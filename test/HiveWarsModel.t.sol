// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveTestBase, HiveWars} from "./TestBase.sol";

/// @dev An eager, small-map reference model. It settles every epoch at the boundary and does not
/// use the production checkpoint algorithm. The actual game settles only after many later actions.
contract HiveWarsModelTest is HiveTestBase {
    struct Position {
        uint256 active;
        uint256 pending;
    }
    Position[7][4] private army;
    uint8[7] private cells = [0, 1, 7, 19, 37, 60, 6];
    uint8[7] private controllers;
    address[4] private actors;
    mapping(uint256 => uint256[4]) private scores;
    mapping(uint256 => uint256[4]) private credits;
    mapping(uint256 => uint8) private winners;
    uint256 private epoch = 1;

    function setUp() public override {
        super.setUp();
        actors = [alice, bob, carol, dave];
        for (uint8 i; i < 4; ++i) {
            _join(actors[i], i);
            _deploy(actors[i], cells[i], 1_000 ether);
            army[i][i].pending = 1_000 ether;
        }
        for (uint8 i; i < 7; ++i) {
            controllers[i] = 4;
        }
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_delayedSettlementsMatchEagerModel(bytes32 seed) public {
        for (uint256 step; step < 100; ++step) {
            uint256 random = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = random % 5;
            uint8 actor = uint8((random >> 8) % 4);
            uint8 cell = uint8((random >> 16) % 7);
            uint256 amount = (random >> 32) % (2_000 ether) + 1;
            if (action == 0) {
                _deposit(actor, cell, amount);
            } else if (action == 1 || action == 2) {
                uint256 available = army[actor][cell].active + army[actor][cell].pending;
                if (available == 0) continue;
                amount = amount % available + 1;
                _removeModel(actor, cell, amount);
                if (action == 1) {
                    uint8 destination = (cell + 1 + uint8((random >> 24) % 6)) % 7;
                    army[actor][destination].pending += amount;
                    _move(actors[actor], cells[cell], cells[destination], amount);
                } else {
                    _retreat(actors[actor], cells[cell], amount);
                }
            } else {
                _advance();
            }
            if (step % 10 == 0) _checkLiveArmies();
        }
        // Include two complete seasons, with a backlog and subsequent historical mutations.
        while (epoch <= 60) _advance();
        _settleThrough(epoch - 1);
        _checkLiveArmies();
        for (uint8 cell; cell < 7; ++cell) {
            assertEq(game.territoryState(cells[cell]).controller, controllers[cell]);
        }
        for (uint256 season = 1; season <= 2; ++season) {
            uint256[4] memory actual = game.seasonScores(season);
            assertEq(game.seasonWinner(season), winners[season]);
            for (uint8 actor; actor < 4; ++actor) {
                assertEq(actual[actor], scores[season][actor]);
                assertEq(game.eligibleEpochs(actors[actor], season), credits[season][actor]);
                bool eligible = winners[season] == actor && credits[season][actor] >= 7;
                assertEq(game.isEligible(actors[actor], season), eligible);
            }
        }
        _assertConserved();
    }

    function _deposit(uint8 actor, uint8 cell, uint256 amount) private {
        // At most 100 deposits of 2,000 NECTAR; initial funding and approval cover them.
        army[actor][cell].pending += amount;
        _deploy(actors[actor], cells[cell], amount);
    }

    function _removeModel(uint8 actor, uint8 cell, uint256 amount) private {
        Position storage position = army[actor][cell];
        if (position.pending >= amount) {
            position.pending -= amount;
        } else {
            position.active -= amount - position.pending;
            position.pending = 0;
        }
    }

    function _advance() private {
        uint256 season = (epoch - 1) / 30 + 1;
        for (uint8 cell; cell < 7; ++cell) {
            uint256 maxStake;
            for (uint8 actor; actor < 4; ++actor) {
                if (army[actor][cell].active > maxStake) maxStake = army[actor][cell].active;
            }
            uint8 ties;
            uint8 leader;
            for (uint8 actor; actor < 4; ++actor) {
                if (army[actor][cell].active == maxStake) {
                    ++ties;
                    leader = actor;
                }
            }
            if (ties == 1) controllers[cell] = leader;
            if (controllers[cell] < 4) scores[season][controllers[cell]] += _points(cells[cell]);
        }
        for (uint8 actor; actor < 4; ++actor) {
            uint256 active;
            for (uint8 cell; cell < 7; ++cell) {
                active += army[actor][cell].active;
                army[actor][cell].active += army[actor][cell].pending;
                army[actor][cell].pending = 0;
            }
            if (active >= 1_000 ether) ++credits[season][actor];
        }
        if (epoch % 30 == 0) {
            uint256 maxScore;
            for (uint8 actor; actor < 4; ++actor) {
                if (scores[season][actor] > maxScore) maxScore = scores[season][actor];
            }
            uint8 ties;
            uint8 leader;
            for (uint8 actor; actor < 4; ++actor) {
                if (scores[season][actor] == maxScore) {
                    ++ties;
                    leader = actor;
                }
            }
            if (ties == 1) {
                winners[season] = leader;
            } else if (controllers[0] < 4 && scores[season][controllers[0]] == maxScore) {
                winners[season] = controllers[0];
            } else {
                winners[season] = 4;
            }
        }
        ++epoch;
        _atEpoch(epoch);
    }

    function _checkLiveArmies() private view {
        for (uint8 cell; cell < 7; ++cell) {
            HiveWars.TerritoryView memory state = game.territoryState(cells[cell]);
            for (uint8 actor; actor < 4; ++actor) {
                assertEq(state.active[actor], army[actor][cell].active);
                assertEq(state.pending[actor], army[actor][cell].pending);
            }
        }
    }

    function _points(uint8 territory) private pure returns (uint256) {
        if (territory == 0) return 5;
        if (territory <= 6) return 3;
        if (territory <= 18) return 2;
        return 1;
    }
}
