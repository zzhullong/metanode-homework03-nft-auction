// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { NFTAuction } from "../src/NFTAuction.sol";
import { AggregatorV3Interface } from "../src/interfaces/AggregatorV3Interface.sol";

/// @dev Optional: runs only when SEPOLIA_RPC_URL is set, otherwise skipped.
contract NFTAuctionForkTest is Test {
    /// @dev Chainlink ETH/USD feed on Sepolia; re-check before running.
    address internal constant ETH_USD_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    NFTAuction internal auction;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        NFTAuction implementation = new NFTAuction();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(NFTAuction.initialize, (address(this), address(this)))
        );
        auction = NFTAuction(payable(address(proxy)));
        auction.setPriceFeed(address(0), ETH_USD_SEPOLIA);
    }

    function test_Fork_LiveEthUsdFeed() public view {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(ETH_USD_SEPOLIA).latestRoundData();
        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertGt(auction.getUsdValue(address(0), 1 ether), 0);
    }
}
