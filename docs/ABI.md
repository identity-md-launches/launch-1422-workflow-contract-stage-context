# Contract ABI and integration notes

Canonical JSON ABI arrays, generated from Solidity 0.8.26 artifacts:

- [LaunchToken.json](abi/LaunchToken.json)
- [HiveWars.json](abi/HiveWars.json)
- [ConquerorBadge.json](abi/ConquerorBadge.json)

The JSON arrays include all tuple components, errors, indexed event fields and inherited standard
interfaces. All writes below are nonpayable. Read values in token minor units (18 decimals),
one-based global epochs/seasons, zero-based territory/colony IDs. Colony ID **4** is neutral.

## LaunchToken

Constructor: `constructor()`; mint exactly `1e27` to the deploying factory.
Standard ERC20 `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`,
`transfer`, `transferFrom`. Ordinary `Transfer` and `Approval` events. No privileged extensions.

## HiveWars

Constructor: `constructor(address nectarToken_)`, supplied as `$token`. `nectarToken()` and
`startTime()` are immutable bindings. The game has no owner or setter.

| Write | Behavior |
| --- | --- |
| `joinColony(uint8 colony)` | Lock the current season's choice; a new-season switch puts carried troops into pending. |
| `deploy(uint8 territory, uint256 amount)` | Pull tokens from caller and add pending stake. Needs ERC20 approval. |
| `move(uint8 from, uint8 to, uint256 amount)` | Consume source pending first, then active; destination is pending. |
| `retreat(uint8 territory, uint256 amount)` | Consume pending first, then active; queue a 24-hour cooldown. |
| `claimRetreat()` | Pay up to 64 mature queue entries to the caller. |
| `settleEpoch()` | Settle exactly the next ended global epoch; finalizes each 30-epoch season. |

| Read | Return / interpretation |
| --- | --- |
| `currentEpoch()`, `currentSeason()` | Live one-based clock, independent of settlement. |
| `territoryCoordinates(uint8)` | `(int8 q, int8 r)` axial coordinates. |
| `territoryPoints(uint8)` | `uint8` points: 5, 3, 2, 1, 1 by ring. |
| `territoryState(uint8)` | `TerritoryView { uint8 controller; uint256[4] active; uint256[4] pending; }`. Balances are live; controller is last settled. |
| `mapState()` | `TerritoryView[61]`, ordered by territory ID. |
| `colonyState()` | `ColonyView { uint256[4] members; uint256[4] active; uint256[4] score; }`. Scores are only settled points in the current clock season. |
| `playerState(address)` | `PlayerView` tuple described below. Unjoined colony is 4. |
| `seasonInfo()` | `SeasonView` tuple described below. |
| `lastSettledEpoch()` | 0 before any settlement. Settle while `lastSettledEpoch + 1 < currentEpoch`. |
| `seasonScores(uint256)` | `uint256[4]` settled points for that season, including partial seasons. |
| `isSeasonFinalized(uint256)` | True when every epoch in the season is settled. False for 0. |
| `seasonWinner(uint256)` | Final winner 0–3 or draw 4. Reverts if not finalized. |
| `colonyForSeason(address,uint256)` | Historical season affiliation, with inherited membership until a new choice. 4 before joining. |
| `eligibleEpochs(address,uint256)` | Completed qualifying epochs, 0–30; does not require settlement. |
| `isEligible(address,uint256)` | Finalized winner membership plus at least seven qualifying epochs. False while pending finalization or for a draw. |
| `keeperSettlements(address)` | Number of successfully settled epochs by that caller. |
| `totalStaked()`, `totalCooldown()` | Aggregate player liabilities. Direct token donations are not liabilities. |
| `cooldownQueue(address)` | `(uint256 head, uint256 length)`, indexes of unclaimed queue and total appended entries. |
| `cooldownEntry(address,uint256)` | `{ uint256 amount; uint256 unlockAt; }`. Claimed entries are cleared; out-of-bounds reverts. |

`PlayerView` components, in ABI order:

| Component | Meaning |
| --- | --- |
| `uint8 colony` | Current inherited/chosen colony, or 4. |
| `uint256 choiceSeason` | Last confirmed season, 0 if unjoined. A new choice is available when this is below `currentSeason`. |
| `uint256[61] deployments` | Current active tokens per territory. |
| `uint256[61] pending` | Current pending tokens per territory. |
| `uint256 totalActive` | Sum of deployments. |
| `uint256 totalPending` | Sum of pending. |
| `uint256 cooldown` | Entire unclaimed withdrawal liability, including immature entries. |
| `uint256 nextUnlock` | Oldest unclaimed entry's timestamp, 0 if empty. |
| `uint256 claimable` | Amount one `claimRetreat` call can pay now, capped at 64 mature entries. |
| `uint256 eligibleEpochs` | Completed qualifying epochs in the current clock season. |

