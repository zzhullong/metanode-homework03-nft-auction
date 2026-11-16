// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MetaNFT } from "../src/MetaNFT.sol";

contract MetaNFTTest is Test {
    MetaNFT internal nft;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        nft = new MetaNFT();
    }

    function test_Mint_IncrementsIdAndSetsOwner() public {
        uint256 id = nft.mint(alice, "ipfs://token/1.json");
        assertEq(id, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.totalMinted(), 1);

        uint256 second = nft.mint(bob, "ipfs://token/2.json");
        assertEq(second, 2);
        assertEq(nft.ownerOf(2), bob);
    }

    function test_Mint_SetsTokenURI() public {
        uint256 id = nft.mint(alice, "ipfs://token/1.json");
        assertEq(nft.tokenURI(id), "ipfs://token/1.json");
    }

    function test_Mint_RevertsForZeroAddress() public {
        vm.expectRevert(MetaNFT.MintToZeroAddress.selector);
        nft.mint(address(0), "ipfs://token/1.json");
    }

    function test_Transfer_UpdatesOwner() public {
        uint256 id = nft.mint(alice, "ipfs://token/1.json");

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);

        assertEq(nft.ownerOf(id), bob);
    }

    function test_TokenURI_RevertsForNonexistentToken() public {
        vm.expectRevert();
        nft.tokenURI(999);
    }
}
