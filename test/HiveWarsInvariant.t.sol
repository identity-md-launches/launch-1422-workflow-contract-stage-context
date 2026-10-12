// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {HiveTestBase, HiveWars, LaunchToken} from "./TestBase.sol";

contract HiveHandler is Test {
    LaunchToken public immutable token;
    HiveWars public immutable game;
    address[4] public actors;
    mapping(address => uint256) public liability;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public settlements;

    constructor(LaunchToken token_, HiveWars game_, address[4] memory actors_) {
        token = token_;
        game = game_;
        actors = actors_;
    }

    function deploy(uint256 actorSeed, uint8 territorySeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        vm.startPrank(actor);
        token.approve(address(game), amount);
        game.deploy(territorySeed % 61, amount);
        vm.stopPrank();
        deposits += amount;
        liability[actor] += amount;
    }

    function move(uint256 actorSeed, uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        HiveWars.PlayerView memory p = game.playerState(actor);
        uint8 from = _occupied(p, fromSeed % 61);
        uint8 to = toSeed % 61;
        if (from == to) to = (to + 1) % 61;
        uint256 available = p.deployments[from] + p.pending[from];
        if (available == 0) return;
        vm.prank(actor);
        game.move(from, to, bound(amountSeed, 1, available));
    }

    function retreat(uint256 actorSeed, uint8 territorySeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        HiveWars.PlayerView memory p = game.playerState(actor);
        uint8 territory = _occupied(p, territorySeed % 61);
        uint256 available = p.deployments[territory] + p.pending[territory];
        if (available == 0) return;
        vm.prank(actor);
        game.retreat(territory, bound(amountSeed, 1, available));
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 claimable = game.playerState(actor).claimable;
        if (claimable == 0) return;
        vm.prank(actor);
        game.claimRetreat();
        withdrawals += claimable;
        liability[actor] -= claimable;
    }

    function chooseColony(uint256 actorSeed, uint8 colonySeed) external {
        address actor = actors[actorSeed % 4];
        if (game.playerState(actor).choiceSeason == game.currentSeason()) return;
        vm.prank(actor);
        game.joinColony(colonySeed % 4);
    }

    function _occupied(HiveWars.PlayerView memory p, uint8 start) private pure returns (uint8) {
        for (uint8 i; i < 61; ++i) {
            uint8 cell = (start + i) % 61;
            if (p.deployments[cell] + p.pending[cell] != 0) return cell;
        }
        return start;
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1, 35 days));
    }

    function settle() external {
        if (game.lastSettledEpoch() + 1 >= game.currentEpoch()) return;
        game.settleEpoch();
        ++settlements;
    }
}

contract HiveWarsInvariantTest is StdInvariant, HiveTestBase {
    HiveHandler internal handler;

    function setUp() public override {
        super.setUp();
        _join(alice, 0);
        _join(bob, 1);
        _join(carol, 2);
        _join(dave, 3);
        address[4] memory actors = [alice, bob, carol, dave];
        handler = new HiveHandler(token, game, actors);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deploy.selector;
        selectors[1] = handler.move.selector;
        selectors[2] = handler.retreat.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.chooseColony.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.settle.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allTokensBelongToDepositors() public view {
        uint256 totalStake;
        uint256 cooldowns;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            HiveWars.PlayerView memory p = game.playerState(actor);
            uint256 playerStake = p.totalActive + p.totalPending;
            totalStake += playerStake;
            cooldowns += p.cooldown;
            assertEq(playerStake + p.cooldown, handler.liability(actor));
            assertEq(token.balanceOf(actor) + playerStake + p.cooldown, 1_000_000 ether);
        }
        assertEq(totalStake, game.totalStaked());
        assertEq(cooldowns, game.totalCooldown());
        assertEq(token.balanceOf(address(game)), totalStake + cooldowns);
        assertEq(totalStake + cooldowns, handler.deposits() - handler.withdrawals());
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_everyTerritoryEqualsItsPlayers() public view {
        HiveWars.PlayerView[4] memory players;
        for (uint256 i; i < 4; ++i) {
            players[i] = game.playerState(handler.actors(i));
        }
        HiveWars.TerritoryView[61] memory cells = game.mapState();
        uint256[4] memory totalActive;
        uint256[4] memory members;
        for (uint256 i; i < 4; ++i) {
            ++members[players[i].colony];
        }
        for (uint8 territory; territory < 61; ++territory) {
            uint256[4] memory active;
            uint256[4] memory pending;
            for (uint256 i; i < 4; ++i) {
                uint8 colony = players[i].colony;
                active[colony] += players[i].deployments[territory];
                pending[colony] += players[i].pending[territory];
            }
            for (uint8 c; c < 4; ++c) {
                assertEq(cells[territory].active[c], active[c]);
                assertEq(cells[territory].pending[c], pending[c]);
                totalActive[c] += active[c];
            }
            assertLe(cells[territory].controller, 4);
        }
        HiveWars.ColonyView memory colonies = game.colonyState();
        for (uint8 c; c < 4; ++c) {
            assertEq(colonies.active[c], totalActive[c]);
            assertEq(colonies.members[c], members[c]);
        }
    }

    function invariant_settlementCannotSkipDuplicateOrSettleFuture() public view {
        assertEq(game.lastSettledEpoch(), handler.settlements());
        assertEq(game.keeperSettlements(address(handler)), handler.settlements());
        assertLt(game.lastSettledEpoch(), game.currentEpoch());
    }
}
