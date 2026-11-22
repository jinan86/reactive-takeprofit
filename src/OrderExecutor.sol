// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { OrderVault } from "./OrderVault.sol";
import { MockPriceOracle } from "./MockPriceOracle.sol";

/// @title OrderExecutor — authenticated callback that settles take-profit orders.
/// @notice Deployed on Base Sepolia. Receives callbacks requested by
/// TakeProfitReactive on Lasna through the Base Sepolia callback proxy
/// (0x476F44b11F5C942c58f4c8E3d0300E5710743585). The proxy overwrites the
/// first 160 bits of the payload with the reactive contract's address, so
/// execute() sees (reactive, orderId) and both guards apply:
/// onlyServiceProvider (caller is the proxy) + onlyCallbackSender (the
/// injected address is the authorized reactive contract).
/// Before settling, the executor re-checks the live condition from the
/// vault and the oracle — the order must still be active and unexecuted,
/// and the current price must still be at or above the target — and then
/// calls vault.executeOrder(), which performs the same checks again and
/// pays the proceeds. Fail closed at every step; an order can never
/// execute twice.
/// Funding: callbacks are billed to this contract in Sepolia ETH — keep it
/// funded by a direct transfer to its balance; coverDebt() settles debt
/// from that balance.
contract OrderExecutor is AbstractCallback {
    OrderVault public immutable vault;
    MockPriceOracle public immutable oracle;

    event OrderSettled(uint256 indexed id, uint256 price, uint256 proceeds);

    error PriceBelowTarget(uint256 price, uint256 targetPrice);

    constructor(IPayable callbackProxy_, address callbackSender_, address vault_, address oracle_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        vault = OrderVault(vault_);
        oracle = MockPriceOracle(oracle_);
    }

    /// @notice Settles outstanding debt to the callback proxy from this
    /// contract's own balance. Anyone can call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Settle order `orderId_` on behalf of the reactive contract.
    /// Only reachable via an authenticated callback from TakeProfitReactive.
    function execute(address reactive_, uint256 orderId_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
        returns (uint256 proceeds)
    {
        OrderVault.Order memory o = vault.getOrder(orderId_);
        uint256 price = oracle.price();
        if (price < o.targetPrice) revert PriceBelowTarget(price, o.targetPrice);
        proceeds = vault.executeOrder(orderId_, price);
        emit OrderSettled(orderId_, price, proceeds);
    }
}
