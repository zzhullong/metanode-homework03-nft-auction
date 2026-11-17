// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { NFTAuction } from "../src/NFTAuction.sol";
import { NFTAuctionV2 } from "../src/NFTAuctionV2.sol";

/// @notice Upgrades the deployed auction proxy from V1 to V2 and initializes the fee tiers.
/// @dev Env: PRIVATE_KEY (required), DEPLOYMENTS_FILE (optional), FEE_TIER* (optional).
contract UpgradeScript is Script {
    function run() external {
        string memory deploymentsFile = vm.envOr("DEPLOYMENTS_FILE", _defaultDeploymentsFile());
        string memory json = vm.readFile(deploymentsFile);
        address proxy = vm.parseJsonAddress(json, ".auctionProxy");

        uint256 cutoff1Usd = vm.envOr("FEE_TIER1_CUTOFF_USD", uint256(1_000e8));
        uint256 cutoff2Usd = vm.envOr("FEE_TIER2_CUTOFF_USD", uint256(10_000e8));
        uint16 bps1 = uint16(vm.envOr("FEE_TIER1_BPS", uint256(200)));
        uint16 bps2 = uint16(vm.envOr("FEE_TIER2_BPS", uint256(150)));
        uint16 bps3 = uint16(vm.envOr("FEE_TIER3_BPS", uint256(100)));

        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);
        NFTAuctionV2 implementation = new NFTAuctionV2();
        NFTAuctionV2(payable(proxy))
            .upgradeToAndCall(
                address(implementation),
                abi.encodeCall(NFTAuctionV2.initializeV2, (cutoff1Usd, cutoff2Usd, bps1, bps2, bps3))
            );
        vm.stopBroadcast();

        string memory key = "upgrade";
        string memory updated = vm.serializeAddress(key, "v2Implementation", address(implementation));
        vm.writeJson(updated, deploymentsFile, ".v2Implementation");

        console2.log("NFTAuctionV2 impl  ", address(implementation));
        console2.log("Proxy upgraded from", NFTAuction(payable(proxy)).getVersion());
        console2.log("Proxy version now  ", NFTAuctionV2(payable(proxy)).getVersion());
    }

    function _defaultDeploymentsFile() internal view returns (string memory) {
        string memory network = block.chainid == 11_155_111 ? "sepolia" : "local";
        return string.concat("deployments/", network, ".json");
    }
}
