# NFT 拍卖市场 — 设计文档

日期:2026-11-16
作业:MetaNodeAcademy LearningRoadmap `contract/homework03.md`
实现工具链:Foundry(经用户确认,替代作业原文的 Hardhat)

## 1. 背景与目标

实现一个 NFT 拍卖市场:卖家把 ERC721 NFT 上架拍卖,买家可用 ETH 或 ERC20 出价,合约通过 Chainlink 价格预言机把不同币种的出价折算成 USD 比较高低;拍卖结束后 NFT 归最高出价者、资金归卖家;拍卖合约可通过 UUPS 代理升级。

目标:
- 覆盖作业全部必做功能:NFT、拍卖、Chainlink 价格计算、UUPS 升级、测试、部署、文档。
- 用 Foundry 完成开发、测试、覆盖率与部署脚本。
- 代码清晰、安全(重入防护、拉取式退款、预言机陈旧价格校验)。

非目标:
- 不做前端/UI。
- 不做完整订单簿或英式/荷兰式以外的拍卖类型。
- 不实现主网级治理或多签。

失败标准(anti-goals):
- 拍卖结算资金出错、NFT 卡在合约里。
- 出价比较依赖中心化操作者手动输入价格。
- 升级后存储布局错乱、旧数据丢失。
- 覆盖率低、关键路径无测试。

## 2. 约束

- 作业原文要求 Hardhat;用户明确选择纯 Foundry。README 中说明工具链差异与对应关系。
- Sepolia 部署需要用户后补 RPC URL、私钥、Etherscan API Key;在此之前交付本地可验证的完整项目与部署脚本。
- 参考 demo:`lc3091/hardhatV3Nft`(Hardhat + Foundry 测试)。仅参考业务流程,不照抄其实现缺陷(如退款代币错配、`transfer` 固定 gas、owner 代下单)。
- Solidity 0.8.38(源码 pragma 精确固定),OpenZeppelin Contracts v5.7.0,forge-std v1.17.0。

## 3. 核心流程

### 3.1 上架
卖家调用 `createAuction(nft, tokenId, startingPriceUsd, duration, paymentToken)`:
- 校验 `duration > 0`、`startingPriceUsd > 0`、卖家是 NFT owner 且已授权拍卖合约。
- NFT 托管进拍卖合约(escrow),生成 auctionId。
- `paymentToken` 为 0 表示该拍卖只接受 ETH;否则接受 ETH 和该 ERC20 两种出价。
- 上架是无需许可的(任何 NFT 持有者都可上架),不是 owner 代下单。

### 3.2 出价
`bid(auctionId)` payable 或 `bidWithERC20(auctionId, amount)`:
- 拍卖必须未结束、未结算。
- ETH 出价:`msg.value > 0`,按 ETH/USD feed 折算 USD。
- ERC20 出价:拍卖必须配置了 ERC20,`SafeERC20.safeTransferFrom` 拉取,按该代币/USD feed 折算 USD。
- 首次出价必须 ≥ `startingPriceUsd`;后续出价必须严格高于当前最高 USD 价值。
- 最高出价记录(token、金额、USD 价值、出价人)。
- 被超越的前最高出价者不直接打款,而是记入可提取退款(pull-based),由本人调用 `withdrawRefund(auctionId)` 提取,避免退款 gas/拒收导致拍卖卡死。

### 3.3 结算
`settle(auctionId)` 无需许可,任何人可在结束后调用:
- 无出价:用 `transferFrom` 把 NFT 退回卖家。
- 有出价:用 `transferFrom` 把 NFT 转给最高出价者(不使用 `safeTransferFrom`,避免接收方合约缺少回调导致 NFT 永久卡住)。
- 卖家所得(扣除平台费后的 V2 部分)与平台费不直接打款,而是记入 `pendingProceeds[seller][token]` / `pendingFees[feeRecipient][token]`,由本人调用 `withdrawProceeds(token)` / `withdrawFees(token)` 提取(成交币种可能是 ETH 或 ERC20,必须按币种记账)。避免卖家或收款方拒收 ETH/代币导致结算永久失败。
- 标记已结算;结算后不可再次结算或出价。

