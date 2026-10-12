// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only hostile ERC20. No deployment configuration uses this contract.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        RevertTransfer,
        ShortTransfer,
        Callback
    }

    Mode public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor() ERC20("Hostile test token", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configure(Mode mode_, address target, bytes calldata data) external {
        mode = mode_;
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.RevertTransfer) revert("blocked transfer");
        if (mode == Mode.Callback) _callback();
        return super.transfer(to, mode == Mode.ShortTransfer ? amount - 1 : amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.RevertTransfer) revert("blocked transfer");
        if (mode == Mode.Callback) _callback();
        return super.transferFrom(from, to, mode == Mode.ShortTransfer ? amount - 1 : amount);
    }

    function _callback() private {
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        balanceOf[msg.sender] = 1_000_000 ether;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
