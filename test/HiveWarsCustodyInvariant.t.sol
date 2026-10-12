// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {HiveWars} from "src/HiveWars.sol";

/// @dev The oracle records inputs and actual token receipts, never using playerState to choose
/// amounts or determine withdrawal entitlement. Tickets are kept separately even when the game
/// coalesces retreats. No private storage, token balance injection, or settlement is needed to exit.
contract CustodyLedgerHandler is Test {
    uint256 public constant FUNDING = 1_000_000 ether;
    LaunchToken public immutable token;
    HiveWars public immutable game;
    address[4] public actors;
    uint256[4] public wallet;
    uint256[61][4] public positions;
    uint256[4] public donated;
    uint256[4] public deposited;
    uint256[4] public paid;
    uint256[4] public choiceSeason;
    uint8[4] public colony;
    uint256 public settlements;
    uint256[4] public keeperCalls;

    struct Ticket {
        uint256 amount;
        uint256 unlockAt;
    }

    mapping(uint256 => Ticket[]) private tickets;

    constructor(LaunchToken token_, HiveWars game_, address[4] memory actors_) {
        token = token_;
        game = game_;
        actors = actors_;
        for (uint256 i; i < 4; ++i) {
            wallet[i] = FUNDING;
            colony[i] = uint8(i % 2); // Include multiple depositors in the same colony.
            choiceSeason[i] = 1;
        }
    }

    function deposit(uint256 actorSeed, uint256 cellSeed, uint256 amountSeed) public {
        uint256 actor = actorSeed % 4;
        if (wallet[actor] == 0) return;
        uint8 cell = uint8(cellSeed % 61);
        uint256 amount = bound(amountSeed, 1, wallet[actor]);
        vm.prank(actors[actor]);
        game.deploy(cell, amount);
        wallet[actor] -= amount;
        positions[actor][cell] += amount;
        deposited[actor] += amount;
        choiceSeason[actor] = _season();
    }

    function move(uint256 actorSeed, uint256 cellSeed, uint256 destinationSeed, uint256 amountSeed) external {
        uint256 actor = actorSeed % 4;
        uint8 from = _occupied(actor, cellSeed);
        uint256 available = positions[actor][from];
        if (available == 0) return;
        uint8 to = uint8((uint256(from) + 1 + destinationSeed % 60) % 61);
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actors[actor]);
        game.move(from, to, amount);
        positions[actor][from] -= amount;
        positions[actor][to] += amount;
        choiceSeason[actor] = _season();
    }

    function retreat(uint256 actorSeed, uint256 cellSeed, uint256 amountSeed) public {
        uint256 actor = actorSeed % 4;
        uint8 cell = _occupied(actor, cellSeed);
        uint256 available = positions[actor][cell];
        if (available == 0) return;
        _retreat(actor, cell, bound(amountSeed, 1, available));
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external {
        uint256 actor = actorSeed % 4;
        if (wallet[actor] == 0) return;
        uint256 amount = bound(amountSeed, 1, wallet[actor]);
        vm.prank(actors[actor]);
        assertTrue(token.transfer(address(game), amount));
        wallet[actor] -= amount;
        donated[actor] += amount;
    }

    function claim(uint256 actorSeed) public {
        uint256 actor = actorSeed % 4;
        uint256 amount = expectedClaim(actor);
        if (amount == 0) {
            vm.prank(actors[actor]);
            vm.expectRevert(HiveWars.NothingToClaim.selector);
            game.claimRetreat();
            return;
        }
        uint256 beforeBalance = token.balanceOf(actors[actor]);
        vm.prank(actors[actor]);
        game.claimRetreat();
        assertEq(token.balanceOf(actors[actor]) - beforeBalance, amount, "incorrect withdrawal receipt");

        // Consume the independent receipts covered by this payment, not the game's queue/head.
        uint256 remaining = amount;
        for (uint256 i; i < tickets[actor].length && remaining != 0; ++i) {
            Ticket storage ticket = tickets[actor][i];
            if (ticket.amount == 0) continue;
            assertLe(ticket.unlockAt, vm.getBlockTimestamp(), "paid an immature ticket");
            assertLe(ticket.amount, remaining, "partial ticket payment");
            remaining -= ticket.amount;
            ticket.amount = 0;
        }
        assertEq(remaining, 0, "payment exceeded recorded retreats");
        paid[actor] += amount;
        wallet[actor] += amount;
    }

    function chooseColony(uint256 actorSeed, uint256 colonySeed) external {
        uint256 actor = actorSeed % 4;
        uint8 next = uint8(colonySeed % 4);
        uint256 season = _season();
        vm.prank(actors[actor]);
        if (choiceSeason[actor] == season) vm.expectRevert(HiveWars.ColonyLocked.selector);
        game.joinColony(next);
        if (choiceSeason[actor] != season) {
            choiceSeason[actor] = season;
            colony[actor] = next;
        }
    }

    function advance(uint256 seed) external {
        // Mix repeated timestamps, near maturity, and season crossings instead of always
        // jumping so far that every cooldown is already mature.
        uint256[6] memory jumps = [uint256(0), 1, 1 hours, 1 days - 1, 1 days, 31 days];
        vm.warp(vm.getBlockTimestamp() + jumps[seed % jumps.length]);
    }

    function settle(uint256 actorSeed) external {
        uint256 actor = actorSeed % 4;
        uint256 ended = (vm.getBlockTimestamp() - game.startTime()) / 1 days;
        vm.prank(actors[actor]);
        if (settlements == ended) {
            vm.expectRevert(HiveWars.NoEndedEpoch.selector);
            game.settleEpoch();
        } else {
            game.settleEpoch();
            ++settlements;
            ++keeperCalls[actor];
        }
    }

    function overdraw(uint256 actorSeed, uint256 cellSeed, bool useMove) external {
        uint256 actor = actorSeed % 4;
        uint8 cell = uint8(cellSeed % 61);
        bytes32 beforeState = keccak256(abi.encode(game.playerState(actors[actor]), game.territoryState(cell)));
        vm.prank(actors[actor]);
        vm.expectRevert(HiveWars.InsufficientStake.selector);
        if (useMove) game.move(cell, uint8((uint256(cell) + 1) % 61), positions[actor][cell] + 1);
        else game.retreat(cell, positions[actor][cell] + 1);
        assertEq(
            keccak256(abi.encode(game.playerState(actors[actor]), game.territoryState(cell))),
            beforeState,
            "failed removal changed membership or balances"
        );
    }

    function expectedClaim(uint256 actor) public view returns (uint256 amount) {
        uint256 distinctDeadlines;
        uint256 previousDeadline;
        for (uint256 i; i < tickets[actor].length; ++i) {
            Ticket memory ticket = tickets[actor][i];
            if (ticket.amount == 0) continue;
            if (ticket.unlockAt > vm.getBlockTimestamp()) break;
            if (ticket.unlockAt != previousDeadline) {
                if (distinctDeadlines == 64) break;
                ++distinctDeadlines;
                previousDeadline = ticket.unlockAt;
            }
            amount += ticket.amount;
        }
    }

    function outstanding(uint256 actor) public view returns (uint256 amount, uint256 nextUnlock) {
        for (uint256 i; i < tickets[actor].length; ++i) {
            Ticket memory ticket = tickets[actor][i];
            amount += ticket.amount;
            if (nextUnlock == 0 && ticket.amount != 0) nextUnlock = ticket.unlockAt;
        }
    }

    /// @dev Called only by afterInvariant, deliberately excluded from the random selector list.
    function exitAll() external {
        for (uint256 actor; actor < 4; ++actor) {
            for (uint8 cell; cell < 61; ++cell) {
                if (positions[actor][cell] != 0) _retreat(actor, cell, positions[actor][cell]);
            }
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
        for (uint256 actor; actor < 4; ++actor) {
            (uint256 remaining,) = outstanding(actor);
            while (remaining != 0) {
                uint256 before = remaining;
                claim(actor);
                (remaining,) = outstanding(actor);
                assertLt(remaining, before, "exit made no progress");
            }
            assertEq(token.balanceOf(actors[actor]) + donated[actor], FUNDING, "principal stranded");
            assertEq(deposited[actor], paid[actor], "not all deposits repaid");
        }
        assertEq(game.totalStaked(), 0);
        assertEq(game.totalCooldown(), 0);
        assertEq(token.balanceOf(address(game)), donated[0] + donated[1] + donated[2] + donated[3]);
    }

    function _retreat(uint256 actor, uint8 cell, uint256 amount) private {
        vm.prank(actors[actor]);
        game.retreat(cell, amount);
        positions[actor][cell] -= amount;
        tickets[actor].push(Ticket(amount, vm.getBlockTimestamp() + 1 days));
        choiceSeason[actor] = _season();
    }

    function _occupied(uint256 actor, uint256 seed) private view returns (uint8) {
        for (uint256 i; i < 61; ++i) {
            uint8 cell = uint8((seed % 61 + i) % 61);
            if (positions[actor][cell] != 0) return cell;
        }
        return 0;
    }

    function _season() private view returns (uint256) {
        return (vm.getBlockTimestamp() - game.startTime()) / 30 days + 1;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HiveWarsCustodyInvariantTest is Test {
    LaunchToken private token;
    HiveWars private game;
    CustodyLedgerHandler private handler;

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new LaunchToken();
        game = new HiveWars(address(token));
        address[4] memory actors;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("custody actor ", vm.toString(i)));
            token.transfer(actors[i], 1_000_000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(game), type(uint256).max);
            game.joinColony(uint8(i % 2));
            vm.stopPrank();
        }
        handler = new CustodyLedgerHandler(token, game, actors);
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, i, 2_000 ether);
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, 60 - i, 1_000 ether);
            handler.retreat(i, i, 1 ether);
        }
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.move.selector;
        selectors[2] = handler.retreat.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.chooseColony.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.settle.selector;
        selectors[8] = handler.overdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_independentLedgerMatchesCustodyAndEveryPosition() public view {
        uint256 totalPositions;
        uint256 totalTickets;
        uint256 totalDonations;
        uint256[4] memory members;
        for (uint256 actor; actor < 4; ++actor) {
            address account = handler.actors(actor);
            HiveWars.PlayerView memory player = game.playerState(account);
            uint256 principal;
            for (uint256 cell; cell < 61; ++cell) {
                uint256 expected = handler.positions(actor, cell);
                assertEq(player.deployments[cell] + player.pending[cell], expected, "wrong position owner/amount");
                principal += expected;
            }
            (uint256 cooldown, uint256 nextUnlock) = handler.outstanding(actor);
            assertEq(player.totalActive + player.totalPending, principal);
            assertEq(player.cooldown, cooldown, "missing retreat");
            assertEq(player.claimable, handler.expectedClaim(actor), "incorrect maturity or batching");
            assertEq(player.nextUnlock, nextUnlock);
            assertEq(player.colony, handler.colony(actor));
            assertEq(player.choiceSeason, handler.choiceSeason(actor));
            assertEq(token.balanceOf(account), handler.wallet(actor));
            assertEq(principal + cooldown + handler.paid(actor), handler.deposited(actor));
            assertEq(principal + cooldown + handler.wallet(actor) + handler.donated(actor), 1_000_000 ether);
            assertEq(game.keeperSettlements(account), handler.keeperCalls(actor));
            ++members[player.colony];
            totalPositions += principal;
            totalTickets += cooldown;
            totalDonations += handler.donated(actor);
        }
        assertEq(game.totalStaked(), totalPositions);
        assertEq(game.totalCooldown(), totalTickets);
        assertEq(token.balanceOf(address(game)), totalPositions + totalTickets + totalDonations);
        assertEq(token.totalSupply(), 1e27);
        assertEq(game.lastSettledEpoch(), handler.settlements());
        HiveWars.ColonyView memory colonies = game.colonyState();
        for (uint256 i; i < 4; ++i) {
            assertEq(colonies.members[i], members[i]);
        }
    }

    function afterInvariant() public {
        handler.exitAll();
        invariant_independentLedgerMatchesCustodyAndEveryPosition();
    }

    function test_seededSequenceExercisesDonationFailureSwitchAndExit() public {
        handler.claim(0); // Immature.
        handler.overdraw(0, 0, false);
        handler.overdraw(0, 60, true);
        handler.move(0, 0, 5, 1 ether);
        handler.donate(1, 7 ether);
        handler.advance(4); // Exactly one day.
        handler.claim(0);
        handler.claim(0); // Already claimed.
        handler.advance(5); // Season crossing with a settlement backlog.
        handler.chooseColony(0, 3);
        handler.chooseColony(0, 2); // Locked.
        handler.settle(2);
        invariant_independentLedgerMatchesCustodyAndEveryPosition();
        afterInvariant();
    }
}
