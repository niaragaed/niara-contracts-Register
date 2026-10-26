// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SignatureRegistryV3} from "../src/v3/SignatureRegistryV3.sol";

/// @notice Deploys SignatureRegistryV3 (commit-reveal + ORB attestation).
///         Env: PRIVATE_KEY, VERIFY_BASE_URL (baked into every receipt, ends in "/")
///         and ORB_ATTESTER (address of the ORB signing key; omit or 0x0 to deploy
///         with ORB permanently off on this deployment).
contract DeploySignatureRegistryV3 is Script {
    function run() external returns (SignatureRegistryV3 registry) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory verifyBaseUrl = vm.envString("VERIFY_BASE_URL");
        address orbAttester = vm.envOr("ORB_ATTESTER", address(0));
        bytes memory url = bytes(verifyBaseUrl);
        require(url.length > 8 && url[url.length - 1] == "/", "VERIFY_BASE_URL must end with /");

        address deployer = vm.addr(deployerKey);
        require(orbAttester != deployer, "ORB_ATTESTER must not be the deploy wallet");
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);
        console.log("Verify base URL:", verifyBaseUrl);
        console.log("ORB attester (0x0 = ORB off):", orbAttester);

        vm.startBroadcast(deployerKey);
        registry = new SignatureRegistryV3(verifyBaseUrl, orbAttester);
        vm.stopBroadcast();

        console.log("SignatureRegistryV3 deployed at:", address(registry));
    }
}
