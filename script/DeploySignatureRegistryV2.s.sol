// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SignatureRegistryV2} from "../src/v2/SignatureRegistryV2.sol";

/// @notice Deploys only SignatureRegistryV2 (e.g. after a change to it), leaving
///         TransferableRecordRegistry where it is. Same env as DeployV2.s.sol:
///         PRIVATE_KEY and VERIFY_BASE_URL (baked into every receipt, ends in "/").
contract DeploySignatureRegistryV2 is Script {
    function run() external returns (SignatureRegistryV2 registry) {
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
        vm.stopBroadcast();

        console.log("SignatureRegistryV2 deployed at:", address(registry));
    }
}
