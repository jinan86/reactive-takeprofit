// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title TakeProfitReactive — the deterministic take-profit engine.
/// @notice Deployed on Lasna (chain 5318007). Subscribes to two contracts
/// on Base Sepolia (chain 84532):
///  - MockPriceOracle.PriceUpdate(uint256,uint256) — LOG1, data =
///    (price, updatedAt), price in 8 decimals.
///  - OrderVault.OrderCreated(uint256,address,address,uint256,uint256,address)
///    — LOG4: topic1 = id, topic2 = owner, topic3 = token,
///    data = (amount, targetPrice, payee).
///  - OrderVault.OrderCancelled(uint256) — LOG2: topic1 = id.
/// The contract mirrors active orders on Lasna. On every PriceUpdate it
/// scans the mirrored active orders; for each order whose target price
/// has been reached (price >= targetPrice) it requests a callback to the
/// OrderExecutor, which re-checks the condition on Base Sepolia and
/// settles the sale. No bot, no server, no AI anywhere in this loop —
/// the only rule is a price threshold.
/// @dev Duplicate callbacks are harmless by design: if the price stays
/// above target and another PriceUpdate arrives, a second callback is
/// requested, but the executor refuses to execute an already-executed
/// order (fail closed). The scan is bounded: at most MAX_SCAN mirrored
/// order ids are inspected per PriceUpdate (oldest first), so react()
/// gas stays bounded. With many live orders, keep the active set small
/// or re-create orders after execution; the demo uses a handful.
/// Funding: keep lREACT in this contract's own balance (plain transfer);
/// the system contract settles debt from it via pay() / coverDebt().
contract TakeProfitReactive is AbstractReactive {
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Callback gas limit. Minimum enforced by the network is
    /// 100,000. The Base Sepolia proxy withholds _extraGas (80,000) +
    /// _maxChargeGas (50,000) before forwarding, so 300,000 leaves ample
    /// room for OrderExecutor.execute.
    uint64 public constant CALLBACK_GAS_LIMIT = 300_000;

    /// @notice Max mirrored order ids scanned per PriceUpdate.
    uint256 public constant MAX_SCAN = 50;

    struct MirroredOrder {
        uint256 targetPrice;
        uint256 amount;
        address payee;
        bool active;
    }

    address public immutable oracle;
    address public immutable vault;
    uint256 public immutable priceTopic0;
    uint256 public immutable createdTopic0;
    uint256 public immutable cancelledTopic0;

    address public owner;
    address public executor;

    mapping(uint256 => MirroredOrder) public mirrored;
    uint256[] public activeIds;

    uint256 public reactCount;
    uint256 public actedCount;
    uint256 public lastPrice;
    uint256 public lastPriceUpdatedAt;

    event OrderMirrored(uint256 indexed id, uint256 targetPrice, uint256 amount, address payee);
    event OrderUnmirrored(uint256 indexed id);
    event OrderTriggered(uint256 indexed id, uint256 price, uint256 targetPrice);
    event PriceSeen(uint256 price, uint256 triggered);
    event ExecutorSet(address indexed executor);

    error NotOwner(address caller);

    constructor(address oracle_, address vault_, uint256 priceTopic0_, uint256 createdTopic0_, uint256 cancelledTopic0_) {
        owner = msg.sender;
        oracle = oracle_;
        vault = vault_;
        priceTopic0 = priceTopic0_;
        createdTopic0 = createdTopic0_;
        cancelledTopic0 = cancelledTopic0_;
        SYSTEM.subscribe(BASE_SEPOLIA_CHAIN_ID, oracle_, priceTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE_SEPOLIA_CHAIN_ID, vault_, createdTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE_SEPOLIA_CHAIN_ID, vault_, cancelledTopic0_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Set (or change) the callback recipient. Owner-only.
    function setExecutor(address executor_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    /// @notice Settles outstanding debt to the system contract from this
    /// contract's own balance. Anyone can call it.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Number of mirrored order ids (active + inactive history).
    function mirroredCount() external view returns (uint256) {
        return activeIds.length;
    }

    /// @inheritdoc IReactive
    /// @dev Never revert: a reverting react() is still billed, and a
    /// below-target price is a normal outcome, not an error.
    /// Dispatch is on topic0 ONLY — deliberately no opCode check. The
    /// opCode is the LOGn index of the event (PriceUpdate is LOG1 = 1,
    /// OrderCancelled is LOG2 = 2, OrderCreated is LOG4 = 4), so copying
    /// Sentinel's single-event `opCode != 3` gate would reject all three
    /// of our events (that exact bug shipped in v1: the network billed
    /// react() calls, but every one returned early and reactCount stayed
    /// 0). A matching topic0 already identifies the event uniquely.
    function react(LogRecord memory log_) external override onlySystem {
        if (log_.topic0 == priceTopic0) {
            (uint256 price, uint256 updatedAt) = abi.decode(log_.data, (uint256, uint256));
            reactCount++;
            lastPrice = price;
            lastPriceUpdatedAt = updatedAt;
            uint256 triggered = 0;
            if (executor != address(0)) {
                uint256 n = activeIds.length;
                if (n > MAX_SCAN) n = MAX_SCAN;
                for (uint256 i = 0; i < n; i++) {
                    uint256 id = activeIds[i];
                    MirroredOrder storage o = mirrored[id];
                    if (!o.active) continue;
                    if (price < o.targetPrice) continue;
                    bytes memory payload = abi.encodeWithSignature("execute(address,uint256)", address(0), id);
                    SYSTEM.requestCallbackV_1_0(
                        ISystemContract.CallbackConfiguration_V_1_0({
                            chainId: BASE_SEPOLIA_CHAIN_ID,
                            recipient: executor,
                            gasLimit: CALLBACK_GAS_LIMIT,
                            payload: payload
                        })
                    );
                    triggered++;
                    actedCount++;
                    emit OrderTriggered(id, price, o.targetPrice);
                }
            }
            emit PriceSeen(price, triggered);
        } else if (log_.topic0 == createdTopic0) {
            uint256 id = log_.topic1;
            (uint256 amount, uint256 targetPrice, address payee) = abi.decode(log_.data, (uint256, uint256, address));
            mirrored[id] = MirroredOrder({ targetPrice: targetPrice, amount: amount, payee: payee, active: true });
            activeIds.push(id);
            reactCount++;
            emit OrderMirrored(id, targetPrice, amount, payee);
        } else if (log_.topic0 == cancelledTopic0) {
            uint256 id = log_.topic1;
            mirrored[id].active = false;
            reactCount++;
            emit OrderUnmirrored(id);
        }
    }
}
