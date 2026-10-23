// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SignatureRegistryV2} from "../src/v2/SignatureRegistryV2.sol";
import {TransferableRecordRegistry} from "../src/mletr/TransferableRecordRegistry.sol";

/// @notice Deploys SignatureRegistryV2 and TransferableRecordRegistry on one network.
///
/// Required env:
///   PRIVATE_KEY      deployer key (the dedicated Register deployer, not the PMEs one)
///   VERIFY_BASE_URL  verification page prefix for this network, ending in "/",
///                    e.g. https://niara-register.vercel.app/verify/sepolia/
///
/// Run with:
///   forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast
///
/// VERIFY_BASE_URL is baked into every receipt's metadata and cannot be changed
/// after deployment, so use the production domain and the network slug the
/// site uses (sepolia, base-sepolia, robinhood-testnet, hyperevm-testnet, tempo-testnet).
contract DeployV2 is Script {
    function run() external returns (SignatureRegistryV2 registry, TransferableRecordRegistry etr) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory verifyBaseUrl = vm.envString("VERIFY_BASE_URL");
        bytes memory url = bytes(verifyBaseUrl);
        require(url.length > 8 && url[url.length - 1] == "/", "VERIFY_BASE_URL must end with /");

        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Verify base URL:", verifyBaseUrl);

        vm.startBroadcast(deployerKey);
        registry = new SignatureRegistryV2(verifyBaseUrl);
        etr = new TransferableRecordRegistry();
        vm.stopBroadcast();

        console.log("SignatureRegistryV2 deployed at:", address(registry));
        console.log("TransferableRecordRegistry deployed at:", address(etr));
    }
}
