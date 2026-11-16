// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import { MetaNFT } from "../src/MetaNFT.sol";
import { NFTAuction } from "../src/NFTAuction.sol";
import { NFTAuctionV2 } from "../src/NFTAuctionV2.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockV3Aggregator } from "../src/mocks/MockV3Aggregator.sol";

/// @dev Unit tests for the auction contract. setUp wires a V1 proxy, a 6-decimal mock USDC
/// and two 8-decimal USD feeds (ETH = $3,000, USDC = $1).
contract NFTAuctionTest is Test {
    NFTAuction internal auction;
    MetaNFT internal nft;
    MockERC20 internal usdc;
    MockV3Aggregator internal ethFeed;
    MockV3Aggregator internal usdcFeed;

    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seller = makeAddr("seller");
    address internal bidder1 = makeAddr("bidder1");
    address internal bidder2 = makeAddr("bidder2");

    /// @dev Every auction in these tests starts at $1,000 and runs for one day.
    uint256 internal constant START_PRICE_USD = 1000e8;
    uint256 internal constant DURATION = 1 days;
    uint256 internal constant NFT_ID = 1;

    function setUp() public {
        nft = new MetaNFT();
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        ethFeed = new MockV3Aggregator(8, 3000e8);
        usdcFeed = new MockV3Aggregator(8, 1e8);

        NFTAuction implementation = new NFTAuction();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(NFTAuction.initialize, (admin, feeRecipient)));
        auction = NFTAuction(payable(address(proxy)));

        vm.startPrank(admin);
        auction.setPriceFeed(address(0), address(ethFeed));
        auction.setPriceFeed(address(usdc), address(usdcFeed));
        vm.stopPrank();

        nft.mint(seller, "ipfs://token/1.json");
        vm.prank(seller);
        nft.setApprovalForAll(address(auction), true);

        vm.deal(bidder1, 100 ether);
        vm.deal(bidder2, 100 ether);
        usdc.mint(bidder1, 1_000_000e6);
        usdc.mint(bidder2, 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Lists NFT_ID on behalf of `seller`. paymentToken == address(0) means ETH only.
    function _list(address paymentToken) internal returns (uint256 auctionId) {
        vm.prank(seller);
        auctionId = auction.createAuction(address(nft), NFT_ID, START_PRICE_USD, DURATION, paymentToken);
    }

    function _warpPastEnd() internal {
        vm.warp(block.timestamp + DURATION + 1);
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    function test_Initialize_SetsOwnerAndFeeRecipient() public view {
        assertEq(auction.owner(), admin);
        assertEq(auction.feeRecipient(), feeRecipient);
        assertEq(auction.maxOracleStaleness(), 1 hours);
        assertEq(auction.getVersion(), "NFTAuction V1");
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        auction.initialize(admin, feeRecipient);
    }

    function test_Implementation_IsLocked() public {
        NFTAuction implementation = new NFTAuction();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin, feeRecipient);
    }

    // ------------------------------------------------------------------
    // Listing
    // ------------------------------------------------------------------

    function test_CreateAuction_EscrowsNftAndEmits() public {
        vm.expectEmit(true, true, true, true, address(auction));
        emit NFTAuction.AuctionCreated(
            0, seller, address(nft), NFT_ID, START_PRICE_USD, block.timestamp + DURATION, address(0)
        );

        uint256 auctionId = _list(address(0));

        assertEq(auctionId, 0);
        assertEq(nft.ownerOf(NFT_ID), address(auction), "NFT must be escrowed");
        assertEq(auction.nextAuctionId(), 1);

        NFTAuction.AuctionView memory view_ = auction.getAuction(auctionId);
        assertEq(view_.seller, seller);
        assertEq(view_.startingPriceUsd, START_PRICE_USD);
        assertEq(view_.paymentToken, address(0));
        assertEq(view_.endTime, block.timestamp + DURATION);
        assertFalse(view_.settled);
        assertFalse(view_.ended);
    }

    function test_CreateAuction_RevertsForNonOwner() public {
        vm.prank(bidder1);
        vm.expectRevert(NFTAuction.NotTokenOwner.selector);
        auction.createAuction(address(nft), NFT_ID, START_PRICE_USD, DURATION, address(0));
    }

    function test_CreateAuction_RevertsWithoutApproval() public {
        uint256 tokenId = nft.mint(bidder1, "ipfs://token/2.json");

        vm.prank(bidder1);
        vm.expectRevert(NFTAuction.NotApproved.selector);
        auction.createAuction(address(nft), tokenId, START_PRICE_USD, DURATION, address(0));
    }

    function test_CreateAuction_RevertsForZeroDuration() public {
        vm.prank(seller);
        vm.expectRevert(NFTAuction.InvalidDuration.selector);
        auction.createAuction(address(nft), NFT_ID, START_PRICE_USD, 0, address(0));
    }

    function test_CreateAuction_RevertsForZeroStartingPrice() public {
        vm.prank(seller);
        vm.expectRevert(NFTAuction.InvalidStartingPrice.selector);
        auction.createAuction(address(nft), NFT_ID, 0, DURATION, address(0));
    }

    // ------------------------------------------------------------------
    // Bidding
    // ------------------------------------------------------------------

    function test_Bid_FirstEthBidRecordsUsdValue() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId); // 0.5 * $3,000 = $1,500

        NFTAuction.AuctionView memory view_ = auction.getAuction(auctionId);
        assertEq(view_.highestBidder, bidder1);
        assertEq(view_.highestBidToken, address(0));
        assertEq(view_.highestBidAmount, 0.5 ether);
        assertEq(view_.highestBidUsd, 1500e8);
        assertEq(address(auction).balance, 0.5 ether);
    }

    function test_Bid_RevertsBelowStartingPrice() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.BidBelowStartingPrice.selector, 1000e8, 300e8));
        auction.bid{ value: 0.1 ether }(auctionId);
    }

    function test_Bid_RevertsWhenNotHigher() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId);

        vm.prank(bidder2);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.BidNotHighEnough.selector, 1500e8, 1200e8));
        auction.bid{ value: 0.4 ether }(auctionId);
    }

    function test_Bid_RevertsAfterEnd() public {
        uint256 auctionId = _list(address(0));
        _warpPastEnd();

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.AuctionEnded.selector, auctionId));
        auction.bid{ value: 1 ether }(auctionId);
    }

    function test_Bid_RevertsForZeroValue() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        vm.expectRevert(NFTAuction.ZeroBid.selector);
        auction.bid{ value: 0 }(auctionId);
    }

    function test_Bid_CreditsRefundToPreviousBidder() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId);

        vm.prank(bidder2);
        auction.bid{ value: 1 ether }(auctionId);

        // Funds stay in the contract until the outbid bidder pulls them.
        assertEq(auction.pendingRefunds(auctionId, bidder1, address(0)), 0.5 ether);
        assertEq(auction.getAuction(auctionId).highestBidder, bidder2);
        assertEq(address(auction).balance, 1.5 ether);
    }

    function test_BidWithERC20_PullsTokensAndRecordsUsd() public {
        uint256 auctionId = _list(address(usdc));

        vm.startPrank(bidder1);
        usdc.approve(address(auction), 1500e6);
        auction.bidWithERC20(auctionId, 1500e6); // 1,500 USDC = $1,500
        vm.stopPrank();

        NFTAuction.AuctionView memory view_ = auction.getAuction(auctionId);
        assertEq(view_.highestBidder, bidder1);
        assertEq(view_.highestBidToken, address(usdc));
        assertEq(view_.highestBidAmount, 1500e6);
        assertEq(view_.highestBidUsd, 1500e8);
        assertEq(usdc.balanceOf(address(auction)), 1500e6);
    }

    function test_BidWithERC20_RevertsForEthOnlyAuction() public {
        uint256 auctionId = _list(address(0));

        vm.startPrank(bidder1);
        usdc.approve(address(auction), 5000e6);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.Erc20NotAccepted.selector, auctionId));
        auction.bidWithERC20(auctionId, 5000e6);
        vm.stopPrank();
    }

    function test_Bid_CrossCurrencyUsdComparison() public {
        uint256 auctionId = _list(address(usdc));

        // 0.4 ETH = $1,200 beats 1,000 USDC = $1,000.
        vm.prank(bidder1);
        auction.bid{ value: 0.4 ether }(auctionId);

        vm.startPrank(bidder2);
        usdc.approve(address(auction), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.BidNotHighEnough.selector, 1200e8, 1000e8));
        auction.bidWithERC20(auctionId, 1000e6);

        // 1,500 USDC = $1,500 wins and the ETH bidder is credited a refund.
        auction.bidWithERC20(auctionId, 1500e6);
        vm.stopPrank();

        assertEq(auction.getAuction(auctionId).highestBidder, bidder2);
        assertEq(auction.pendingRefunds(auctionId, bidder1, address(0)), 0.4 ether);
    }

    // ------------------------------------------------------------------
    // Refunds
    // ------------------------------------------------------------------

    function test_WithdrawRefund_Eth() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId);
        vm.prank(bidder2);
        auction.bid{ value: 1 ether }(auctionId);

        uint256 balanceBefore = bidder1.balance;
        vm.prank(bidder1);
        auction.withdrawRefund(auctionId);

        assertEq(bidder1.balance, balanceBefore + 0.5 ether);
        assertEq(auction.pendingRefunds(auctionId, bidder1, address(0)), 0);
    }

    function test_WithdrawRefund_Erc20() public {
        uint256 auctionId = _list(address(usdc));

        vm.startPrank(bidder1);
        usdc.approve(address(auction), 1500e6);
        auction.bidWithERC20(auctionId, 1500e6);
        vm.stopPrank();

        vm.startPrank(bidder2);
        usdc.approve(address(auction), 2000e6);
        auction.bidWithERC20(auctionId, 2000e6);
        vm.stopPrank();

        uint256 balanceBefore = usdc.balanceOf(bidder1);
        vm.prank(bidder1);
        auction.withdrawRefund(auctionId);

        assertEq(usdc.balanceOf(bidder1), balanceBefore + 1500e6);
        assertEq(auction.pendingRefunds(auctionId, bidder1, address(usdc)), 0);
    }

    function test_WithdrawRefund_RevertsWhenNothingToWithdraw() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        vm.expectRevert(NFTAuction.NothingToWithdraw.selector);
        auction.withdrawRefund(auctionId);
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    function test_Settle_TransfersNftToWinner() public {
        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: 1 ether }(auctionId);
        _warpPastEnd();

        auction.settle(auctionId);

        assertEq(nft.ownerOf(NFT_ID), bidder1);
        assertTrue(auction.getAuction(auctionId).settled);
        // V1 charges no fee, so the whole bid is owed to the seller.
        assertEq(auction.pendingProceeds(seller, address(0)), 1 ether);
        assertEq(auction.pendingFees(feeRecipient, address(0)), 0);
    }

    function test_Settle_ReturnsNftWhenNoBids() public {
        uint256 auctionId = _list(address(0));
        _warpPastEnd();

        auction.settle(auctionId);

        assertEq(nft.ownerOf(NFT_ID), seller);
        assertTrue(auction.getAuction(auctionId).settled);
    }

    function test_Settle_RevertsBeforeEnd() public {
        uint256 auctionId = _list(address(0));

        vm.expectRevert(abi.encodeWithSelector(NFTAuction.AuctionNotEnded.selector, auctionId));
        auction.settle(auctionId);
    }

    function test_Settle_RevertsWhenCalledTwice() public {
        uint256 auctionId = _list(address(0));
        _warpPastEnd();
        auction.settle(auctionId);

        vm.expectRevert(abi.encodeWithSelector(NFTAuction.AlreadySettled.selector, auctionId));
        auction.settle(auctionId);
    }

    function test_WithdrawProceeds_EthAndErc20() public {
        uint256 ethAuction = _list(address(0));
        vm.prank(bidder1);
        auction.bid{ value: 1 ether }(ethAuction);
        _warpPastEnd();
        auction.settle(ethAuction);

        // 时间前进了一天，两路价格都已过期；刷新后再开第二场拍卖，否则出价会以 StalePrice 失败。
        ethFeed.updateAnswer(3000e8);
        usdcFeed.updateAnswer(1e8);

        uint256 sellerEthBefore = seller.balance;
        vm.prank(seller);
        auction.withdrawProceeds(address(0));
        assertEq(seller.balance, sellerEthBefore + 1 ether);

        // A second, ERC20-denominated auction pays the seller in USDC.
        uint256 secondTokenId = nft.mint(seller, "ipfs://token/2.json");
        vm.prank(seller);
        auction.createAuction(address(nft), secondTokenId, START_PRICE_USD, DURATION, address(usdc));
        uint256 erc20Auction = auction.nextAuctionId() - 1;

        vm.startPrank(bidder2);
        usdc.approve(address(auction), 2000e6);
        auction.bidWithERC20(erc20Auction, 2000e6);
        vm.stopPrank();
        _warpPastEnd();
        auction.settle(erc20Auction);

        uint256 sellerUsdcBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        auction.withdrawProceeds(address(usdc));
        assertEq(usdc.balanceOf(seller), sellerUsdcBefore + 2000e6);
    }

    function test_WithdrawProceeds_RevertsWhenNothingToWithdraw() public {
        vm.prank(seller);
        vm.expectRevert(NFTAuction.NothingToWithdraw.selector);
        auction.withdrawProceeds(address(0));
    }

    // ------------------------------------------------------------------
    // Oracle
    // ------------------------------------------------------------------

    function test_GetUsdValue_Handles6And18Decimals() public view {
        assertEq(auction.getUsdValue(address(0), 1 ether), 3000e8);
        assertEq(auction.getUsdValue(address(usdc), 1e6), 1e8);
        assertEq(auction.getUsdValue(address(usdc), 2500e6), 2500e8);
    }

    function test_GetUsdValue_RevertsWithoutFeed() public {
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.PriceFeedNotSet.selector, address(0xdead)));
        auction.getUsdValue(address(0xdead), 1);
    }

    function test_GetUsdValue_RevertsForNonPositiveAnswer() public {
        ethFeed.updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(NFTAuction.InvalidPrice.selector, int256(0)));
        auction.getUsdValue(address(0), 1 ether);
    }

    function test_GetUsdValue_RevertsForStalePrice() public {
        uint256 staleAt = ethFeed.updatedAt();
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(abi.encodeWithSelector(NFTAuction.StalePrice.selector, staleAt));
        auction.getUsdValue(address(0), 1 ether);
    }

    function test_SetPriceFeed_OnlyOwner() public {
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bidder1));
        auction.setPriceFeed(address(0), address(ethFeed));
    }

    function test_SetFeeRecipient_UpdatesAndValidates() public {
        address newRecipient = makeAddr("newFeeRecipient");

        vm.prank(admin);
        auction.setFeeRecipient(newRecipient);
        assertEq(auction.feeRecipient(), newRecipient);

        vm.prank(admin);
        vm.expectRevert(NFTAuction.ZeroAddress.selector);
        auction.setFeeRecipient(address(0));
    }

    function test_SetMaxOracleStaleness_UpdatesAndValidates() public {
        vm.prank(admin);
        auction.setMaxOracleStaleness(2 hours);
        assertEq(auction.maxOracleStaleness(), 2 hours);

        vm.prank(admin);
        vm.expectRevert(NFTAuction.InvalidDuration.selector);
        auction.setMaxOracleStaleness(0);
    }

    function test_CreateAuction_RevertsForZeroNft() public {
        vm.prank(seller);
        vm.expectRevert(NFTAuction.ZeroAddress.selector);
        auction.createAuction(address(0), NFT_ID, START_PRICE_USD, DURATION, address(0));
    }

    function test_Bid_EthAcceptedOnErc20Auction() public {
        uint256 auctionId = _list(address(usdc));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId);

        assertEq(auction.getAuction(auctionId).highestBidToken, address(0));
        assertEq(auction.getAuction(auctionId).highestBidUsd, 1500e8);
    }

    /// @dev 预言机 decimals 不一定是 8：高于 8 位要缩小，低于 8 位要放大，最终都归一到 8 位。
    function test_GetUsdValue_NormalizesFeedDecimals() public {
        MockV3Aggregator eth18 = new MockV3Aggregator(18, 3000e18);
        vm.prank(admin);
        auction.setPriceFeed(address(0), address(eth18));
        assertEq(auction.getUsdValue(address(0), 1 ether), 3000e8);

        MockV3Aggregator eth6 = new MockV3Aggregator(6, 3000e6);
        vm.prank(admin);
        auction.setPriceFeed(address(0), address(eth6));
        assertEq(auction.getUsdValue(address(0), 1 ether), 3000e8);
    }

    // ------------------------------------------------------------------
    // Upgrade
    // ------------------------------------------------------------------

    function test_Upgrade_OnlyOwner() public {
        NFTAuctionV2 v2 = new NFTAuctionV2();
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bidder1));
        auction.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_PreservesStorageAndSetsVersion() public {
        uint256 auctionId = _list(address(0));
        vm.prank(bidder1);
        auction.bid{ value: 1 ether }(auctionId);

        NFTAuctionV2 v2Implementation = new NFTAuctionV2();

        vm.prank(admin);
        auction.upgradeToAndCall(
            address(v2Implementation), abi.encodeCall(NFTAuctionV2.initializeV2, (1000e8, 10_000e8, 200, 150, 100))
        );

        NFTAuctionV2 upgraded = NFTAuctionV2(payable(address(auction)));
        assertEq(upgraded.getVersion(), "NFTAuction V2");
        assertEq(upgraded.nextAuctionId(), 1);

        NFTAuction.AuctionView memory view_ = upgraded.getAuction(auctionId);
        assertEq(view_.seller, seller);
        assertEq(view_.highestBidder, bidder1);
        assertEq(view_.highestBidAmount, 1 ether);

        assertEq(upgraded.getFeeBps(500e8), 200);
        assertEq(upgraded.getFeeBps(5000e8), 150);
        assertEq(upgraded.getFeeBps(20_000e8), 100);
    }
}
