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

/// @dev V2 专项测试：升级初始化、费率分档、owner 配置与平台费提取。
contract NFTAuctionV2Test is Test {
    NFTAuction internal proxyAuction;
    NFTAuctionV2 internal auction;
    MetaNFT internal nft;
    MockERC20 internal usdc;
    MockV3Aggregator internal ethFeed;
    MockV3Aggregator internal usdcFeed;

    address internal admin = makeAddr("admin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal seller = makeAddr("seller");
    address internal bidder = makeAddr("bidder");

    uint256 internal constant START_PRICE_USD = 1000e8;
    uint256 internal constant DURATION = 1 days;

    function setUp() public {
        nft = new MetaNFT();
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        ethFeed = new MockV3Aggregator(8, 3000e8);
        usdcFeed = new MockV3Aggregator(8, 1e8);

        proxyAuction = _deployV1();

        NFTAuctionV2 implementation = new NFTAuctionV2();
        vm.prank(admin);
        proxyAuction.upgradeToAndCall(
            address(implementation), abi.encodeCall(NFTAuctionV2.initializeV2, (1000e8, 10_000e8, 200, 150, 100))
        );
        auction = NFTAuctionV2(payable(address(proxyAuction)));

        nft.mint(seller, "ipfs://token/1.json");
        vm.prank(seller);
        nft.setApprovalForAll(address(auction), true);
        vm.deal(bidder, 10 ether);
    }

    function _deployV1() internal returns (NFTAuction) {
        NFTAuction implementation = new NFTAuction();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(NFTAuction.initialize, (admin, feeRecipient)));
        NFTAuction deployed = NFTAuction(payable(address(proxy)));
        vm.startPrank(admin);
        deployed.setPriceFeed(address(0), address(ethFeed));
        deployed.setPriceFeed(address(usdc), address(usdcFeed));
        vm.stopPrank();
        return deployed;
    }

    // ------------------------------------------------------------------
    // 初始化
    // ------------------------------------------------------------------

    function test_InitializeV2_StoresTiersAndCap() public view {
        assertEq(auction.feeTier1CutoffUsd(), 1000e8);
        assertEq(auction.feeTier2CutoffUsd(), 10_000e8);
        assertEq(auction.feeTier1Bps(), 200);
        assertEq(auction.feeTier2Bps(), 150);
        assertEq(auction.feeTier3Bps(), 100);
        assertEq(auction.maxFeeBps(), 1000);
        assertEq(auction.getVersion(), "NFTAuction V2");
    }

    function test_InitializeV2_RevertsOnSecondCall() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        auction.initializeV2(1000e8, 10_000e8, 200, 150, 100);
    }

    function test_InitializeV2_RevertsOnInvalidCutoffs() public {
        NFTAuction fresh = _deployV1();
        NFTAuctionV2 implementation = new NFTAuctionV2();
        vm.prank(admin);
        vm.expectRevert(NFTAuctionV2.InvalidFeeTiers.selector);
        fresh.upgradeToAndCall(
            address(implementation), abi.encodeCall(NFTAuctionV2.initializeV2, (0, 10_000e8, 200, 150, 100))
        );
    }

    function test_InitializeV2_RevertsWhenFeeAboveCap() public {
        NFTAuction fresh = _deployV1();
        NFTAuctionV2 implementation = new NFTAuctionV2();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV2.FeeAboveMaximum.selector, uint16(1000)));
        fresh.upgradeToAndCall(
            address(implementation), abi.encodeCall(NFTAuctionV2.initializeV2, (1000e8, 10_000e8, 1001, 150, 100))
        );
    }

    // ------------------------------------------------------------------
    // 费率分档
    // ------------------------------------------------------------------

    function test_GetFeeBps_Boundaries() public view {
        // 分界点本身归入下一档：< 1,000 为 2%，< 10,000 为 1.5%，其余 1%。
        assertEq(auction.getFeeBps(999e8), 200);
        assertEq(auction.getFeeBps(1000e8), 150);
        assertEq(auction.getFeeBps(9999e8), 150);
        assertEq(auction.getFeeBps(10_000e8), 100);
    }

    function test_SetFeeTiers_UpdatesValues() public {
        vm.prank(admin);
        auction.setFeeTiers(500e8, 5000e8, 300, 250, 200);

        assertEq(auction.feeTier1CutoffUsd(), 500e8);
        assertEq(auction.feeTier2CutoffUsd(), 5000e8);
        assertEq(auction.feeTier1Bps(), 300);
        assertEq(auction.feeTier2Bps(), 250);
        assertEq(auction.feeTier3Bps(), 200);
        assertEq(auction.getFeeBps(100e8), 300);
        assertEq(auction.getFeeBps(1000e8), 250);
        assertEq(auction.getFeeBps(6000e8), 200);
    }

    function test_SetFeeTiers_RevertsOnInvalidCutoffs() public {
        vm.prank(admin);
        vm.expectRevert(NFTAuctionV2.InvalidFeeTiers.selector);
        auction.setFeeTiers(5000e8, 5000e8, 200, 150, 100);
    }

    function test_SetFeeTiers_RevertsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV2.FeeAboveMaximum.selector, uint16(1001)));
        auction.setFeeTiers(1000e8, 10_000e8, 200, 1001, 100);
    }

    function test_SetFeeTiers_OnlyOwner() public {
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bidder));
        auction.setFeeTiers(1000e8, 10_000e8, 200, 150, 100);
    }

    function test_SetMaxFeeBps_UpdatesAndValidates() public {
        vm.prank(admin);
        auction.setMaxFeeBps(500);
        assertEq(auction.maxFeeBps(), 500);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV2.FeeAboveMaximum.selector, uint16(10_000)));
        auction.setMaxFeeBps(10_001);
    }

    // ------------------------------------------------------------------
    // 结算收费与提现
    // ------------------------------------------------------------------

    function test_Settle_ChargesTieredFeeAndWithdraws() public {
        vm.prank(seller);
        uint256 auctionId = auction.createAuction(address(nft), 1, START_PRICE_USD, DURATION, address(0));

        vm.prank(bidder);
        auction.bid{ value: 1 ether }(auctionId); // $3,000 -> 1.5%

        vm.warp(block.timestamp + DURATION + 1);
        auction.settle(auctionId);

        uint256 expectedFee = 1 ether * 150 / 10_000;
        assertEq(auction.pendingFees(feeRecipient, address(0)), expectedFee);
        assertEq(auction.pendingProceeds(seller, address(0)), 1 ether - expectedFee);

        uint256 feeRecipientBefore = feeRecipient.balance;
        vm.prank(feeRecipient);
        auction.withdrawFees(address(0));
        assertEq(feeRecipient.balance, feeRecipientBefore + expectedFee);

        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        auction.withdrawProceeds(address(0));
        assertEq(seller.balance, sellerBefore + 1 ether - expectedFee);
    }

    function test_WithdrawFees_RevertsWhenNothingToWithdraw() public {
        vm.prank(feeRecipient);
        vm.expectRevert(NFTAuction.NothingToWithdraw.selector);
        auction.withdrawFees(address(0));
    }

    function test_Settle_ChargesFeeInErc20() public {
        vm.prank(seller);
        uint256 auctionId = auction.createAuction(address(nft), 1, START_PRICE_USD, DURATION, address(usdc));

        usdc.mint(bidder, 20_000e6);
        vm.startPrank(bidder);
        usdc.approve(address(auction), 20_000e6);
        auction.bidWithERC20(auctionId, 20_000e6); // $20,000 -> 1%
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);
        auction.settle(auctionId);

        uint256 expectedFee = 20_000e6 * 100 / 10_000;
        assertEq(auction.pendingFees(feeRecipient, address(usdc)), expectedFee);

        uint256 before = usdc.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        auction.withdrawFees(address(usdc));
        assertEq(usdc.balanceOf(feeRecipient), before + expectedFee);
    }
}
