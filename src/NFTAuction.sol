// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "./interfaces/AggregatorV3Interface.sol";

/// @title NFTAuction V1
/// @notice NFT 拍卖市场：卖家托管 NFT，买家可用 ETH 或指定 ERC20 出价，
///         所有出价通过 Chainlink 预言机折算成 USD(8 位小数)后比较高低。
/// @dev 合约通过 UUPS 代理升级。下面的存储布局在部署后即冻结：V2 只能在末尾追加变量，
///      绝不能插入、删除或重排已有变量，否则代理后面的数据会整体错位。
contract NFTAuction is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // 类型
    // ---------------------------------------------------------------------

    /// @dev 一场拍卖的完整状态。用 address 而不是接口类型存储，避免代理升级时接口变化带来的歧义。
    ///      金额字段：startingPriceUsd / highestBidUsd 恒为 8 位小数；highestBidAmount 是出价代币原始精度。
    struct Auction {
        address nft; // NFT 合约地址
        address seller; // 卖家；address(0) 同时用来标记“该 auctionId 不存在”
        uint256 tokenId; // 被托管的 NFT tokenId
        uint256 startTime; // 拍卖开始时间
        uint256 endTime; // 拍卖结束时间 = startTime + duration
        uint256 startingPriceUsd; // 起拍价（USD，8 位小数）
        address paymentToken; // 该场拍卖接受的 ERC20；address(0) 表示只收 ETH
        address highestBidder; // 当前最高出价人；address(0) 表示还没人出价
        address highestBidToken; // 当前最高出价使用的币种；address(0) 表示 ETH
        uint256 highestBidAmount; // 当前最高出价的数量（原始精度）
        uint256 highestBidUsd; // 当前最高出价的 USD 价值（8 位小数）
        bool settled; // 是否已结算，防止重复结算/结算后出价
    }

    /// @notice getAuction 的只读返回结构，额外附带一个计算出来的 ended 字段。
    struct AuctionView {
        address nft;
        address seller;
        uint256 tokenId;
        uint256 startTime;
        uint256 endTime;
        uint256 startingPriceUsd;
        address paymentToken;
        address highestBidder;
        address highestBidToken;
        uint256 highestBidAmount;
        uint256 highestBidUsd;
        bool settled;
        bool ended;
    }

    // ---------------------------------------------------------------------
    // 存储（自本行起只允许在末尾追加）
    // ---------------------------------------------------------------------
    //
    // OpenZeppelin v5 的基础合约（OwnableUpgradeable / ReentrancyGuard）都使用 ERC-7201 命名空间存储，
    // 不占用普通的顺序 slot，因此从 nextAuctionId 开始就是本合约自己的布局。
    // 升级时请用 `forge inspect NFTAuction storageLayout` 对比 V1/V2。

    uint256 public nextAuctionId;
    mapping(uint256 auctionId => Auction) private _auctions;
    /// @notice 币种 => Chainlink USD 价格源；address(0) 代表 ETH。
    mapping(address token => address feed) public priceFeeds;
    /// @notice 预言机价格允许的最大陈旧时间（秒），默认 1 小时。
    uint256 public maxOracleStaleness;
    /// @notice 平台费收款地址。V1 不收费，但地址先存下来，V2 直接复用。
    address public feeRecipient;
    /// @notice 卖家待提取货款：账户 => 币种 => 金额。
    ///         用“拉取式”记账而不是结算时直接打款，避免卖家拒收（合约账户）导致结算永久失败。
    mapping(address account => mapping(address token => uint256 amount)) public pendingProceeds;
    /// @notice 平台待提取费用：账户 => 币种 => 金额。V1 恒为 0，V2 结算时写入。
    mapping(address account => mapping(address token => uint256 amount)) public pendingFees;
    /// @notice 出价被超越后待提取的退款：auctionId => 出价人 => 币种 => 金额。
    ///         同理避免退款转账失败把出价流程卡死；ETH 与 ERC20 用币种维度区分。
    mapping(uint256 auctionId => mapping(address bidder => mapping(address token => uint256 amount))) public
        pendingRefunds;

    // ---------------------------------------------------------------------
    // 事件
    // ---------------------------------------------------------------------

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 startingPriceUsd,
        uint256 endTime,
        address paymentToken
    );
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, address token, uint256 amount, uint256 usdValue);
    event RefundCredited(uint256 indexed auctionId, address indexed bidder, address token, uint256 amount);
    event RefundWithdrawn(uint256 indexed auctionId, address indexed bidder, address token, uint256 amount);
    event AuctionSettled(uint256 indexed auctionId, address indexed winner, address token, uint256 amount, uint256 fee);
    event ProceedsWithdrawn(address indexed account, address token, uint256 amount);
    event FeesWithdrawn(address indexed account, address token, uint256 amount);
    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MaxOracleStalenessUpdated(uint256 seconds_);
    event FeeRecipientUpdated(address indexed feeRecipient);

    // ---------------------------------------------------------------------
    // 错误
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidDuration();
    error InvalidStartingPrice();
    error NotTokenOwner();
    error NotApproved();
    error AuctionNotFound(uint256 auctionId);
    error AuctionEnded(uint256 auctionId);
    error AuctionNotEnded(uint256 auctionId);
    error AlreadySettled(uint256 auctionId);
    error ZeroBid();
    error BidBelowStartingPrice(uint256 requiredUsd, uint256 actualUsd);
    error BidNotHighEnough(uint256 highestUsd, uint256 actualUsd);
    error Erc20NotAccepted(uint256 auctionId);
    error PriceFeedNotSet(address token);
    error InvalidPrice(int256 answer);
    error StalePrice(uint256 updatedAt);
    error NothingToWithdraw();
    error UnexpectedValue();

    // ---------------------------------------------------------------------
    // 初始化
    // ---------------------------------------------------------------------

    /// @dev 实现合约自身永远处于“已初始化”状态，防止有人直接初始化实现合约并调用 upgradeToAndCall
    ///      劫持代理。只有代理存储里的 initializer 才是空的，可以初始化一次。
    constructor() {
        _disableInitializers();
    }

    /// @notice 代理部署时调用一次。
    /// @param owner_ 升级与配置权限的 owner。
    /// @param feeRecipient_ 平台费收款地址（V1 不产生费用，V2 起生效）。
    function initialize(address owner_, address feeRecipient_) external initializer {
        if (owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        feeRecipient = feeRecipient_;
        maxOracleStaleness = 1 hours;
    }

    // ---------------------------------------------------------------------
    // 上架
    // ---------------------------------------------------------------------

    /// @notice 把 NFT 托管进合约并开一场拍卖。任何 NFT 持有者都能上架，无需 owner 代操作。
    /// @param nft NFT 合约地址。
    /// @param tokenId 要拍卖的 tokenId。
    /// @param startingPriceUsd 起拍价（USD，8 位小数）。
    /// @param duration 拍卖时长（秒）。
    /// @param paymentToken 该场拍卖额外接受的 ERC20；address(0) 表示只接受 ETH。
    /// @return auctionId 新拍卖的 id（从 0 开始自增）。
    function createAuction(
        address nft,
        uint256 tokenId,
        uint256 startingPriceUsd,
        uint256 duration,
        address paymentToken
    ) external nonReentrant returns (uint256 auctionId) {
        if (nft == address(0)) revert ZeroAddress();
        if (duration == 0) revert InvalidDuration();
        if (startingPriceUsd == 0) revert InvalidStartingPrice();

        IERC721 token = IERC721(nft);

        // 只有 owner 能上架，并且必须已授权给本合约（单 token 授权或 opensea 式全量授权都行）。
        // 先查 owner 再查授权，是为了让“不是 owner”这种更根本的问题优先报出来。
        if (token.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!token.isApprovedForAll(msg.sender, address(this)) && token.getApproved(tokenId) != address(this)) {
            revert NotApproved();
        }

        auctionId = nextAuctionId++;

        // 先把状态写完整，再做外部调用（把 NFT 拉进合约），遵循 checks-effects-interactions。
        Auction storage auction = _auctions[auctionId];
        auction.nft = nft;
        auction.seller = msg.sender;
        auction.tokenId = tokenId;
        auction.startTime = block.timestamp;
        auction.endTime = block.timestamp + duration;
        auction.startingPriceUsd = startingPriceUsd;
        auction.paymentToken = paymentToken;

        // 托管 NFT。用 transferFrom 而非 safeTransferFrom：这里的目标是本合约，不存在接收回调缺失的问题，
        // 而 safeTransferFrom 会额外触发 onERC721Received，多一层不必要的依赖。
        token.transferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(auctionId, msg.sender, nft, tokenId, startingPriceUsd, auction.endTime, paymentToken);
    }

    // ---------------------------------------------------------------------
    // 出价
    // ---------------------------------------------------------------------

    /// @notice 用 ETH 出价，msg.value 即出价金额。
    /// @dev 无论拍卖是否配置了 ERC20，ETH 始终可出价；两者都按 USD 价值比较。
    function bid(uint256 auctionId) external payable nonReentrant {
        Auction storage auction = _requireActive(auctionId);

        if (msg.value == 0) revert ZeroBid();

        uint256 usdValue = getUsdValue(address(0), msg.value);
        _placeBid(auction, auctionId, address(0), msg.value, usdValue);
    }

    /// @notice 用拍卖配置的 ERC20 出价。
    /// @dev 声明为 payable 仅仅是为了能检查并拒绝误发的 ETH，本函数本身不收 ETH。
    function bidWithERC20(uint256 auctionId, uint256 amount) external payable nonReentrant {
        // 误把 ETH 一起发进来时直接拒绝，防止资金滞留在合约里。
        if (msg.value != 0) revert UnexpectedValue();

        Auction storage auction = _requireActive(auctionId);

        if (auction.paymentToken == address(0)) revert Erc20NotAccepted(auctionId);
        if (amount == 0) revert ZeroBid();

        uint256 usdValue = getUsdValue(auction.paymentToken, amount);

        // 先拉取代币再记账。两处都在 nonReentrant 保护下，且任何校验失败都会整体回滚。
        IERC20(auction.paymentToken).safeTransferFrom(msg.sender, address(this), amount);

        _placeBid(auction, auctionId, auction.paymentToken, amount, usdValue);
    }

    /// @dev 出价校验与记账的公共逻辑。
    ///      规则：首次出价必须 ≥ 起拍价；之后必须严格高于当前最高 USD 价值。
    ///      被超越者的资金不会立刻退还，而是记到 pendingRefunds 由其自行提取。
    function _placeBid(Auction storage auction, uint256 auctionId, address token, uint256 amount, uint256 usdValue)
        private
    {
        // 首次出价允许正好等于起拍价，之后必须严格更高（防止原地踏步）。
        if (auction.highestBidder == address(0)) {
            if (usdValue < auction.startingPriceUsd) {
                revert BidBelowStartingPrice(auction.startingPriceUsd, usdValue);
            }
        } else if (usdValue <= auction.highestBidUsd) {
            revert BidNotHighEnough(auction.highestBidUsd, usdValue);
        }

        address previousBidder = auction.highestBidder;
        if (previousBidder != address(0)) {
            // 即使出价人是自己，也照样记账：不在这里做净额抵扣，逻辑最简单，也不会算错账。
            uint256 refundAmount = auction.highestBidAmount;
            address refundToken = auction.highestBidToken;
            pendingRefunds[auctionId][previousBidder][refundToken] += refundAmount;
            emit RefundCredited(auctionId, previousBidder, refundToken, refundAmount);
        }

        auction.highestBidder = msg.sender;
        auction.highestBidToken = token;
        auction.highestBidAmount = amount;
        auction.highestBidUsd = usdValue;

        emit BidPlaced(auctionId, msg.sender, token, amount, usdValue);
    }

    /// @dev 校验拍卖存在、未结算、未结束，并返回存储指针。
    function _requireActive(uint256 auctionId) private view returns (Auction storage auction) {
        auction = _auctions[auctionId];
        if (auction.seller == address(0)) revert AuctionNotFound(auctionId);
        if (auction.settled) revert AlreadySettled(auctionId);
        if (block.timestamp >= auction.endTime) revert AuctionEnded(auctionId);
    }

    // ---------------------------------------------------------------------
    // 提取（拉取式）
    // ---------------------------------------------------------------------

    /// @notice 提取本人在某场拍卖中累计的退款（ETH 与该场拍卖的 ERC20 一并处理）。
    function withdrawRefund(uint256 auctionId) external nonReentrant {
        Auction storage auction = _auctions[auctionId];

        uint256 ethAmount = pendingRefunds[auctionId][msg.sender][address(0)];
        uint256 tokenAmount =
            auction.paymentToken == address(0) ? 0 : pendingRefunds[auctionId][msg.sender][auction.paymentToken];

        if (ethAmount == 0 && tokenAmount == 0) revert NothingToWithdraw();

        // 先清零再转账（checks-effects-interactions），即便代币有回调也无法重复提取。
        if (ethAmount > 0) {
            pendingRefunds[auctionId][msg.sender][address(0)] = 0;
            Address.sendValue(payable(msg.sender), ethAmount);
            emit RefundWithdrawn(auctionId, msg.sender, address(0), ethAmount);
        }

        if (tokenAmount > 0) {
            pendingRefunds[auctionId][msg.sender][auction.paymentToken] = 0;
            IERC20(auction.paymentToken).safeTransfer(msg.sender, tokenAmount);
            emit RefundWithdrawn(auctionId, msg.sender, auction.paymentToken, tokenAmount);
        }
    }

    /// @notice 提取卖家货款。
    /// @param token address(0) 提取 ETH，否则提取对应 ERC20。
    function withdrawProceeds(address token) external nonReentrant {
        uint256 amount = pendingProceeds[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();

        pendingProceeds[msg.sender][token] = 0;
        _payout(msg.sender, token, amount);

        emit ProceedsWithdrawn(msg.sender, token, amount);
    }

    /// @notice 提取平台费。V1 不会产生费用，保留接口是为了 V2 升级后 ABI 不变。
    /// @param token address(0) 提取 ETH，否则提取对应 ERC20。
    function withdrawFees(address token) external nonReentrant {
        uint256 amount = pendingFees[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();

        pendingFees[msg.sender][token] = 0;
        _payout(msg.sender, token, amount);

        emit FeesWithdrawn(msg.sender, token, amount);
    }

    /// @dev 统一的 ETH / ERC20 打款出口。ETH 用 Address.sendValue（转发全部 gas 并检查返回值），
    ///      而不是 transfer() 的 2300 gas 固定额度——后者会误伤多签/合约收款方。
    function _payout(address to, address token, uint256 amount) private {
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ---------------------------------------------------------------------
    // 结算
    // ---------------------------------------------------------------------

    /// @notice 结束拍卖。无需许可，任何人（包括买家）都可以在结束后调用。
    /// @dev 结算只做三件事：交付 NFT、把货款/费用记入待提取余额、标记 settled。
    ///      不在这一步直接打款，避免任何一方拒收导致整场拍卖无法收尾。
    function settle(uint256 auctionId) external nonReentrant {
        Auction storage auction = _auctions[auctionId];

        if (auction.seller == address(0)) revert AuctionNotFound(auctionId);
        if (auction.settled) revert AlreadySettled(auctionId);
        if (block.timestamp < auction.endTime) revert AuctionNotEnded(auctionId);

        // 先置位再外部调用，重入时会被 AlreadySettled 拦住。
        auction.settled = true;

        // 无人出价：NFT 原路退回卖家，不产生货款。
        if (auction.highestBidder == address(0)) {
            IERC721(auction.nft).transferFrom(address(this), auction.seller, auction.tokenId);
            emit AuctionSettled(auctionId, address(0), address(0), 0, 0);
            return;
        }

        // 有出价：按成交 USD 价值算费（V1 恒为 0），剩余部分记给卖家。
        // 费用在结算币种里计算，结算过程不再读预言机，避免预言机异常卡住已结束的拍卖。
        uint256 fee = _calculateFee(auction.highestBidUsd, auction.highestBidAmount);
        uint256 sellerAmount = auction.highestBidAmount - fee;

        pendingProceeds[auction.seller][auction.highestBidToken] += sellerAmount;
        if (fee > 0) {
            pendingFees[feeRecipient][auction.highestBidToken] += fee;
        }

        // 用 transferFrom 而不是 safeTransferFrom：若最高出价者是合约且未实现 onERC721Received，
        // safeTransferFrom 会让结算永久 revert、NFT 永远卡在拍卖合约里。
        IERC721(auction.nft).transferFrom(address(this), auction.highestBidder, auction.tokenId);

        emit AuctionSettled(auctionId, auction.highestBidder, auction.highestBidToken, auction.highestBidAmount, fee);
    }

    // ---------------------------------------------------------------------
    // 预言机
    // ---------------------------------------------------------------------

    /// @notice 把 token 数量折算成 USD，返回值统一 8 位小数。
    /// @param token address(0) 表示 ETH，其余按 ERC20 处理。
    /// @param amount 以该币种原始精度表示的数量。
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        address feedAddress = priceFeeds[token];
        if (feedAddress == address(0)) revert PriceFeedNotSet(token);

        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        // 价格必须为正；round 数据必须完整且未过期，否则宁可让出价失败也不要按错误价格成交。
        if (answer <= 0) revert InvalidPrice(answer);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxOracleStaleness) {
            revert StalePrice(updatedAt);
        }
        if (answeredInRound < roundId) revert StalePrice(updatedAt);

        uint8 priceDecimals = feed.decimals();
        uint8 amountDecimals = token == address(0) ? 18 : IERC20Metadata(token).decimals();

        // amount * price / 10^amountDecimals 得到 10^priceDecimals 精度的 USD，再对齐到 8 位小数。
        uint256 usd = Math.mulDiv(amount, uint256(answer), 10 ** amountDecimals);
        if (priceDecimals > 8) {
            usd /= 10 ** (priceDecimals - 8);
        } else if (priceDecimals < 8) {
            usd *= 10 ** (8 - priceDecimals);
        }

        return usd;
    }

    // ---------------------------------------------------------------------
    // 查询
    // ---------------------------------------------------------------------

    function getAuction(uint256 auctionId) external view returns (AuctionView memory view_) {
        Auction storage auction = _auctions[auctionId];
        view_ = AuctionView({
            nft: auction.nft,
            seller: auction.seller,
            tokenId: auction.tokenId,
            startTime: auction.startTime,
            endTime: auction.endTime,
            startingPriceUsd: auction.startingPriceUsd,
            paymentToken: auction.paymentToken,
            highestBidder: auction.highestBidder,
            highestBidToken: auction.highestBidToken,
            highestBidAmount: auction.highestBidAmount,
            highestBidUsd: auction.highestBidUsd,
            settled: auction.settled,
            ended: isEnded(auctionId)
        });
    }

    function isEnded(uint256 auctionId) public view returns (bool) {
        Auction storage auction = _auctions[auctionId];
        return auction.seller != address(0) && block.timestamp >= auction.endTime;
    }

    function getVersion() external pure virtual returns (string memory) {
        return "NFTAuction V1";
    }

    // ---------------------------------------------------------------------
    // owner 配置
    // ---------------------------------------------------------------------

    /// @notice 设置某个币种的价格源。token 传 address(0) 即配置 ETH/USD。
    function setPriceFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    /// @notice 调整预言机允许的最大陈旧时间。
    function setMaxOracleStaleness(uint256 seconds_) external onlyOwner {
        if (seconds_ == 0) revert InvalidDuration();
        maxOracleStaleness = seconds_;
        emit MaxOracleStalenessUpdated(seconds_);
    }

    /// @notice 更换平台费收款地址。
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // ---------------------------------------------------------------------
    // 钩子
    // ---------------------------------------------------------------------

    /// @dev V1 不收费，返回 0；V2 覆盖此函数实现分档费率。
    function _calculateFee(uint256, uint256) internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev 只允许 owner 升级实现合约，其它人调用 upgradeToAndCall 会被这里拦住。
    function _authorizeUpgrade(address) internal override onlyOwner { }
}
