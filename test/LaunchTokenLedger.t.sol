// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract TokenLedgerHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    uint256[4] public balances;
    uint256[4][4] public allowances;

    constructor(LaunchToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < 4; ++i) {
            balances[i] = 1e27 / 4;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        allowances[owner][spender] = amount;
    }

    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], type(uint256).max));
        allowances[owner][spender] = type(uint256).max;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 spender = spenderSeed % 4;
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowed = allowances[from][spender];
        uint256 available = balances[from] < allowed ? balances[from] : allowed;
        uint256 amount = bound(amountSeed, 0, available);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[from], actors[to], amount));
        balances[from] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[from][spender] -= amount;
    }

    function overspendBalance(uint256 fromSeed, uint256 toSeed) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        vm.prank(actors[from]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[from], balances[from], balances[from] + 1
            )
        );
        token.transfer(actors[to], balances[from] + 1);
    }

    function overspendAllowance(uint256 fromSeed, uint256 spenderSeed) external {
        uint256 from = fromSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 allowed = allowances[from][spender];
        if (allowed == type(uint256).max) {
            vm.prank(actors[from]);
            token.approve(actors[spender], 0);
            allowances[from][spender] = 0;
            allowed = 0;
        }
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowed, allowed + 1
            )
        );
        token.transferFrom(actors[from], actors[spender], allowed + 1);
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 4;
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(actors[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenLedgerInvariantTest is Test {
    LaunchToken private token;
    TokenLedgerHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        address[4] memory actors;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("token ledger actor ", vm.toString(i)));
            token.transfer(actors[i], 1e27 / 4);
        }
        handler = new TokenLedgerHandler(token, actors);
        handler.approve(0, 1, 1_000 ether);
        handler.approveUnlimited(2, 3);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.approveUnlimited.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.overspendBalance.selector;
        selectors[5] = handler.overspendAllowance.selector;
        selectors[6] = handler.transferToZero.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyBalancesAndAllowancesMatchIndependentLedger() public view {
        uint256 supply;
        for (uint256 owner; owner < 4; ++owner) {
            address account = handler.actors(owner);
            assertEq(token.balanceOf(account), handler.balances(owner));
            supply += token.balanceOf(account);
            for (uint256 spender; spender < 4; ++spender) {
                assertEq(token.allowance(account, handler.actors(spender)), handler.allowances(owner, spender));
            }
        }
        assertEq(supply, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }
}

contract LaunchTokenLedgerEdgesTest is Test {
    LaunchToken private token;
    address private owner;
    address private spender;
    address private recipient;

    function setUp() public {
        token = new LaunchToken();
        owner = makeAddr("token owner");
        spender = makeAddr("token spender");
        recipient = makeAddr("token recipient");
        token.transfer(owner, 1e27);
    }

    function test_zeroTransferFromWithoutApprovalEmitsTransferAndChangesNothing() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(owner, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, 0));
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(owner), 1e27);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_infiniteAllowanceSurvivesWholeSupplyTransferAndFiniteReplacement() public {
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1e27);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(recipient), 1e27);
        assertEq(token.allowance(owner, spender), type(uint256).max);
        vm.prank(recipient);
        token.transfer(owner, 1e27);
        vm.prank(owner);
        token.approve(spender, 1);
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        assertEq(token.allowance(owner, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(owner, recipient, 1);
    }

    function test_failedBalanceCheckRestoresSpentAllowance() public {
        vm.prank(owner);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 1e27, 1e27 + 1));
        token.transferFrom(owner, recipient, 1e27 + 1);
        assertEq(token.allowance(owner, spender), type(uint256).max - 1);
        assertEq(token.balanceOf(owner), 1e27);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_approvalRevocationAndZeroSpender() public {
        vm.startPrank(owner);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(owner, spender, 0);
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(owner, recipient, 1);
        assertEq(token.allowance(owner, spender), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferPreservesBalanceButSpendsFiniteAllowance(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        vm.startPrank(owner);
        assertTrue(token.transfer(owner, amount));
        token.approve(spender, amount);
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, owner, amount));
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(owner), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
