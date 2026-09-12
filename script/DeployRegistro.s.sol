// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RegistroAssinaturas} from "../src/registro/RegistroAssinaturas.sol";

/// @notice Deploy do RegistroAssinaturas na Sepolia.
/// Rodar com: forge script script/DeployRegistro.s.sol --rpc-url sepolia --broadcast
contract DeployRegistro is Script {
    function run() external returns (RegistroAssinaturas registro) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Saldo do deployer (wei):", deployer.balance);

        vm.startBroadcast(deployerKey);
        registro = new RegistroAssinaturas();
        vm.stopBroadcast();

        console.log("RegistroAssinaturas deployado em:", address(registro));
    }
}
