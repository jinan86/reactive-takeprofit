// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceOracle } from "../src/MockPriceOracle.sol";
import { OrderVault } from "../src/OrderVault.sol";

/// @notice Step A (Base Sepolia): deploy the TakeProfit base stack.
/// Deploys tUSD + tTOKEN mock tokens, MockPriceOracle (initial price
/// $1500, 8 decimals), and OrderVault (stablecoin = tUSD). Funds the
/// vault with a 1,000,000 tUSD proceeds pool and mints 1000 tTOKEN to the
/// deployer for demo orders. Writes deployments/base.json.
contract DeployBase is Script {
    function run() external {
        vm.startBroadcast();
        MockToken tUSD = new MockToken("TakeProfit Demo USD", "tUSD");
        MockToken tTOKEN = new MockToken("TakeProfit Demo Token", "tTOKEN");
        MockPriceOracle oracle = new MockPriceOracle(1500_00000000);
        OrderVault vault = new OrderVault(address(tUSD));
        tUSD.mint(address(vault), 1_000_000 ether);
        tTOKEN.mint(msg.sender, 1000 ether);
        vm.stopBroadcast();

        console.log("tUSD:", address(tUSD));
        console.log("tTOKEN:", address(tTOKEN));
        console.log("MockPriceOracle:", address(oracle));
        console.log("OrderVault:", address(vault));
        string memory json = string.concat(
            '{"chain":"base_sepolia","chainId":84532,"tUSD":"',
            vm.toString(address(tUSD)),
            '","tTOKEN":"',
            vm.toString(address(tTOKEN)),
            '","oracle":"',
            vm.toString(address(oracle)),
            '","vault":"',
            vm.toString(address(vault)),
            '"}'
        );
        vm.writeJson(json, "deployments/base.json");
        console.log("Wrote deployments/base.json");
    }
}
