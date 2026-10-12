// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveTestBase, HiveWars, LaunchToken} from "./TestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract HiveWarsAdversarialTest is HiveTestBase {
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_invalidTerritoryRejectedByEveryEntryPoint(uint8 invalid, uint256 amount) public {
        invalid = uint8(bound(invalid, 61, 255));
        amount = bound(amount, 1, type(uint256).max);
        _join(alice, 0);
        _deploy(alice, 0, 1 ether);
        bytes32 beforeState = _stateHash(alice);
        vm.startPrank(alice);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.deploy(invalid, amount);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.move(invalid, 0, amount);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.move(0, invalid, amount);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.retreat(invalid, amount);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryState(invalid);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryPoints(invalid);
        vm.expectRevert(HiveWars.InvalidTerritory.selector);
        game.territoryCoordinates(invalid);
        vm.stopPrank();
        assertEq(_stateHash(alice), beforeState);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_invalidColonyCannotCreateOrReplaceMembership(uint8 invalid) public {
        invalid = uint8(bound(invalid, 4, 255));
        bytes32 beforeState = _stateHash(alice);
        vm.prank(alice);
        vm.expectRevert(HiveWars.InvalidColony.selector);
        game.joinColony(invalid);
        assertEq(_stateHash(alice), beforeState);
        _join(alice, 2);
        _deploy(alice, 60, 1_000 ether);
        _atEpoch(31);
        beforeState = _stateHash(alice);
        vm.prank(alice);
        vm.expectRevert(HiveWars.InvalidColony.selector);
        game.joinColony(invalid);
        assertEq(_stateHash(alice), beforeState);
        _join(alice, 3); // A reverted choice must not lock the new season.
        assertEq(game.playerState(alice).colony, 3);
    }

    function test_zeroAndMaximumActionsCannotMutateExistingPositions() public {
        _join(alice, 0);
        _deploy(alice, 0, 100 ether);
        _atEpoch(2);
        _deploy(alice, 0, 50 ether);
        bytes32 beforeState = _stateHash(alice);
        vm.startPrank(alice);
        vm.expectRevert(HiveWars.ZeroAmount.selector);
        game.deploy(0, 0);
        vm.expectRevert(HiveWars.ZeroAmount.selector);
        game.move(0, 60, 0);
        vm.expectRevert(HiveWars.ZeroAmount.selector);
        game.retreat(0, 0);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.move(0, 60, type(uint256).max);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.retreat(0, type(uint256).max);
        vm.stopPrank();
        assertEq(_stateHash(alice), beforeState);
    }

    function test_unjoinedAndSameColonyWalletCannotUseAnotherPlayersTroops() public {
        _join(alice, 1);
        _deploy(alice, 0, 100 ether);
        _atEpoch(2);
        bytes32 victimBefore = keccak256(abi.encode(game.playerState(alice)));
        vm.startPrank(bob);
        vm.expectRevert(HiveWars.NotJoined.selector);
        game.move(0, 1, 1);
        vm.expectRevert(HiveWars.NotJoined.selector);
        game.retreat(0, 1);
        game.joinColony(1);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.move(0, 1, 1);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        game.retreat(0, 1);
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        game.claimRetreat();
        vm.stopPrank();
        assertEq(game.playerState(alice).totalActive, 100 ether);
        assertEq(game.totalStaked(), 100 ether);
        // Membership counts legitimately changed; the victim's own state did not.
        assertEq(keccak256(abi.encode(game.playerState(alice))), victimBefore);
    }

    function test_insufficientBalanceRollsBackAllowanceAndInheritedSeasonConfirmation() public {
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(31);
        uint256 balance = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(game), balance + 1);
        bytes32 beforeState = _stateHash(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        game.deploy(60, balance + 1);
        assertEq(_stateHash(alice), beforeState);
        assertEq(token.allowance(alice, address(game)), balance + 1);
        _join(alice, 2);
        assertEq(game.playerState(alice).totalPending, 1_000 ether);
        assertEq(game.colonyForSeason(alice, 1), 0);
        assertEq(game.colonyForSeason(alice, 2), 2);
    }

    function test_entireSupplyCanMoveRetreatAndReturnWithoutKeeper() public {
        LaunchToken all = new LaunchToken();
        HiveWars isolated = new HiveWars(address(all));
        uint256 supply = all.totalSupply();
        all.approve(address(isolated), type(uint256).max);
        isolated.joinColony(3);
        isolated.deploy(60, supply);
        assertEq(all.balanceOf(address(this)), 0);
        assertEq(isolated.totalStaked(), supply);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        isolated.move(60, 0, supply);
        assertEq(isolated.playerState(address(this)).totalActive, 0);
        assertEq(isolated.playerState(address(this)).totalPending, supply);
        isolated.retreat(0, supply);
        assertEq(isolated.totalStaked(), 0);
        assertEq(isolated.totalCooldown(), supply);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        vm.expectRevert(HiveWars.NothingToClaim.selector);
        isolated.claimRetreat();
        vm.warp(vm.getBlockTimestamp() + 1);
        isolated.claimRetreat();
        assertEq(all.balanceOf(address(this)), supply);
        assertEq(all.balanceOf(address(isolated)), 0);
        assertEq(isolated.totalCooldown(), 0);
        assertEq(isolated.lastSettledEpoch(), 0);
        assertEq(all.totalSupply(), 1e27);
        isolated.deploy(0, 1); // A completely drained game remains usable, even for dust.
        isolated.retreat(0, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        isolated.claimRetreat();
        assertEq(all.balanceOf(address(this)), supply);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_cooldownBatchCutoffPartialMaturityAndRetry(uint256 countSeed, uint256 matureSeed) public {
        uint256 count = bound(countSeed, 65, 140);
        uint256 matured = bound(matureSeed, 1, count);
        _join(alice, 0);
        _deploy(alice, 0, 3 * count);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < count; ++i) {
            vm.warp(start + i);
            _retreat(alice, 0, 1);
            _retreat(alice, 0, 2); // Two independent retreats share a timestamp and deadline.
        }
        vm.warp(start + 1 days + matured - 1);
        uint256 first = matured < 64 ? matured : 64;
        assertEq(game.playerState(alice).claimable, first * 3);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        game.claimRetreat();
        assertEq(token.balanceOf(alice) - before, first * 3);
        (uint256 head, uint256 length) = game.cooldownQueue(alice);
        assertEq(head, first);
        assertEq(length, count);
        assertEq(game.playerState(alice).nextUnlock, start + first + 1 days);
        assertEq(game.playerState(alice).cooldown, (count - first) * 3);
        for (uint256 i; i < first; ++i) {
            HiveWars.Cooldown memory consumed = game.cooldownEntry(alice, i);
            assertEq(consumed.amount, 0);
            assertEq(consumed.unlockAt, 0);
        }
        if (matured <= 64) {
            vm.prank(alice);
            vm.expectRevert(HiveWars.NothingToClaim.selector);
            game.claimRetreat();
            assertEq(game.playerState(alice).cooldown, (count - first) * 3);
        }
        vm.warp(start + 1 days + count - 1);
        // The remaining at most 139 entries need at most three bounded claims.
        for (uint256 remaining = count - first; remaining != 0;) {
            uint256 batch = remaining < 64 ? remaining : 64;
            before = token.balanceOf(alice);
            vm.prank(alice);
            game.claimRetreat();
            assertEq(token.balanceOf(alice) - before, batch * 3);
            remaining -= batch;
        }
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        assertEq(game.playerState(alice).nextUnlock, 0);
        assertEq(game.playerState(alice).claimable, 0);
        assertEq(game.totalCooldown(), 0);
        _assertConserved();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_lateSeasonEligibilityRequiresSevenWholeActiveEpochs(
        uint256 deploymentSeed,
        uint256 durationSeed,
        uint256 amountSeed
    ) public {
        uint256 deploymentEpoch = bound(deploymentSeed, 1, 30);
        uint256 completed = bound(durationSeed, 0, 30 - deploymentEpoch);
        uint256 amount = bound(amountSeed, 999 ether, 1_001 ether);
        _join(alice, 0);
        _atEpoch(deploymentEpoch);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        _deploy(alice, 0, amount);
        _atEpoch(deploymentEpoch + 1 + completed);
        _retreat(alice, 0, amount);
        _atEpoch(31);
        _settleThrough(30);
        assertEq(game.eligibleEpochs(alice, 1), amount >= 1_000 ether ? completed : 0);
        assertEq(game.isEligible(alice, 1), amount >= 1_000 ether && completed >= 7);
        assertEq(game.playerState(alice).totalActive, 0);
        _assertConserved();
    }

    function test_gameEventsIdentifyActorEpochCooldownAndKeeperResult() public {
        vm.expectEmit(true, true, false, true, address(game));
        emit Joined(alice, 1, 2);
        _join(alice, 2);
        vm.expectEmit(true, true, false, true, address(game));
        emit Deployed(alice, 0, 1_000 ether, 2);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(2);
        uint8[4] memory counts;
        vm.expectEmit(true, false, false, true, address(game));
        emit Settled(1, counts);
        vm.prank(bob);
        game.settleEpoch();
        _atEpoch(3);
        vm.expectEmit(true, false, false, true, address(game));
        emit TerritoryCaptured(0, 4, 2);
        counts[2] = 1;
        vm.expectEmit(true, false, false, true, address(game));
        emit Settled(2, counts);
        vm.prank(carol);
        game.settleEpoch();
        assertEq(game.keeperSettlements(bob), 1);
        assertEq(game.keeperSettlements(carol), 1);
        vm.expectEmit(true, true, true, true, address(game));
        emit Moved(alice, 0, 60, 400 ether, 4);
        _move(alice, 0, 60, 400 ether);
        vm.expectEmit(true, true, false, true, address(game));
        emit Retreated(alice, 60, 400 ether, vm.getBlockTimestamp() + 1 days);
        _retreat(alice, 60, 400 ether);
        _atEpoch(4);
        vm.expectEmit(true, false, false, true, address(game));
        emit RetreatClaimed(alice, 400 ether);
        vm.prank(alice);
        game.claimRetreat();
        _atEpoch(31);
        _settleThrough(29);
        vm.expectEmit(true, false, false, true, address(game));
        emit Settled(30, counts);
        vm.expectEmit(true, false, false, true, address(game));
        emit SeasonEnded(1, 2);
        game.settleEpoch();
        assertEq(game.seasonWinner(1), 2);
        _assertConserved();
    }

    function _stateHash(address player) private view returns (bytes32) {
        (uint256 head, uint256 length) = game.cooldownQueue(player);
        bytes32 balances = keccak256(
            abi.encode(
                token.balanceOf(player),
                token.balanceOf(address(game)),
                token.allowance(player, address(game)),
                head,
                length
            )
        );
        return keccak256(
            abi.encode(
                game.playerState(player),
                game.mapState(),
                game.colonyState(),
                game.totalStaked(),
                game.totalCooldown(),
                game.lastSettledEpoch(),
                balances
            )
        );
    }

    event Joined(address indexed player, uint256 indexed season, uint8 colony);
    event Deployed(address indexed player, uint8 indexed territory, uint256 amount, uint256 activationEpoch);
    event Moved(address indexed player, uint8 indexed from, uint8 indexed to, uint256 amount, uint256 activationEpoch);
    event Retreated(address indexed player, uint8 indexed territory, uint256 amount, uint256 unlockAt);
    event RetreatClaimed(address indexed player, uint256 amount);
    event Settled(uint256 indexed epoch, uint8[4] territoriesPerColony);
    event TerritoryCaptured(uint8 indexed territory, uint8 from, uint8 to);
    event SeasonEnded(uint256 indexed season, uint8 winner);
}
