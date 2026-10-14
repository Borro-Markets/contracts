// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

/// @title BorroHookShare
/// @notice The ERC-20 share of one BorroHook pool's liquidity. Only its hook mints and burns; holders move it
///         like any token. One clone per pool, made by the hook when the pool is registered.
contract BorroHookShare {
    address public hook;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error OnlyHook();
    error AlreadySet();

    /// @dev The implementation itself can never be initialized: its hook is set to itself here.
    constructor() {
        hook = address(this);
    }

    function initialize(string calldata name_, string calldata symbol_) external {
        if (hook != address(0)) revert AlreadySet();
        hook = msg.sender;
        name = name_;
        symbol = symbol_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        balanceOf[from] -= amount;
        unchecked {
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
