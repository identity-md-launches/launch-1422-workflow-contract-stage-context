// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveTestBase, HiveWars} from "./TestBase.sol";

contract HiveWarsBoundariesTest is HiveTestBase {
    function test_all61TerritoriesFourColoniesSettleWithinOneTransaction() public {
        address[4] memory players = [alice, bob, carol, dave];
        for (uint8 c; c < 4; ++c) {
            _join(players[c], c);
            for (uint8 cell; cell < 61; ++cell) {
                _deploy(players[c], cell, (uint256(c) + 1) * 1_000 ether);
            }
        }
        _atEpoch(3);
        game.settleEpoch();
        uint256 beforeGas = gasleft();
        game.settleEpoch();
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("61-cell settlement gas (local test)", used);
        assertLt(used, 8_000_000);
        assertEq(game.seasonScores(1)[3], 89);
        HiveWars.TerritoryView[61] memory cells = game.mapState();
        for (uint8 i; i < 61; ++i) {
            assertEq(cells[i].controller, 3);
        }
        _assertConserved();
    }

    function test_all61TerritoriesCanSwitchColonyAtomically() public {
        _join(alice, 0);
        for (uint8 cell; cell < 61; ++cell) {
            _deploy(alice, cell, 1_000 ether);
        }
        _atEpoch(31);
        uint256 beforeGas = gasleft();
        _join(alice, 1);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("61-cell colony switch gas (local test)", used);
        assertLt(used, 12_000_000);
        assertEq(game.playerState(alice).totalActive, 0);
        assertEq(game.playerState(alice).totalPending, 61_000 ether);
        _settleThrough(30);
        assertEq(game.seasonScores(1)[0], 89 * 29);
        assertEq(game.seasonWinner(1), 0);
        _atEpoch(32);
        assertEq(game.colonyState().active[1], 61_000 ether);
        _assertConserved();
    }

    function test_threeSeasonBacklogPreservesChangingColonies() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(31);
        _join(alice, 1);
        _atEpoch(61);
        _join(alice, 2);
        _atEpoch(91);
        _settleThrough(90);
        assertEq(game.seasonWinner(1), 0);
        assertEq(game.seasonWinner(2), 1);
        assertEq(game.seasonWinner(3), 2);
        assertTrue(game.isEligible(alice, 1));
        assertTrue(game.isEligible(alice, 2));
        assertTrue(game.isEligible(alice, 3));
        assertEq(game.eligibleEpochs(alice, 1), 29);
        assertEq(game.eligibleEpochs(alice, 2), 29);
        assertEq(game.eligibleEpochs(alice, 3), 29);
        // The previous controller retains the Core during the switch's pending epoch.
        assertEq(game.seasonScores(2)[0], 5);
        assertEq(game.seasonScores(2)[1], 145);
        assertEq(game.seasonScores(3)[1], 5);
        assertEq(game.seasonScores(3)[2], 145);
    }

    function test_coreHolderOutsideTopScoreTieCannotWin() public {
        _join(alice, 0);
        _join(bob, 1);
        _join(carol, 2);
        _deploy(alice, 1, 1 ether);
        _deploy(alice, 2, 1 ether);
        _deploy(bob, 3, 1 ether);
        _deploy(bob, 4, 1 ether);
        _deploy(carol, 0, 1 ether);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.seasonScores(1)[0], 174);
        assertEq(game.seasonScores(1)[1], 174);
        assertEq(game.seasonScores(1)[2], 145);
        assertEq(game.territoryState(0).controller, 2);
        assertEq(game.seasonWinner(1), 4);
    }

    function test_exactSeasonBoundaryCannotRewriteLastEpoch() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(30);
        _deploy(bob, 0, 2_000 ether);
        _atEpoch(31);
        _retreat(alice, 0, 1_000 ether);
        _settleThrough(30);
        assertEq(game.seasonWinner(1), 0);
        assertEq(game.seasonScores(1)[1], 0);
        _atEpoch(32);
        game.settleEpoch();
        assertEq(game.seasonScores(2)[1], 5);
    }

    function test_insufficientAllowanceRevertsWithoutLockingNewSeasonChoice() public {
        _join(alice, 0);
        _atEpoch(31);
        vm.startPrank(alice);
        token.approve(address(game), 0);
        vm.expectRevert();
        game.deploy(0, 1);
        game.joinColony(2);
        vm.stopPrank();
        assertEq(game.colonyForSeason(alice, 2), 2);
        assertEq(game.totalStaked(), 0);
    }

    function test_claimingPriorCooldownDoesNotLockNewSeasonColony() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(30);
        _retreat(alice, 0, 1_000 ether);
        _atEpoch(31);
        vm.startPrank(alice);
        game.claimRetreat();
        game.joinColony(1);
        vm.stopPrank();
        assertEq(game.playerState(alice).colony, 1);
        _assertConserved();
    }
}
