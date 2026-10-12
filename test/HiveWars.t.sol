// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveTestBase, HiveWars} from "./TestBase.sol";

contract HiveWarsTest is HiveTestBase {
    function test_mapRingsCoordinatesAndPoints() public view {
        uint256[5] memory counts;
        uint256 totalPoints;
        for (uint8 i; i < 61; ++i) {
            (int8 q, int8 r) = game.territoryCoordinates(i);
            uint256 radius = _abs(q);
            if (_abs(r) > radius) radius = _abs(r);
            if (_abs(q + r) > radius) radius = _abs(q + r);
            assertLe(radius, 4);
            ++counts[radius];
            uint256 expected = radius == 0 ? 5 : radius == 1 ? 3 : radius == 2 ? 2 : 1;
            assertEq(game.territoryPoints(i), expected);
            totalPoints += expected;
            for (uint8 j; j < i; ++j) {
                (int8 otherQ, int8 otherR) = game.territoryCoordinates(j);
                assertFalse(q == otherQ && r == otherR, "duplicate cell");
            }
        }
        assertEq(counts[0], 1);
        for (uint256 i = 1; i <= 4; ++i) {
            assertEq(counts[i], i * 6);
        }
        assertEq(totalPoints, 89);
    }

    function test_initialViewsAndClock() public view {
        HiveWars.SeasonView memory info = game.seasonInfo();
        assertEq(info.season, 1);
        assertEq(info.epoch, 1);
        assertEq(info.epochInSeason, 1);
        assertEq(info.secondsLeft, 1 days);
        assertEq(info.seasonSecondsLeft, 30 days);
        assertEq(info.lastSettled, 0);
        assertEq(info.pastWinners.length, 0);
        assertEq(game.playerState(alice).colony, 4);
        HiveWars.TerritoryView[61] memory cells = game.mapState();
        for (uint8 i; i < 61; ++i) {
            assertEq(cells[i].controller, 4);
        }
    }

    function test_pendingOnlyActivatesAtNextBoundary() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        assertEq(game.territoryState(0).active[0], 0);
        assertEq(game.territoryState(0).pending[0], 100 ether);
        vm.warp(game.startTime() + 1 days - 1);
        assertEq(game.playerState(alice).totalActive, 0);
        _atEpoch(2);
        assertEq(game.territoryState(0).active[0], 100 ether);
        assertEq(game.territoryState(0).pending[0], 0);
        assertEq(game.playerState(alice).totalActive, 100 ether);
        game.settleEpoch();
        assertEq(game.territoryState(0).controller, 4, "epoch one had no active troops");
        _atEpoch(3);
        game.settleEpoch();
        assertEq(game.territoryState(0).controller, 0);
        assertEq(game.seasonScores(1)[0], 5);
    }

    function test_lastSecondDepositCannotSnipeEndedEpoch() public {
        _join(alice, 0);
        vm.warp(game.startTime() + 1 days - 1);
        _deploy(alice, 0, 100_000 ether);
        _atEpoch(2);
        game.settleEpoch();
        assertEq(game.territoryState(0).controller, 4);
        assertEq(game.seasonScores(1)[0], 0);
    }

    function test_moveRemovesImmediatelyAndWaitsOneEpoch() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        _atEpoch(2);
        _move(alice, 0, 1, 60 ether);
        assertEq(game.territoryState(0).active[0], 40 ether);
        assertEq(game.territoryState(1).active[0], 0);
        assertEq(game.territoryState(1).pending[0], 60 ether);
        assertEq(game.playerState(alice).totalActive, 40 ether);
        _atEpoch(3);
        assertEq(game.playerState(alice).totalActive, 100 ether);
        assertEq(game.territoryState(1).active[0], 60 ether);
        _assertConserved();
    }

    function test_pendingMovesAndRetreatsConsumePendingFirst() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        _atEpoch(2);
        _deploy(alice, 0, 50 ether);
        _move(alice, 0, 1, 30 ether);
        _retreat(alice, 0, 40 ether);
        HiveWars.PlayerView memory player = game.playerState(alice);
        assertEq(player.deployments[0], 80 ether);
        assertEq(player.pending[0], 0);
        assertEq(player.pending[1], 30 ether);
        assertEq(player.cooldown, 40 ether);
        _assertConserved();
    }

    function test_tiesKeepIncumbentAndNeutral() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 0, 100 ether);
        _deploy(alice, 1, 100 ether);
        _deploy(bob, 1, 100 ether);
        _atEpoch(3);
        _settleThrough(2);
        assertEq(game.territoryState(0).controller, 0);
        assertEq(game.territoryState(1).controller, 4);
        _deploy(bob, 0, 100 ether);
        _atEpoch(5);
        _settleThrough(4);
        assertEq(game.territoryState(0).controller, 0);
        _retreat(alice, 0, 100 ether);
        _retreat(bob, 0, 100 ether);
        _atEpoch(6);
        _settleThrough(5);
        assertEq(game.territoryState(0).controller, 0, "empty tie retains incumbent");
    }

    function test_tiedChallengersDoNotDislodgeIncumbent() public {
        _join(alice, 0);
        _join(bob, 1);
        _join(carol, 2);
        _deploy(alice, 0, 1 ether);
        _atEpoch(3);
        _settleThrough(2);
        _deploy(bob, 0, 2 ether);
        _deploy(carol, 0, 2 ether);
        _atEpoch(5);
        _settleThrough(4);
        assertEq(game.territoryState(0).controller, 0);
    }

    function test_higherStakeCaptures() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 0, 10 ether);
        _atEpoch(3);
        _settleThrough(2);
        _deploy(bob, 0, 11 ether);
        _atEpoch(5);
        _settleThrough(4);
        assertEq(game.territoryState(0).controller, 1);
    }

    function test_settlementSequentialOnceAndKeeperStats() public {
        vm.expectRevert(HiveWars.NoEndedEpoch.selector);
        game.settleEpoch();
        _atEpoch(4);
        vm.prank(alice);
        game.settleEpoch();
        assertEq(game.lastSettledEpoch(), 1);
        vm.startPrank(bob);
        game.settleEpoch();
        game.settleEpoch();
        vm.expectRevert(HiveWars.NoEndedEpoch.selector);
        game.settleEpoch();
        vm.stopPrank();
        assertEq(game.keeperSettlements(alice), 1);
        assertEq(game.keeperSettlements(bob), 2);
        assertEq(game.lastSettledEpoch(), 3);
    }

    function test_laterRetreatDoesNotRewriteUnsettledHistory() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(10);
        _retreat(alice, 0, 1_000 ether);
        _settleThrough(9);
        assertEq(game.seasonScores(1)[0], 8 * 5);
        assertEq(game.eligibleEpochs(alice, 1), 8);
        assertEq(game.territoryState(0).active[0], 0);
        _assertConserved();
    }

    function test_laterDepositCannotRewriteHistoricalControl() public {
        _join(alice, 0);
        _atEpoch(5);
        _deploy(alice, 0, 100 ether);
        _atEpoch(7);
        _settleThrough(5);
        assertEq(game.seasonScores(1)[0], 0);
        game.settleEpoch();
        assertEq(game.seasonScores(1)[0], 5);
    }

    function test_retreatCooldownCannotClaimEarlyOrTwice() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        _retreat(alice, 0, 100 ether);
        vm.startPrank(alice);
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        game.claimRetreat();
        vm.warp(game.startTime() + 1 days - 1);
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        game.claimRetreat();
        _atEpoch(2);
        game.claimRetreat();
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        game.claimRetreat();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        _assertConserved();
    }

    function test_laterRetreatNeverRelocksOlderCooldown() public {
        _join(alice, 0);
        _deploy(alice, 0, 200 ether);
        _retreat(alice, 0, 100 ether);
        vm.warp(game.startTime() + 12 hours);
        _retreat(alice, 0, 100 ether);
        _atEpoch(2);
        assertEq(game.playerState(alice).claimable, 100 ether);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(game.playerState(alice).cooldown, 100 ether);
        vm.warp(game.startTime() + 36 hours);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(game.playerState(alice).cooldown, 0);
        _assertConserved();
    }

    function test_sameTimestampRetreatsCoalesceAndClaimIsBounded() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        _retreat(alice, 0, 1 ether);
        _retreat(alice, 0, 1 ether);
        (, uint256 count) = game.cooldownQueue(alice);
        assertEq(count, 1);
        for (uint256 i = 1; i < 66; ++i) {
            vm.warp(game.startTime() + i);
            _retreat(alice, 0, 1 ether);
        }
        _atEpoch(3);
        assertEq(game.playerState(alice).claimable, 65 ether);
        vm.prank(alice);
        game.claimRetreat();
        (uint256 head,) = game.cooldownQueue(alice);
        assertEq(head, 64);
        assertEq(game.playerState(alice).cooldown, 2 ether);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(game.playerState(alice).cooldown, 0);
        _assertConserved();
    }

    function test_colonyLockedUntilNewSeason() public {
        _join(alice, 0);
        vm.startPrank(alice);
        vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(0);
        vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(1);
        _atEpoch(30);
        vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(1);
        _atEpoch(31);
        game.joinColony(1);
        vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(2);
        vm.stopPrank();
        assertEq(game.colonyForSeason(alice, 1), 0);
        assertEq(game.colonyForSeason(alice, 2), 1);
        HiveWars.ColonyView memory colonies = game.colonyState();
        assertEq(colonies.members[0], 0);
        assertEq(colonies.members[1], 1);
    }

    function test_newSeasonGameplayConfirmsInheritedColony() public {
        _join(alice, 0);
        _atEpoch(31);
        _deploy(alice, 0, 10 ether);
        vm.prank(alice);
        vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(1);
    }

    function test_switchMigratesAllTroopsAsPendingPreservingPast() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _deploy(alice, 60, 500 ether);
        _atEpoch(31);
        _join(alice, 1);
        HiveWars.PlayerView memory player = game.playerState(alice);
        assertEq(player.totalActive, 0);
        assertEq(player.totalPending, 1_500 ether);
        assertEq(game.territoryState(0).active[0], 0);
        assertEq(game.territoryState(0).pending[1], 1_000 ether);
        _settleThrough(30);
        assertEq(game.seasonWinner(1), 0);
        assertTrue(game.isEligible(alice, 1));
        assertEq(game.eligibleEpochs(alice, 1), 29);
        _atEpoch(32);
        assertEq(game.territoryState(60).active[1], 500 ether);
        _assertConserved();
    }

    function test_lateSeasonChoiceDoesNotCreditPreviousColonyEpochs() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(40);
        _join(alice, 1);
        assertEq(game.eligibleEpochs(alice, 2), 0);
        _atEpoch(47);
        assertEq(game.eligibleEpochs(alice, 2), 6);
        _atEpoch(48);
        assertEq(game.eligibleEpochs(alice, 2), 7);
    }

    function test_keepingColonyRetainsEarlierSeasonCredit() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(40);
        _join(alice, 0);
        assertEq(game.eligibleEpochs(alice, 2), 9);
        assertEq(game.playerState(alice).totalActive, 1_000 ether);
    }

    function test_seasonRolloverScoreResetAndPastWinners() public {
        _prepareWinner();
        assertEq(game.currentSeason(), 2);
        assertEq(game.seasonWinner(1), 0);
        assertEq(game.seasonScores(1)[0], 145);
        assertEq(game.colonyState().score[0], 0);
        HiveWars.SeasonView memory info = game.seasonInfo();
        assertEq(info.epochInSeason, 1);
        assertEq(info.pastWinners.length, 1);
        assertEq(info.pastWinners[0], 0);
        _atEpoch(32);
        game.settleEpoch();
        assertEq(game.colonyState().score[0], 5);
        assertEq(game.seasonScores(1)[0], 145);
    }

    function test_seasonHighestScoreTieGoesToCoreHolder() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 0, 1 ether); // five points
        _deploy(bob, 1, 1 ether); // three points
        _deploy(bob, 7, 1 ether); // two points
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.seasonScores(1)[0], game.seasonScores(1)[1]);
        assertEq(game.seasonWinner(1), 0);
    }

    function test_seasonDrawWhenCoreCannotBreakTie() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 1, 1 ether);
        _deploy(bob, 2, 1 ether);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.seasonWinner(1), 4);
        assertFalse(game.isEligible(alice, 1));
    }

    function test_emptySeasonHasNoWinner() public {
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.seasonWinner(1), 4);
    }

    function test_eligibilityExactThresholdAndSevenCompletedEpochs() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(8);
        assertEq(game.eligibleEpochs(alice, 1), 6);
        _atEpoch(9);
        assertEq(game.eligibleEpochs(alice, 1), 7);
        assertFalse(game.isEligible(alice, 1), "season not finished");
        _atEpoch(31);
        assertFalse(game.isEligible(alice, 1), "season not settled");
        _settleThrough(30);
        assertTrue(game.isEligible(alice, 1));
    }

    function test_eligibilityOneWeiUnderThresholdNeverCounts() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether - 1);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.eligibleEpochs(alice, 1), 0);
        assertFalse(game.isEligible(alice, 1));
    }

    function test_pendingAndPartialEpochDoNotCountForEligibility() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(8);
        vm.warp(block.timestamp + 12 hours);
        _retreat(alice, 0, 1);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.eligibleEpochs(alice, 1), 6);
        assertFalse(game.isEligible(alice, 1));
    }

    function test_eligibilityAggregatesTerritoriesAndNonconsecutiveEpochs() public {
        _join(alice, 0);
        _deploy(alice, 0, 500 ether);
        _deploy(alice, 1, 500 ether);
        _atEpoch(5); // completed active epochs 2,3,4
        _move(alice, 1, 2, 500 ether); // epoch 5 only 500 active
        _atEpoch(10); // completed epochs 6,7,8,9
        _retreat(alice, 0, 500 ether);
        assertEq(game.eligibleEpochs(alice, 1), 7);
        _atEpoch(31);
        _settleThrough(30);
        assertTrue(game.isEligible(alice, 1));
    }

    function test_losingColonyDoesNotQualifyAndOldHistoryPersists() public {
        _join(alice, 0);
        _join(bob, 1);
        _deploy(alice, 0, 2_000 ether);
        _deploy(bob, 0, 1_000 ether);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.eligibleEpochs(bob, 1), 29);
        assertFalse(game.isEligible(bob, 1));
        _join(bob, 0);
        assertFalse(game.isEligible(bob, 1));
        assertTrue(game.isEligible(alice, 1));
    }

    function test_lazyAccountingAcrossThousandsOfInactiveSeasons() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(30_001);
        assertEq(game.eligibleEpochs(alice, 500), 30);
        _retreat(alice, 0, 1_000 ether);
        _atEpoch(30_002);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        assertEq(game.eligibleEpochs(alice, 1), 29);
        _assertConserved();
    }

    function test_validationAndUnauthorizedActions() public {
        vm.expectRevert(HiveWars.InvalidColony.selector);
        game.joinColony(4);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryPoints(61);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryCoordinates(255);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryState(61);
        vm.expectRevert(HiveWars.NotJoined.selector);
        game.deploy(0, 1);
        _join(alice, 0);
        vm.startPrank(alice);
        vm.expectRevert(HiveWars.ZeroAmount.selector);
        game.deploy(0, 0);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.deploy(61, 1);
        vm.expectRevert(HiveWars.SameTerritory.selector);
        game.move(0, 0, 1);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.move(0, 1, 1);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.retreat(0, 1);
        vm.stopPrank();
        _deploy(alice, 0, 10 ether);
        _join(bob, 0);
        vm.prank(bob);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.retreat(0, 1);
        vm.prank(bob);
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        game.claimRetreat();
        vm.expectRevert(HiveWars.SeasonNotFinalized.selector);
        game.seasonWinner(1);
        assertFalse(game.isEligible(alice, 0));
        assertEq(game.eligibleEpochs(alice, type(uint256).max), 0);
        _assertConserved();
    }

    function test_immutableBindingHasNoOwnerSetterOrRecoveryPower() public {
        assertEq(address(game.nectarToken()), address(token));
        bytes memory data = abi.encodeWithSignature("setNectarToken(address)", address(token));
        (bool ok,) = address(game).call(data);
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(game).call(data);
        assertFalse(ok);
        (ok,) = address(game).call(abi.encodeWithSignature("withdraw(address,uint256)", alice, 1));
        assertFalse(ok);
        vm.expectRevert(HiveWars.InvalidToken.selector);
        new HiveWars(address(0));
    }

    function test_unsolicitedDonationDoesNotCreditAnyPlayer() public {
        token.transfer(address(game), 100 ether);
        assertEq(game.totalStaked(), 0);
        assertEq(game.totalCooldown(), 0);
        assertEq(game.playerState(alice).totalActive, 0);
    }

    function testFuzz_deployMoveRetreatConserves(uint256 amount, uint256 moved, uint256 removed) public {
        amount = bound(amount, 1, 1_000_000 ether);
        moved = bound(moved, 1, amount);
        removed = bound(removed, 1, moved);
        _join(alice, 0);
        _deploy(alice, 0, amount);
        _assertConserved();
        _atEpoch(2);
        _move(alice, 0, 60, moved);
        _assertConserved();
        _retreat(alice, 60, removed);
        _assertConserved();
        HiveWars.PlayerView memory player = game.playerState(alice);
        assertEq(player.totalActive + player.totalPending + player.cooldown, amount);
        _atEpoch(3);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(token.balanceOf(alice), 1_000_000 ether - amount + removed);
        _assertConserved();
    }

    function _abs(int8 value) private pure returns (uint256) {
        return uint256(int256(value < 0 ? -value : value));
    }
}
