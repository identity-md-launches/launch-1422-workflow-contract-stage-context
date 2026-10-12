// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HiveWars} from "../src/HiveWars.sol";
import {ConquerorBadge} from "../src/ConquerorBadge.sol";

abstract contract HiveTestBase is Test {
    LaunchToken internal token;
    HiveWars internal game;
    ConquerorBadge internal badge;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;

    function setUp() public virtual {
        // All configuration is local and deterministic; no shared environment or network.
        vm.warp(1_800_000_000);
        token = new LaunchToken();
        game = new HiveWars(address(token));
        badge = new ConquerorBadge(address(game));
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);
    }

    function _fund(address player) internal {
        token.transfer(player, 1_000_000 ether);
        vm.prank(player);
        token.approve(address(game), 1_000_000 ether);
    }

    function _join(address player, uint8 colony) internal {
        vm.prank(player);
        game.joinColony(colony);
    }

    function _deploy(address player, uint8 territory, uint256 amount) internal {
        vm.prank(player);
        game.deploy(territory, amount);
    }

    function _retreat(address player, uint8 territory, uint256 amount) internal {
        vm.prank(player);
        game.retreat(territory, amount);
    }

    function _move(address player, uint8 from, uint8 to, uint256 amount) internal {
        vm.prank(player);
        game.move(from, to, amount);
    }

    function _atEpoch(uint256 epoch) internal {
        vm.warp(game.startTime() + (epoch - 1) * 1 days);
    }

    function _settleThrough(uint256 epoch) internal {
        while (game.lastSettledEpoch() < epoch) game.settleEpoch();
    }

    function _prepareWinner() internal {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(31);
        _settleThrough(30);
    }

    function _assertConserved() internal view {
        assertEq(token.balanceOf(address(game)), game.totalStaked() + game.totalCooldown());
    }
}
