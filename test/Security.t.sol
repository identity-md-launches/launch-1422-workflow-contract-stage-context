// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HiveWars} from "../src/HiveWars.sol";
import {ConquerorBadge} from "../src/ConquerorBadge.sol";
import {AdversarialToken, NoReturnToken} from "./mocks/AdversarialToken.sol";

contract SecurityTest is Test {
    AdversarialToken internal token;
    HiveWars internal game;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new AdversarialToken();
        game = new HiveWars(address(token));
        token.approve(address(game), 1_000_000 ether);
        game.joinColony(0);
    }

    function test_failedAndShortDepositsRollBackAllAccounting() public {
        for (uint8 mode = 1; mode <= 3; ++mode) {
            token.configure(AdversarialToken.Mode(mode), address(game), "");
            vm.expectRevert();
            game.deploy(0, 100 ether);
            assertEq(game.totalStaked(), 0);
            assertEq(game.playerState(address(this)).totalPending, 0);
            assertEq(game.territoryState(0).pending[0], 0);
            assertEq(token.balanceOf(address(game)), 0);
        }
    }

    function test_failedPayoutRetainsClaimAndCanBeRetried() public {
        game.deploy(0, 100 ether);
        game.retreat(0, 100 ether);
        vm.warp(block.timestamp + 1 days);
        token.configure(AdversarialToken.Mode.ReturnFalse, address(game), "");
        vm.expectRevert();
        game.claimRetreat();
        assertEq(game.totalCooldown(), 100 ether);
        assertEq(game.playerState(address(this)).claimable, 100 ether);
        (uint256 head,) = game.cooldownQueue(address(this));
        assertEq(head, 0);
        token.configure(AdversarialToken.Mode.Normal, address(game), "");
        game.claimRetreat();
        assertEq(game.totalCooldown(), 0);
        assertEq(token.balanceOf(address(game)), 0);
    }

    function test_reentrantDepositCannotEnterAnyMutator() public {
        bytes[6] memory payloads = [
            abi.encodeCall(game.deploy, (0, 1)),
            abi.encodeCall(game.move, (0, 1, 1)),
            abi.encodeCall(game.retreat, (0, 1)),
            abi.encodeCall(game.claimRetreat, ()),
            abi.encodeCall(game.joinColony, (1)),
            abi.encodeCall(game.settleEpoch, ())
        ];
        for (uint256 i; i < payloads.length; ++i) {
            token.configure(AdversarialToken.Mode.Callback, address(game), payloads[i]);
            game.deploy(0, 100 ether);
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(game.totalStaked(), 600 ether);
        assertEq(token.balanceOf(address(game)), 600 ether);
    }

    function test_reentrantPayoutCannotDoubleClaim() public {
        game.deploy(0, 100 ether);
        game.retreat(0, 100 ether);
        vm.warp(block.timestamp + 1 days);
        token.configure(AdversarialToken.Mode.Callback, address(game), abi.encodeCall(game.claimRetreat, ()));
        game.claimRetreat();
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.totalCooldown(), 0);
    }

    function test_safeERC20AcceptsNoReturnData() public {
        NoReturnToken noReturn = new NoReturnToken();
        HiveWars other = new HiveWars(address(noReturn));
        noReturn.approve(address(other), 100 ether);
        other.joinColony(0);
        other.deploy(0, 100 ether);
        other.retreat(0, 100 ether);
        vm.warp(block.timestamp + 1 days);
        other.claimRetreat();
        assertEq(noReturn.balanceOf(address(other)), 0);
        assertEq(other.totalCooldown(), 0);
    }

    function test_factoryCompatibleConstructorsDoNotCallDependencies() public {
        address futureToken = makeAddr("future token");
        address futureGame = makeAddr("future game");
        assertEq(futureToken.code.length, 0);
        assertEq(futureGame.code.length, 0);
        HiveWars futureBoundGame = new HiveWars(futureToken);
        ConquerorBadge futureBoundBadge = new ConquerorBadge(futureGame);
        assertEq(address(futureBoundGame.nectarToken()), futureToken);
        assertEq(address(futureBoundBadge.hiveWars()), futureGame);
        futureBoundGame.joinColony(0);
        vm.expectRevert(HiveWars.InvalidToken.selector);
        futureBoundGame.deploy(0, 1);
        vm.expectRevert(ConquerorBadge.InvalidGame.selector);
        futureBoundBadge.claim(1);
    }

    function test_deploymentsPreserveFactorySupplyAndRuntimeFloor() public {
        LaunchToken launch = new LaunchToken();
        HiveWars live = new HiveWars(address(launch));
        ConquerorBadge liveBadge = new ConquerorBadge(address(live));
        assertEq(launch.totalSupply(), 1e27);
        assertEq(launch.balanceOf(address(this)), 1e27);
        _checkRuntime(address(launch));
        _checkRuntime(address(live));
        _checkRuntime(address(liveBadge));
    }

    function _checkRuntime(address target) private view {
        bytes memory runtime = target.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
