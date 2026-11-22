// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { OrderExecutor } from "../src/OrderExecutor.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

/// @notice Step C (Base Sepolia): deploy OrderExecutor, authenticated to
/// the TakeProfitReactive contract (env REACTIVE_ADDRESS), and point the
/// OrderVault at it (env VAULT_ADDRESS, ORACLE_ADDRESS). Funded with
/// Sepolia ETH (env EXECUTOR_FUND, default 0.001 ETH) so callback
/// billing can be settled via coverDebt(). Writes
/// deployments/executor.json.
contract DeployExecutor is Script {
    address internal constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        uint256 fund = vm.envOr("EXECUTOR_FUND", uint256(0.001 ether));

        vm.startBroadcast();
        OrderExecutor executor =
            new OrderExecutor{ value: fund }(IPayable(payable(BASE_PROXY)), reactive, vault, oracle);
        // Point the vault at its executor (deployer is the vault owner).
        (bool ok, ) = vault.call(abi.encodeWithSignature("setExecutor(address)", address(executor)));
        require(ok, "setExecutor failed");
        vm.stopBroadcast();

        console.log("OrderExecutor:", address(executor));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"executor":"',
            vm.toString(address(executor)),
            '","reactive":"',
            vm.toString(reactive),
            '","vault":"',
            vm.toString(vault),
            '","oracle":"',
            vm.toString(oracle),
            '"}'
        );
        vm.writeJson(json, "deployments/executor.json");
        console.log("Wrote deployments/executor.json");
    }
}
