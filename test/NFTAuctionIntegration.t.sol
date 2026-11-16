// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MetaNFT } from "../src/MetaNFT.sol";
import { NFTAuction } from "../src/NFTAuction.sol";
import { NFTAuctionV2 } from "../src/NFTAuctionV2.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockV3Aggregator } from "../src/mocks/MockV3Aggregator.sol";

/// @dev Cross-currency end-to-end flows, including a mid-auction upgrade to V2.
contract NFTAuctionIntegrationTest is Test {
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

    function _list(address paymentToken) internal returns (uint256 auctionId) {
        vm.prank(seller);
        auctionId = auction.createAuction(address(nft), NFT_ID, START_PRICE_USD, DURATION, paymentToken);
    }

    function _warpPastEnd() internal {
        vm.warp(block.timestamp + DURATION + 1);
    }

    function _upgradeToV2() internal returns (NFTAuctionV2) {
        NFTAuctionV2 implementation = new NFTAuctionV2();
        vm.prank(admin);
        auction.upgradeToAndCall(
            address(implementation), abi.encodeCall(NFTAuctionV2.initializeV2, (1000e8, 10_000e8, 200, 150, 100))
        );
        return NFTAuctionV2(payable(address(auction)));
    }

    /// @dev One auction, two bidders in different currencies, every pull-based payout exercised.
    function test_Integration_TwoBiddersFullFlow() public {
        uint256 auctionId = _list(address(usdc));

        vm.prank(bidder1);
        auction.bid{ value: 0.5 ether }(auctionId); // $1,500

        vm.startPrank(bidder2);
        usdc.approve(address(auction), 2000e6);
        auction.bidWithERC20(auctionId, 2000e6); // $2,000, outbids bidder1
        vm.stopPrank();

        _warpPastEnd();
        auction.settle(auctionId);

        assertEq(nft.ownerOf(NFT_ID), bidder2);
        assertEq(auction.pendingProceeds(seller, address(usdc)), 2000e6);
        assertEq(auction.pendingRefunds(auctionId, bidder1, address(0)), 0.5 ether);

        uint256 bidder1EthBefore = bidder1.balance;
        vm.prank(bidder1);
        auction.withdrawRefund(auctionId);
        assertEq(bidder1.balance, bidder1EthBefore + 0.5 ether);

        uint256 sellerUsdcBefore = usdc.balanceOf(seller);
        vm.prank(seller);
        auction.withdrawProceeds(address(usdc));
        assertEq(usdc.balanceOf(seller), sellerUsdcBefore + 2000e6);

        // Everything owed has been paid out except the winning bid now held by the seller.
        assertEq(usdc.balanceOf(address(auction)), 0);
        assertEq(address(auction).balance, 0);
    }

    function test_Integration_UpgradeMidAuctionPreservesStorage() public {
        uint256 auctionId = _list(address(0));
        vm.prank(bidder1);
        auction.bid{ value: 1 ether }(auctionId);

        NFTAuctionV2 upgraded = _upgradeToV2();

        assertEq(upgraded.getVersion(), "NFTAuction V2");
        assertEq(upgraded.nextAuctionId(), 1);

        NFTAuction.AuctionView memory view_ = upgraded.getAuction(auctionId);
        assertEq(view_.seller, seller);
        assertEq(view_.nft, address(nft));
        assertEq(view_.highestBidder, bidder1);
        assertEq(view_.highestBidAmount, 1 ether);
        assertEq(view_.highestBidUsd, 3000e8);
    }

    function test_Integration_UpgradeThenSettleChargesV2Fee() public {
        uint256 auctionId = _list(address(0));
        vm.prank(bidder1);
        auction.bid{ value: 1 ether }(auctionId); // $3,000 falls in the 1.5% tier

        NFTAuctionV2 upgraded = _upgradeToV2();
        assertEq(upgraded.getFeeBps(3000e8), 150);

        _warpPastEnd();
        upgraded.settle(auctionId);

        uint256 expectedFee = 1 ether * 150 / 10_000; // 0.015 ether
        assertEq(upgraded.pendingFees(feeRecipient, address(0)), expectedFee);
        assertEq(upgraded.pendingProceeds(seller, address(0)), 1 ether - expectedFee);
        assertEq(nft.ownerOf(NFT_ID), bidder1);

        uint256 feeRecipientBefore = feeRecipient.balance;
        vm.prank(feeRecipient);
        upgraded.withdrawFees(address(0));
        assertEq(feeRecipient.balance, feeRecipientBefore + expectedFee);

        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        upgraded.withdrawProceeds(address(0));
        assertEq(seller.balance, sellerBefore + 1 ether - expectedFee);

        assertEq(address(auction).balance, 0);
    }

    /// @dev Whatever the bid amounts, the contract must never owe more than it holds:
    /// after every claim is withdrawn the balance must be exactly zero.
    function testFuzz_FundsConservation(uint96 firstBid, uint96 bump) public {
        firstBid = uint96(bound(firstBid, 0.4 ether, 20 ether));
        bump = uint96(bound(bump, 0.4 ether, 20 ether));

        uint256 auctionId = _list(address(0));

        vm.prank(bidder1);
        auction.bid{ value: firstBid }(auctionId);
        vm.prank(bidder2);
        auction.bid{ value: firstBid + bump }(auctionId);

        _warpPastEnd();
        auction.settle(auctionId);

        vm.prank(bidder1);
        auction.withdrawRefund(auctionId);
        vm.prank(seller);
        auction.withdrawProceeds(address(0));

        assertEq(nft.ownerOf(NFT_ID), bidder2);
        assertEq(address(auction).balance, 0, "contract still holds funds");
    }
}