`SeasonView` components, in ABI order: `season`, `epoch` (global), `epochInSeason` (1–30),
`secondsLeft` (in the epoch), `seasonSecondsLeft`, `lastSettled`, `uint8[] pastWinners`.
At a boundary `secondsLeft` is 86400. `pastWinners[0]` is season 1; only finalized seasons appear.
For long histories, use individual `seasonWinner` reads instead of requesting the complete array.

### Events

```solidity
event Joined(address indexed player, uint256 indexed season, uint8 colony);
event Deployed(address indexed player, uint8 indexed territory, uint256 amount, uint256 activationEpoch);
event Moved(address indexed player, uint8 indexed from, uint8 indexed to, uint256 amount, uint256 activationEpoch);
event Retreated(address indexed player, uint8 indexed territory, uint256 amount, uint256 unlockAt);
event RetreatClaimed(address indexed player, uint256 amount);
event Settled(uint256 indexed epoch, uint8[4] territoriesPerColony);
event TerritoryCaptured(uint8 indexed territory, uint8 from, uint8 to);
event SeasonEnded(uint256 indexed season, uint8 winner);
```

`Joined` also fires when the first troop action confirms an inherited colony in a new season.
A colony change moves all the wallet's troops as part of that event; refresh `playerState` and
`mapState` rather than expecting individual `Moved` events for it.
`TerritoryCaptured` is emitted before the associated `Settled` event. To label a historical capture,
associate those logs in transaction/log order with that settlement's epoch, not the block timestamp.
The counts in `Settled` exclude neutral cells. The final epoch emits `SeasonEnded` after `Settled`.
Index `Settled` transaction callers for the keeper leaderboard and confirm counts with
`keeperSettlements`. No onchain enumerable leaderboard is maintained.

Main custom errors: `InvalidToken`, `InvalidColony`, `InvalidTerritory`, `ZeroAmount`,
`SameTerritory`, `NotJoined`, `ColonyLocked`, `InsufficientStake`, `NothingToClaim`,
`NoEndedEpoch`, `SeasonNotFinalized`, `UnexpectedTokenAmount`; ERC20/SafeERC20 and reentrancy
errors can also propagate. No amount of an invalid action is partially applied.

## ConquerorBadge

Constructor: `constructor(address hiveWars_)`, supplied as `$contract:HiveWars`.

| Method | Meaning |
| --- | --- |
| `hiveWars()` | Immutable game reference. |
| `claim(uint256 season) returns (uint256 tokenId)` | Mint to eligible caller, only after finalization. Contract callers must accept safe mint. |
| `badgeOf(address wallet,uint256 season)` | Minted token ID, or 0 when unclaimed. |
| `badgeData(uint256 tokenId)` | `(uint256 season, uint8 colony)` saved on mint. Query `ownerOf` to establish existence. |
| `totalSupply()` | Mint count; IDs are 1 through this value. |
| `ownerOf`, `balanceOf`, `name`, `symbol` | Standard ERC721 reads. |
| `tokenURI(uint256)` | `data:application/json;base64,...`, with embedded `data:image/svg+xml;base64,...`. |
| `locked(uint256)` | ERC5192, true for minted IDs; nonexistent IDs revert. |
| `supportsInterface(bytes4)` | ERC165, ERC721, ERC721 metadata and ERC5192. |
| `transferFrom`, both `safeTransferFrom` overloads | Always fail to transfer a token. |
| `approve`, `setApprovalForAll` | Always revert `Soulbound()`. |

Mint events are standard ERC721 `Transfer(address(0), player, tokenId)`, ERC5192 `Locked(tokenId)`,
and `BadgeClaimed(address indexed player, uint256 indexed season, uint256 indexed tokenId, uint8 colony)`.
Index these for a wallet's badges. There is no ERC721 enumerable extension or burn entrypoint.

Claim errors: `InvalidGame`, `SeasonNotEnded` (including ended but not fully settled),
`NotEligible`, `AlreadyClaimed`; standard safe-mint receiver errors and reentrancy errors also apply.
Transferred-to-zero and nonexistent-token calls may use standard ERC721 errors. Badges remain
soulbound regardless of which rejection is returned.
