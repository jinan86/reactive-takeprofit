// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceOracle — demo price feed for TakeProfit.
/// @notice Deployed on Base Sepolia. The owner (demo operator) publishes
/// prices with setPrice(); each publish emits PriceUpdate, which the
/// Lasna reactive contract subscribes to. Prices use 8 decimals in the
/// Chainlink style: 2000_00000000 = $2,000.
/// @dev THIS IS A MOCK FOR THE DEMO. In production this would be replaced
/// by a real feed (Chainlink price feed or a Uniswap TWAP oracle) with
/// the same event shape; the reactive contract and executor only read
/// the PriceUpdate event and the current price, so the swap is a
/// drop-in at the oracle address.
contract MockPriceOracle {
    uint256 public price;
    uint256 public updatedAt;

    address public owner;

    event PriceUpdate(uint256 price, uint256 updatedAt);

    error NotOwner(address caller);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor(uint256 initialPrice_) {
        owner = msg.sender;
        price = initialPrice_;
        updatedAt = block.timestamp;
    }

    /// @notice Publish a new price (8 decimals). Owner-only, demo only.
    function setPrice(uint256 price_) external onlyOwner {
        price = price_;
        updatedAt = block.timestamp;
        emit PriceUpdate(price_, block.timestamp);
    }
}