### 3.4 价格换算
- `setPriceFeed(token, feed)` 仅 owner;`address(0)` 代表 ETH。
- 读取 `latestRoundData()`,要求 `answer > 0`、`updatedAt` 不陈旧(可配置最大陈旧时间,默认 1 小时)、`answeredInRound >= roundId`。
- USD 统一 8 位小数:出价金额按其 decimals 与 8 位价格换算。
- 支持 ERC4626 式 decimals 差异(`IERC20Metadata.decimals()`)。

### 3.5 升级(V1 → V2)
- 拍卖合约采用 UUPS:实现合约构造器 `_disableInitializers()`,代理通过 `initialize(admin, feeRecipient)` 初始化。
- 升级权限:`_authorizeUpgrade` 仅 owner。
- V2 在 V1 存储布局末尾追加字段,新增"动态平台费"(作业可选挑战):
  - 费率按成交 USD 价值分档,例:< $1,000 收 2%,< $10,000 收 1.5%,其余 1%;owner 可配置分档参数与上限。
  - 结算时从卖家所得中扣除,转给 `feeRecipient`;V1 费率为 0,升级后生效。
  - 新增 `getVersion()` 返回 V2 标识,保留 V1 全部外部接口。

## 4. 合约与文件结构

```
metanode-homework03-nft-auction/
├── foundry.toml
├── remappings.txt
├── README.md
├── .env.example
├── .gitignore
├── src/
│   ├── MetaNFT.sol              # ERC721,公开 mint(带 URI)
│   ├── NFTAuction.sol           # V1:拍卖 + UUPS + 预言机 + 拉取退款
│   ├── NFTAuctionV2.sol         # V2:动态平台费
│   └── mocks/
│       ├── MockERC20.sol        # 测试用 ERC20(可配 decimals)
│       └── MockV3Aggregator.sol # Chainlink AggregatorV3Interface mock
├── test/
│   ├── MetaNFT.t.sol
│   ├── NFTAuction.t.sol         # 单元测试
│   ├── NFTAuctionIntegration.t.sol  # 全流程 + 跨币种 + 升级
│   └── NFTAuctionFork.t.sol     # 可选:Sepolia fork(需 RPC)
├── script/
│   ├── Deploy.s.sol             # 部署 NFT + 拍卖代理 + 配置 feed
│   └── Upgrade.s.sol            # V1 → V2 升级
├── docs/
│   ├── test-report.md           # 覆盖率与测试结果
│   └── superpowers/specs/2026-11-16-nft-auction-design.md
└── deployments/                 # 部署产物地址(README 同步)
```

## 5. 接口草案

```solidity
// NFTAuction (V1)
function initialize(address owner_, address feeRecipient_) external;
function createAuction(address nft, uint256 tokenId, uint256 startingPriceUsd, uint256 duration, address paymentToken) external returns (uint256);
function bid(uint256 auctionId) external payable;
function bidWithERC20(uint256 auctionId, uint256 amount) external;
function withdrawRefund(uint256 auctionId) external;
function settle(uint256 auctionId) external;
function withdrawProceeds(address token) external;
function withdrawFees(address token) external;
function setPriceFeed(address token, address feed) external; // onlyOwner
function setMaxOracleStaleness(uint256 seconds_) external;   // onlyOwner
function getUsdValue(address token, uint256 amount) external view returns (uint256);
function getAuction(uint256 auctionId) external view returns (AuctionView memory);
function getVersion() external pure returns (string memory); // "NFTAuction V1"
```

## 6. 测试计划

单元测试:
- NFT:铸造、转移、tokenURI、非法操作。
- 上架:正常、未授权、非 owner、时长为 0、起拍价为 0、paymentToken 为 0(仅 ETH)。
- 出价:ETH 首拍、ERC20 首拍、低于起拍价、低于最高价、结束后出价、双币种 USD 比较(ETH $3000 vs USDC $1)。
- 退款:被超越后可提取;重复提取失败;跨 ETH/ERC20 正确退款。
- 结算:赢家获得 NFT、卖家收款、无出价退回 NFT、重复结算失败、未结束结算失败。
- 预言机:未配置 feed、价格 ≤ 0、陈旧价格、权限控制。
- 升级:非 owner 不可升级、升级后存储保留、V2 版本号、V2 动态费率结算。

