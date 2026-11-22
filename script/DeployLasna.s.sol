// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { TakeProfitReactive } from "../src/TakeProfitReactive.sol";

/// @notice Step B (Lasna): deploy TakeProfitReactive subscribed to the
/// MockPriceOracle + OrderVault (env ORACLE_ADDRESS, VAULT_ADDRESS) and
/// fund its own balance in lREACT (env LREACT_DEPOSIT, default 0.5
/// lREACT) so react() txs and callback requests can be settled from it.
/// Writes deployments/lasna.json.
contract DeployLasna is Script {
    function run() external {
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address vault = vm.envAddress("VAULT_ADDRESS");
        uint256 deposit = vm.envOr("LREACT_DEPOSIT", uint256(0.5 ether));
        uint256 priceTopic0 = uint256(keccak256("PriceUpdate(uint256,uint256)"));
        uint256 createdTopic0 = uint256(keccak256("OrderCreated(uint256,address,address,uint256,uint256,address)"));
        uint256 cancelledTopic0 = uint256(keccak256("OrderCancelled(uint256)"));

        vm.startBroadcast();
        TakeProfitReactive reactive = new TakeProfitReactive(oracle, vault, priceTopic0, createdTopic0, cancelledTopic0);
        (bool funded, ) = payable(address(reactive)).call{ value: deposit }("");
        require(funded, "fund reactive failed");
        vm.stopBroadcast();

        console.log("TakeProfitReactive:", address(reactive));
        console.log("Deposited lREACT to reactive:", deposit);
        string memory json = string.concat(
            '{"chain":"lasna","chainId":5318007,"reactive":"',
            vm.toString(address(reactive)),
            '","oracle":"',
            vm.toString(oracle),
            '","vault":"',
            vm.toString(vault),
            '"}'
        );
        vm.writeJson(json, "deployments/lasna.json");
        console.log("Wrote deployments/lasna.json");
    }
}
