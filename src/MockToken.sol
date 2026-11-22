// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockToken — minimal mintable ERC20 for the TakeProfit demo.
/// @notice Demo-only: the deployer (owner) can mint. Used twice on
/// Base Sepolia: once as the token being sold (tTOKEN) and once as the
/// mock stablecoin received from a sale (tUSD). No real value.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotOwner(address caller);
    error InsufficientBalance(address from, uint256 have, uint256 want);
    error InsufficientAllowance(address spender, uint256 have, uint256 want);

    constructor(string memory name_, string memory symbol_) {
        owner = msg.sender;
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(from, bal, amount);
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