集成/模糊测试:
- 双买家跨 ETH/ERC20 完整流程 + 中期升级 V2 + 结算扣费。
- `forge` fuzz:出价金额/时间随机化下的资金守恒(NFT 归属 + 合约余额)。

覆盖率:
- `forge coverage --report summary --report lcov`,目标行覆盖率 ≥ 95%;结果写入 `docs/test-report.md`,附 `forge test -vv` 结果。

## 7. 部署

- `.env.example`:`SEPOLIA_RPC_URL`、`PRIVATE_KEY`、`ETHERSCAN_API_KEY`。
- `Deploy.s.sol`:
  1. 部署 `MetaNFT`。
  2. 部署 `MockERC20`(MockUSDC,6 位小数)作为演示用 ERC20。
  3. 用 `Upgrades.deployUUPSProxy` 部署 `NFTAuction` 代理并初始化。
  4. ETH/USD 使用 Sepolia 上的真实 Chainlink feed;ERC20/USD 部署一个 `MockV3Aggregator`(自部署的 MockERC20 没有官方 feed),`latestRoundData()` 的 `updatedAt` 取 `block.timestamp`,不会触发陈旧校验。README 说明:接真实现网代币时只需 owner 调用 `setPriceFeed` 换成官方地址。
  5. 铸造示例 NFT 给部署者。
  6. 输出全部地址并写入 `deployments/sepolia.json`。
- `Upgrade.s.sol`:在 Sepolia 上把代理从 V1 升级到 V2,并记录 V2 实现地址与升级交易。
- 验证:`forge script ... --verify` / `forge verify-contract`(Etherscan v2,chainId 11155111),代理实现合约也验证。
- 用户补全密钥后执行;在此之前用 `anvil` 完成本地端到端验证。

## 8. 文档与提交

- `README.md`:项目介绍、结构、功能、快速开始、测试/覆盖率、Sepolia 部署步骤、合约地址(后补)、与作业要求的对应关系及 Foundry 说明。
- `docs/test-report.md`:测试列表、通过情况、覆盖率表格、关键截图/日志(本地运行输出)。
- 提交:初始化 git 仓库并提交;推送到 `github.com:zzhullong/metanode-homework03-nft-auction`(public)。仓库创建方式待定:用户在网页新建空仓库,或登录 `gh` 后由我创建。

## 9. 由我做出的决定(可改)

- 纯 Foundry,不保留 Hardhat 部署层(用户选择)。
- 起拍价以 USD(8 位)计价,便于跨币种比较。
- 每场拍卖固定一种 ERC20(可选)+ ETH 同时可出价。
- 上架与结算均无需许可;预言机与升级仅 owner。
- 退款、卖家所得、平台费全部采用拉取式,结算时只转移 NFT 并记账。
- NFT 结算使用 `transferFrom`(非 `safeTransferFrom`),避免接收方回调导致卡死。
- V2 的动态平台费用于满足"额外挑战";费率按结算时记录的最高出价 USD 值分档,费用按成交代币数量计算(结算不再读预言机)。
- Sepolia 上的 ERC20 演示使用自部署 MockERC20 + MockV3Aggregator;ETH/USD 用真实 Chainlink feed。
- Sepolia 交付包含 V1 部署 + 升级到 V2,两个实现合约均验证。
- Solidity `0.8.38` + OZ v5.7.0(OZ v5.5+ 移除了 `ReentrancyGuardUpgradeable`,本项目改用核心包 `ReentrancyGuard`,同为 ERC-7201 命名空间存储槽,代理升级不错位);代理部署与升级直接用 `ERC1967Proxy` / `UUPSUpgradeable`,不引入 openzeppelin-foundry-upgrades 插件(避免 FFI 与 Node 依赖)。

## 10. 待补/待办

- Sepolia 部署所需 RPC、私钥、Etherscan Key(用户后补)。
- Chainlink Sepolia ETH/USD 官方 feed 已核对(`0x694AA1769357215DE4FAC081bf1f309aDC325306`)并写入 README 与部署脚本。
- GitHub 仓库已创建:https://github.com/zzhullong/metanode-homework03-nft-auction 。
