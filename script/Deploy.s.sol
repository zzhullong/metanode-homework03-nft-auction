// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { MetaNFT } from "../src/MetaNFT.sol";
import { NFTAuction } from "../src/NFTAuction.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockV3Aggregator } from "../src/mocks/MockV3Aggregator.sol";

/// @notice Deploys MetaNFT, a mock USDC, price feeds and the NFTAuction UUPS proxy.
/// @dev Env: PRIVATE_KEY (required), FEE_RECIPIENT (optional), ETH_USD_FEED (optional).
contract DeployScript is Script {
    /// @dev Chainlink ETH/USD aggregator on Sepolia.
    address internal constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        bool onSepolia = block.chainid == 11_155_111;

        vm.startBroadcast(privateKey);

        MetaNFT nft = new MetaNFT();
        MockERC20 usdc = new MockERC20("Mock USD Coin", "mUSDC", 6);

        NFTAuction implementation = new NFTAuction();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(NFTAuction.initialize, (deployer, feeRecipient))
        );
        NFTAuction auction = NFTAuction(payable(address(proxy)));

        // The mock USDC has no official Chainlink feed, so pair it with a mock aggregator.
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);

        // ETH/USD uses the live Sepolia feed on testnet and a mock locally.
        address ethUsdFeed =
            onSepolia ? vm.envOr("ETH_USD_FEED", SEPOLIA_ETH_USD_FEED) : address(new MockV3Aggregator(8, 3000e8));

        auction.setPriceFeed(address(0), ethUsdFeed);
        auction.setPriceFeed(address(usdc), address(usdcFeed));

        usdc.mint(deployer, 1_000_000e6);
        uint256 demoTokenId = nft.mint(deployer, "ipfs://metanode-homework03/demo.json");

        vm.stopBroadcast();

        _writeDeployment(
            deployer,
            address(nft),
            address(usdc),
            address(usdcFeed),
            ethUsdFeed,
            address(implementation),
            address(auction),
            demoTokenId
        );

        console2.log("MetaNFT            ", address(nft));
        console2.log("MockERC20 (USDC)   ", address(usdc));
        console2.log("MockV3Aggregator   ", address(usdcFeed));
        console2.log("ETH/USD feed       ", ethUsdFeed);
        console2.log("NFTAuction impl    ", address(implementation));
        console2.log("NFTAuction proxy   ", address(auction));
        console2.log("Demo NFT tokenId   ", demoTokenId);
    }

    function _writeDeployment(
        address deployer,
        address nft,
        address usdc,
        address usdcFeed,
        address ethUsdFeed,
        address implementation,
        address auction,
        uint256 demoTokenId
    ) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "metaNFT", nft);
        vm.serializeAddress(key, "mockUSDC", usdc);
        vm.serializeAddress(key, "usdcUsdFeed", usdcFeed);
        vm.serializeAddress(key, "ethUsdFeed", ethUsdFeed);
        vm.serializeAddress(key, "auctionImplementation", implementation);
        vm.serializeUint(key, "demoTokenId", demoTokenId);
        string memory json = vm.serializeAddress(key, "auctionProxy", auction);

        vm.writeJson(json, _deploymentsFile());
    }

    function _deploymentsFile() internal view returns (string memory) {
        string memory network = block.chainid == 11_155_111 ? "sepolia" : "local";
        return string.concat("deployments/", network, ".json");
    }
}
