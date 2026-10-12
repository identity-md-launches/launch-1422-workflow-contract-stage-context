// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice A perpetual territory game with token escrow. Only depositors can withdraw their tokens.
/// @dev Epochs and seasons are one-based. Historical checkpoints preserve end-of-epoch stakes even
/// when settlement is delayed. Pending stake matures lazily, exactly at the next epoch boundary.
contract HiveWars is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EPOCH_DURATION = 1 days;
    uint256 public constant EPOCHS_PER_SEASON = 30;
    uint256 public constant RETREAT_COOLDOWN = 1 days;
    uint256 public constant ELIGIBILITY_STAKE = 1_000 ether;
    uint256 public constant ELIGIBILITY_EPOCHS = 7;
    uint256 public constant CLAIM_BATCH_SIZE = 64;
    uint8 public constant TERRITORY_COUNT = 61;
    uint8 public constant COLONY_COUNT = 4;
    uint8 public constant NEUTRAL = 4;

    IERC20 public immutable nectarToken;
    uint256 public immutable startTime;
    uint256 public lastSettledEpoch;
    uint256 public totalStaked;
    uint256 public totalCooldown;
    mapping(address => uint256) public keeperSettlements;

    // Each checkpoint is the final state after all actions in its epoch. If queried at a later
    // epoch, its pending balance has matured. No mutation can change an already ended epoch.
    struct TerritoryCheckpoint {
        uint256 epoch;
        uint256[4] active;
        uint256[4] pending;
    }

    struct StakeCheckpoint {
        uint256 epoch;
        uint256 active;
        uint256 pending;
    }

    struct Membership {
        uint256 season;
        uint256 sinceEpoch;
        uint8 colony;
    }

    struct Cooldown {
        uint256 amount;
        uint256 unlockAt;
    }

    struct Player {
        Membership[] memberships;
        StakeCheckpoint[] history;
        mapping(uint8 => StakeCheckpoint) positions;
        Cooldown[] cooldowns;
        uint256 cooldownHead;
        uint256 cooldownAmount;
    }

    struct TerritoryView {
        uint8 controller;
        uint256[4] active;
        uint256[4] pending;
    }

    struct ColonyView {
        uint256[4] members;
        uint256[4] active;
        uint256[4] score;
    }

    struct PlayerView {
        uint8 colony;
        uint256 choiceSeason;
        uint256[61] deployments;
        uint256[61] pending;
        uint256 totalActive;
        uint256 totalPending;
        uint256 cooldown;
        uint256 nextUnlock;
        uint256 claimable;
        uint256 eligibleEpochs;
    }

    struct SeasonView {
        uint256 season;
        uint256 epoch;
        uint256 epochInSeason;
        uint256 secondsLeft;
        uint256 seasonSecondsLeft;
        uint256 lastSettled;
        uint8[] pastWinners;
    }

    mapping(uint8 => TerritoryCheckpoint[]) private _territories;
    mapping(address => Player) private _players;
    uint8[61] private _controllers;
    uint256[4] private _members;
    mapping(uint256 => uint256[4]) private _scores;
    mapping(uint256 => uint8) private _winners;

    error InvalidToken();
    error InvalidColony();
    error InvalidTerritory();
    error ZeroAmount();
    error SameTerritory();
    error NotJoined();
    error ColonyLocked();
    error InsufficientStake();
    error NothingToClaim();
    error NoEndedEpoch();
    error SeasonNotFinalized();
    error UnexpectedTokenAmount();

    event Joined(address indexed player, uint256 indexed season, uint8 colony);
    event Deployed(address indexed player, uint8 indexed territory, uint256 amount, uint256 activationEpoch);
    event Moved(address indexed player, uint8 indexed from, uint8 indexed to, uint256 amount, uint256 activationEpoch);
    event Retreated(address indexed player, uint8 indexed territory, uint256 amount, uint256 unlockAt);
    event RetreatClaimed(address indexed player, uint256 amount);
    event Settled(uint256 indexed epoch, uint8[4] territoriesPerColony);
    event TerritoryCaptured(uint8 indexed territory, uint8 from, uint8 to);
    event SeasonEnded(uint256 indexed season, uint8 winner);

    /// @param nectarToken_ The launch's $token. No external calls are made during construction.
    constructor(address nectarToken_) {
        if (nectarToken_ == address(0)) revert InvalidToken();
        nectarToken = IERC20(nectarToken_);
        startTime = block.timestamp;
        for (uint8 i; i < TERRITORY_COUNT; ++i) {
            _controllers[i] = NEUTRAL;
        }
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - startTime) / EPOCH_DURATION + 1;
    }

    function currentSeason() public view returns (uint256) {
        return _seasonOf(currentEpoch());
    }

    /// @notice Choose once per season. Playing in a new season confirms the inherited colony.
    /// @dev A new-season switch moves all remaining troops to the new colony as pending. Earlier
    /// contributions in that season do not qualify for the new colony's badge. Past seasons persist.
    function joinColony(uint8 colony) external nonReentrant {
        if (colony >= COLONY_COUNT) revert InvalidColony();
        Player storage p = _players[msg.sender];
        uint256 epoch = currentEpoch();
        uint256 season = _seasonOf(epoch);
        uint256 count = p.memberships.length;
        if (count != 0) {
            Membership storage previous = p.memberships[count - 1];
            if (previous.season == season) revert ColonyLocked();
            uint8 oldColony = previous.colony;
            if (oldColony != colony) {
                --_members[oldColony];
                ++_members[colony];
                _changeColony(p, oldColony, colony, epoch);
            } else {
                // Keeping an inherited colony preserves credit from the beginning of the season.
                epoch = (season - 1) * EPOCHS_PER_SEASON + 1;
            }
        } else {
            ++_members[colony];
        }
        p.memberships.push(Membership(season, epoch, colony));
        emit Joined(msg.sender, season, colony);
    }

    function deploy(uint8 territory, uint256 amount) external nonReentrant {
        _validateAction(territory, amount);
        // Check code on first use, never in a factory-run constructor.
        if (address(nectarToken).code.length == 0) revert InvalidToken();
        uint256 epoch = currentEpoch();
        Player storage p = _players[msg.sender];
        uint8 colony = _confirmMembership(p, epoch);
        StakeCheckpoint storage user = _touchUser(p, epoch);
        StakeCheckpoint storage position = _touchPosition(p, territory, epoch);
        TerritoryCheckpoint storage cell = _touchTerritory(territory, epoch);
        position.pending += amount;
        user.pending += amount;
        cell.pending[colony] += amount;
        totalStaked += amount;
        uint256 beforeBalance = nectarToken.balanceOf(address(this));
        nectarToken.safeTransferFrom(msg.sender, address(this), amount);
        if (nectarToken.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedTokenAmount();
        emit Deployed(msg.sender, territory, amount, epoch + 1);
    }

    /// @notice Pending stake is consumed first; any active portion leaves the source immediately.
    function move(uint8 from, uint8 to, uint256 amount) external nonReentrant {
        _validateAction(from, amount);
        _validateTerritory(to);
        if (from == to) revert SameTerritory();
        uint256 epoch = currentEpoch();
        Player storage p = _players[msg.sender];
        uint8 colony = _confirmMembership(p, epoch);
        (uint256 activeRemoved, uint256 pendingRemoved) = _remove(p, from, colony, amount, epoch);
        _touchPosition(p, to, epoch).pending += amount;
        _touchTerritory(to, epoch).pending[colony] += amount;
        StakeCheckpoint storage user = _touchUser(p, epoch);
        user.active -= activeRemoved;
        user.pending = user.pending - pendingRemoved + amount;
        emit Moved(msg.sender, from, to, amount, epoch + 1);
    }

    /// @notice Queue a separate 24-hour withdrawal; later retreats never delay older ones.
    function retreat(uint8 territory, uint256 amount) external nonReentrant {
        _validateAction(territory, amount);
        uint256 epoch = currentEpoch();
        Player storage p = _players[msg.sender];
        uint8 colony = _confirmMembership(p, epoch);
        (uint256 activeRemoved, uint256 pendingRemoved) = _remove(p, territory, colony, amount, epoch);
        StakeCheckpoint storage user = _touchUser(p, epoch);
        user.active -= activeRemoved;
        user.pending -= pendingRemoved;
        totalStaked -= amount;
        totalCooldown += amount;
        p.cooldownAmount += amount;
        uint256 unlockAt = block.timestamp + RETREAT_COOLDOWN;
        uint256 count = p.cooldowns.length;
        if (count > p.cooldownHead && p.cooldowns[count - 1].unlockAt == unlockAt) {
            p.cooldowns[count - 1].amount += amount;
        } else {
            p.cooldowns.push(Cooldown(amount, unlockAt));
        }
        emit Retreated(msg.sender, territory, amount, unlockAt);
    }

    /// @notice Claim up to 64 matured queue entries. Repeat for larger queues. No season lock.
    function claimRetreat() external nonReentrant {
        Player storage p = _players[msg.sender];
        uint256 head = p.cooldownHead;
        uint256 stop = head + CLAIM_BATCH_SIZE;
        if (stop > p.cooldowns.length) stop = p.cooldowns.length;
        uint256 amount;
        while (head < stop && p.cooldowns[head].unlockAt <= block.timestamp) {
            amount += p.cooldowns[head].amount;
            delete p.cooldowns[head];
            ++head;
        }
        if (amount == 0) revert NothingToClaim();
        p.cooldownHead = head;
        p.cooldownAmount -= amount;
        totalCooldown -= amount;
        nectarToken.safeTransfer(msg.sender, amount);
        emit RetreatClaimed(msg.sender, amount);
    }

    /// @notice Settle exactly the oldest ended epoch. No keeper is trusted or paid.
    function settleEpoch() external nonReentrant {
        uint256 epoch = lastSettledEpoch + 1;
        if (epoch >= currentEpoch()) revert NoEndedEpoch();
        uint256 season = _seasonOf(epoch);
        uint8[4] memory counts;
        for (uint8 territory; territory < TERRITORY_COUNT; ++territory) {
            (uint256[4] memory active,) = _territoryAt(territory, epoch);
            uint8 previous = _controllers[territory];
            uint8 controller = _controller(active, previous);
            if (controller != previous) {
                _controllers[territory] = controller;
                emit TerritoryCaptured(territory, previous, controller);
            }
            if (controller != NEUTRAL) {
                ++counts[controller];
                _scores[season][controller] += territoryPoints(territory);
            }
        }
        lastSettledEpoch = epoch;
        ++keeperSettlements[msg.sender];
        emit Settled(epoch, counts);
        if (epoch % EPOCHS_PER_SEASON == 0) {
            uint8 winner = _seasonWinner(season);
            _winners[season] = winner;
            emit SeasonEnded(season, winner);
        }
    }

    function isSeasonFinalized(uint256 season) public view returns (bool) {
        return season != 0 && season <= lastSettledEpoch / EPOCHS_PER_SEASON;
    }

    function seasonWinner(uint256 season) public view returns (uint8) {
        if (!isSeasonFinalized(season)) revert SeasonNotFinalized();
        return _winners[season];
    }

    function seasonScores(uint256 season) external view returns (uint256[4] memory) {
        return _scores[season];
    }

    /// @notice Count completed epochs with >= 1,000 active NECTAR throughout that epoch.
    /// @dev At most 30 binary searches regardless of elapsed time or settlement backlog. Active
    /// stake only increases at boundaries, so its end-of-epoch value is also its minimum that epoch.
    function eligibleEpochs(address account, uint256 season) public view returns (uint256 count) {
        if (season == 0 || season > currentSeason()) return 0;
        Player storage p = _players[account];
        (bool found, Membership memory membership) = _membershipAt(p, season);
        if (!found) return 0;
        uint256 first = (season - 1) * EPOCHS_PER_SEASON + 1;
        if (membership.sinceEpoch > first) first = membership.sinceEpoch;
        uint256 end = season * EPOCHS_PER_SEASON + 1;
        uint256 epoch = currentEpoch();
        if (end > epoch) end = epoch;
        for (uint256 i = first; i < end; ++i) {
            if (_userActiveAt(p, i) >= ELIGIBILITY_STAKE) ++count;
        }
    }

    function isEligible(address account, uint256 season) external view returns (bool) {
        if (!isSeasonFinalized(season)) return false;
        uint8 winner = _winners[season];
        if (winner == NEUTRAL) return false;
        (bool found, Membership memory membership) = _membershipAt(_players[account], season);
        return found && membership.colony == winner && eligibleEpochs(account, season) >= ELIGIBILITY_EPOCHS;
    }

    function colonyForSeason(address account, uint256 season) external view returns (uint8) {
        (bool found, Membership memory membership) = _membershipAt(_players[account], season);
        return found ? membership.colony : NEUTRAL;
    }

    function territoryState(uint8 territory) public view returns (TerritoryView memory state) {
        _validateTerritory(territory);
        state.controller = _controllers[territory];
        (state.active, state.pending) = _territoryAt(territory, currentEpoch());
    }

    function mapState() external view returns (TerritoryView[61] memory states) {
        for (uint8 i; i < TERRITORY_COUNT; ++i) {
            states[i] = territoryState(i);
        }
    }

    function colonyState() external view returns (ColonyView memory state) {
        state.members = _members;
        state.score = _scores[currentSeason()];
        uint256 epoch = currentEpoch();
        for (uint8 i; i < TERRITORY_COUNT; ++i) {
            (uint256[4] memory active,) = _territoryAt(i, epoch);
            for (uint8 c; c < COLONY_COUNT; ++c) {
                state.active[c] += active[c];
            }
        }
    }

    function playerState(address account) external view returns (PlayerView memory state) {
        Player storage p = _players[account];
        uint256 memberships = p.memberships.length;
        state.colony = memberships == 0 ? NEUTRAL : p.memberships[memberships - 1].colony;
        if (memberships != 0) state.choiceSeason = p.memberships[memberships - 1].season;
        uint256 epoch = currentEpoch();
        for (uint8 i; i < TERRITORY_COUNT; ++i) {
            StakeCheckpoint storage position = p.positions[i];
            (uint256 active, uint256 pending) = _positionAt(position, epoch);
            state.deployments[i] = active;
            state.pending[i] = pending;
            state.totalActive += active;
            state.totalPending += pending;
        }
        state.cooldown = p.cooldownAmount;
        uint256 head = p.cooldownHead;
        uint256 stop = head + CLAIM_BATCH_SIZE;
        if (stop > p.cooldowns.length) stop = p.cooldowns.length;
        if (head < stop) state.nextUnlock = p.cooldowns[head].unlockAt;
        while (head < stop && p.cooldowns[head].unlockAt <= block.timestamp) {
            state.claimable += p.cooldowns[head].amount;
            ++head;
        }
        state.eligibleEpochs = eligibleEpochs(account, _seasonOf(epoch));
    }

    function cooldownQueue(address account) external view returns (uint256 head, uint256 length) {
        Player storage p = _players[account];
        return (p.cooldownHead, p.cooldowns.length);
    }

    function cooldownEntry(address account, uint256 index) external view returns (Cooldown memory) {
        return _players[account].cooldowns[index];
    }

    function seasonInfo() external view returns (SeasonView memory info) {
        info.epoch = currentEpoch();
        info.season = _seasonOf(info.epoch);
        info.epochInSeason = (info.epoch - 1) % EPOCHS_PER_SEASON + 1;
        info.secondsLeft = EPOCH_DURATION - (block.timestamp - startTime) % EPOCH_DURATION;
        info.seasonSecondsLeft = (EPOCHS_PER_SEASON - info.epochInSeason) * EPOCH_DURATION + info.secondsLeft;
        info.lastSettled = lastSettledEpoch;
        uint256 ended = lastSettledEpoch / EPOCHS_PER_SEASON;
        info.pastWinners = new uint8[](ended);
        for (uint256 i; i < ended; ++i) {
            info.pastWinners[i] = _winners[i + 1];
        }
    }

    /// @notice Core = 0; each following ring is contiguous, clockwise from axial (-radius, radius).
    function territoryCoordinates(uint8 territory) external pure returns (int8 q, int8 r) {
        _validateTerritory(territory);
        if (territory == 0) return (0, 0);
        uint8 radius = 1;
        while (territory > 3 * radius * (radius + 1)) ++radius;
        uint8 offset = territory - (1 + 3 * radius * (radius - 1));
        q = -int8(radius);
        r = int8(radius);
        int8[6] memory dq = [int8(1), 1, 0, -1, -1, 0];
        int8[6] memory dr = [int8(0), -1, -1, 0, 1, 1];
        for (uint8 side; side < 6; ++side) {
            uint8 steps = offset < radius ? offset : radius;
            q += dq[side] * int8(steps);
            r += dr[side] * int8(steps);
            offset -= steps;
            if (offset == 0) break;
        }
    }

    function territoryPoints(uint8 territory) public pure returns (uint8) {
        _validateTerritory(territory);
        if (territory == 0) return 5;
        if (territory <= 6) return 3;
        if (territory <= 18) return 2;
        return 1;
    }

    function _changeColony(Player storage p, uint8 oldColony, uint8 newColony, uint256 epoch) private {
        StakeCheckpoint storage user = _touchUser(p, epoch);
        for (uint8 i; i < TERRITORY_COUNT; ++i) {
            StakeCheckpoint storage position = p.positions[i];
            uint256 amount = position.active + position.pending;
            if (amount == 0) continue;
            _touchPosition(p, i, epoch);
            TerritoryCheckpoint storage cell = _touchTerritory(i, epoch);
            cell.active[oldColony] -= position.active;
            cell.pending[oldColony] -= position.pending;
            cell.pending[newColony] += amount;
            position.active = 0;
            position.pending = amount;
        }
        user.pending += user.active;
        user.active = 0;
    }

    function _confirmMembership(Player storage p, uint256 epoch) private returns (uint8 colony) {
        uint256 count = p.memberships.length;
        if (count == 0) revert NotJoined();
        Membership storage membership = p.memberships[count - 1];
        colony = membership.colony;
        uint256 season = _seasonOf(epoch);
        if (membership.season != season) {
            p.memberships.push(Membership(season, (season - 1) * EPOCHS_PER_SEASON + 1, colony));
            emit Joined(msg.sender, season, colony);
        }
    }

    function _remove(Player storage p, uint8 territory, uint8 colony, uint256 amount, uint256 epoch)
        private
        returns (uint256 activeRemoved, uint256 pendingRemoved)
    {
        StakeCheckpoint storage position = _touchPosition(p, territory, epoch);
        if (amount > position.active + position.pending) revert InsufficientStake();
        pendingRemoved = amount < position.pending ? amount : position.pending;
        activeRemoved = amount - pendingRemoved;
        position.pending -= pendingRemoved;
        position.active -= activeRemoved;
        TerritoryCheckpoint storage cell = _touchTerritory(territory, epoch);
        cell.pending[colony] -= pendingRemoved;
        cell.active[colony] -= activeRemoved;
    }

    function _touchTerritory(uint8 territory, uint256 epoch) private returns (TerritoryCheckpoint storage cp) {
        TerritoryCheckpoint[] storage history = _territories[territory];
        uint256 count = history.length;
        if (count == 0 || history[count - 1].epoch != epoch) {
            history.push();
            cp = history[count];
            cp.epoch = epoch;
            if (count != 0) {
                TerritoryCheckpoint storage previous = history[count - 1];
                for (uint8 c; c < COLONY_COUNT; ++c) {
                    cp.active[c] = previous.active[c] + previous.pending[c];
                }
            }
        } else {
            cp = history[count - 1];
        }
    }

    function _touchUser(Player storage p, uint256 epoch) private returns (StakeCheckpoint storage cp) {
        uint256 count = p.history.length;
        if (count == 0) {
            p.history.push(StakeCheckpoint(epoch, 0, 0));
        } else if (p.history[count - 1].epoch != epoch) {
            StakeCheckpoint storage previous = p.history[count - 1];
            p.history.push(StakeCheckpoint(epoch, previous.active + previous.pending, 0));
        } else {
            return p.history[count - 1];
        }
        return p.history[p.history.length - 1];
    }

    function _touchPosition(Player storage p, uint8 territory, uint256 epoch)
        private
        returns (StakeCheckpoint storage position)
    {
        position = p.positions[territory];
        if (position.epoch != epoch) {
            position.active += position.pending;
            position.pending = 0;
            position.epoch = epoch;
        }
    }

    function _territoryAt(uint8 territory, uint256 epoch)
        private
        view
        returns (uint256[4] memory active, uint256[4] memory pending)
    {
        TerritoryCheckpoint[] storage history = _territories[territory];
        uint256 low;
        uint256 high = history.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (history[mid].epoch <= epoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (active, pending);
        TerritoryCheckpoint storage cp = history[low - 1];
        active = cp.active;
        if (cp.epoch == epoch) {
            pending = cp.pending;
        } else {
            for (uint8 c; c < COLONY_COUNT; ++c) {
                active[c] += cp.pending[c];
            }
        }
    }

    function _userActiveAt(Player storage p, uint256 epoch) private view returns (uint256) {
        uint256 low;
        uint256 high = p.history.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (p.history[mid].epoch <= epoch) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return 0;
        StakeCheckpoint storage cp = p.history[low - 1];
        return cp.active + (cp.epoch < epoch ? cp.pending : 0);
    }

    function _membershipAt(Player storage p, uint256 season) private view returns (bool found, Membership memory m) {
        if (season == 0) return (false, m);
        uint256 low;
        uint256 high = p.memberships.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (p.memberships[mid].season <= season) low = mid + 1;
            else high = mid;
        }
        if (low == 0) return (false, m);
        return (true, p.memberships[low - 1]);
    }

    function _positionAt(StakeCheckpoint storage position, uint256 epoch)
        private
        view
        returns (uint256 active, uint256 pending)
    {
        if (position.epoch < epoch) return (position.active + position.pending, 0);
        return (position.active, position.pending);
    }

    function _controller(uint256[4] memory active, uint8 previous) private pure returns (uint8) {
        uint256 maximum;
        uint8 leader;
        bool tie = true;
        for (uint8 c; c < COLONY_COUNT; ++c) {
            if (active[c] > maximum) {
                maximum = active[c];
                leader = c;
                tie = false;
            } else if (active[c] == maximum) {
                tie = true;
            }
        }
        return tie ? previous : leader;
    }

    function _seasonWinner(uint256 season) private view returns (uint8) {
        uint256[4] memory score = _scores[season];
        uint256 maximum;
        uint8 leader;
        bool tie = true;
        for (uint8 c; c < COLONY_COUNT; ++c) {
            if (score[c] > maximum) {
                maximum = score[c];
                leader = c;
                tie = false;
            } else if (score[c] == maximum) {
                tie = true;
            }
        }
        if (!tie) return leader;
        uint8 core = _controllers[0];
        // A draw has no badge winner if the Core cannot break the highest-score tie.
        return core != NEUTRAL && score[core] == maximum ? core : NEUTRAL;
    }

    function _seasonOf(uint256 epoch) private pure returns (uint256) {
        return (epoch - 1) / EPOCHS_PER_SEASON + 1;
    }

    function _validateTerritory(uint8 territory) private pure {
        if (territory >= TERRITORY_COUNT) revert InvalidTerritory();
    }

    function _validateAction(uint8 territory, uint256 amount) private pure {
        _validateTerritory(territory);
        if (amount == 0) revert ZeroAmount();
    }
}
