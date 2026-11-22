// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MockToken } from "./MockToken.sol";

/// @title OrderVault — holds take-profit orders and their tokens.
/// @notice Deployed on Base Sepolia. A user calls createOrder() once
/// ("sell X of my token when the price reaches Y") and the tokens move
/// into this vault (transferFrom — approve first). The order stays
/// locked until it is executed by the authorized OrderExecutor (via a
/// Reactive callback) or cancelled by its owner for a full refund.
/// @dev Sale proceeds are paid in the mock stablecoin (tUSD) from this
/// vault's own balance, at the oracle price at execution time:
/// proceeds = amount * price / 1e8. The vault must be funded with
/// enough stablecoin before orders can execute (the deploy script mints
/// a large proceeds pool into it). This is a DEMO settlement model —
/// production would route the sale through a DEX instead of a
/// pre-funded pool. No lending, no collateral, no debt, no health
/// factor anywhere in this contract: it only holds orders and tokens.
contract OrderVault {
    struct Order {
        address owner;
        address token;
        uint256 amount;
        uint256 targetPrice; // 8 decimals, Chainlink style
        address payee;
        bool active;
        bool executed;
    }

    MockToken public immutable stablecoin;
    address public owner;
    address public executor;

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;

    event OrderCreated(
        uint256 indexed id, address indexed owner, address indexed token, uint256 amount, uint256 targetPrice, address payee
    );
    event OrderCancelled(uint256 indexed id);
    event OrderExecuted(uint256 indexed id, address indexed payee, uint256 proceeds);
    event ExecutorSet(address indexed executor);

    error NotOwner(address caller);
    error NotExecutor(address caller);
    error OrderNotActive(uint256 id);
    error OrderAlreadyExecuted(uint256 id);
    error PriceBelowTarget(uint256 price, uint256 targetPrice);
    error InvalidAmount(uint256 amount);
    error InvalidTargetPrice(uint256 targetPrice);
    error InvalidPayee(address payee);
    error InsufficientProceeds(uint256 have, uint256 want);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
        _;
    }

    constructor(address stablecoin_) {
        owner = msg.sender;
        stablecoin = MockToken(stablecoin_);
    }

    /// @notice Point the vault at its (single) authorized executor.
    /// Owner-only; called once at deploy time.
    function setExecutor(address executor_) external onlyOwner {
        executor = executor_;
        emit ExecutorSet(executor_);
    }

    /// @notice Lock `amount` of `token` into a take-profit order that
    /// sells when the oracle price reaches `targetPrice` (8 decimals).
    /// Proceeds go to `payee`. Caller must approve the vault first.
    function createOrder(address token_, uint256 amount_, uint256 targetPrice_, address payee_)
        external
        returns (uint256 id)
    {
        if (amount_ == 0) revert InvalidAmount(amount_);
        if (targetPrice_ == 0) revert InvalidTargetPrice(targetPrice_);
        if (payee_ == address(0)) revert InvalidPayee(payee_);
        id = nextOrderId++;
        orders[id] =
            Order({ owner: msg.sender, token: token_, amount: amount_, targetPrice: targetPrice_, payee: payee_, active: true, executed: false });
        require(MockToken(token_).transferFrom(msg.sender, address(this), amount_), "transferFrom failed");
        emit OrderCreated(id, msg.sender, token_, amount_, targetPrice_, payee_);
    }

    /// @notice Cancel an active order. Owner of the order only; the
    /// locked tokens are refunded in full. A cancelled order can never
    /// execute afterwards.
    function cancelOrder(uint256 id) external {
        Order storage o = orders[id];
        if (!o.active || o.executed) revert OrderNotActive(id);
        if (msg.sender != o.owner) revert NotOwner(msg.sender);
        o.active = false;
        require(MockToken(o.token).transfer(o.owner, o.amount), "refund failed");
        emit OrderCancelled(id);
    }

    /// @notice Execute an order at the given oracle `price_` (8 decimals).
    /// Only the authorized executor (OrderExecutor, reached via a Reactive
    /// callback). Re-checks everything — fail closed: the order must still
    /// be active and unexecuted, and the price must still be at or above
    /// the target. Pays `amount * price / 1e8` stablecoin to the payee.
    function executeOrder(uint256 id, uint256 price_) external onlyExecutor returns (uint256 proceeds) {
        Order storage o = orders[id];
        if (o.executed) revert OrderAlreadyExecuted(id);
        if (!o.active) revert OrderNotActive(id);
        if (price_ < o.targetPrice) revert PriceBelowTarget(price_, o.targetPrice);
        proceeds = (o.amount * price_) / 1e8;
        uint256 have = stablecoin.balanceOf(address(this));
        if (have < proceeds) revert InsufficientProceeds(have, proceeds);
        o.executed = true;
        o.active = false;
        require(stablecoin.transfer(o.payee, proceeds), "proceeds transfer failed");
        emit OrderExecuted(id, o.payee, proceeds);
    }

    /// @notice Read a full order record.
    function getOrder(uint256 id) external view returns (Order memory) {
        return orders[id];
    }
}
