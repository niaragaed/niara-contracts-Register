// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RegistroAssinaturas} from "../src/registro/RegistroAssinaturas.sol";

/// @notice Deploys RegistroAssinaturas.
/// Run with: forge script script/DeployRegistro.s.sol --rpc-url sepolia --broadcast
/// (the script name is kept because the deploy receipts in broadcast/ are stored under it)
contract DeployRegistro is Script {
    function run() external returns (RegistroAssinaturas registry) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);

        vm.startBroadcast(deployerKey);
        registry = new RegistroAssinaturas();
        vm.stopBroadcast();

        console.log("RegistroAssinaturas deployed at:", address(registry));
    }
}
