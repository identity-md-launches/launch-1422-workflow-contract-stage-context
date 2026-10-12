# HIVE WARS — Battle for the Comb

The swarm built the Comb. Now Amber, Obsidian, Jade and Crimson fight for its 61 territories.
Players escrow their own NECTAR, earn colony scores, and may claim a permanent onchain conqueror badge.
This contribution supplies the three contracts, their tests, vendored dependencies and ABI exports.

## Build and check

Run from the repository root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer with 200 runs and `bytecode_hash = "none"`.
All imported dependencies are ordinary files under `lib/`; no package download, submodule, RPC,
environment variable, FFI or filesystem cheatcode permission is required. Python is needed only
for ABI export/checking. After changing source, run `forge build` and
`python3 scripts/export_abis.py` to regenerate the three JSON ABI arrays in `docs/abi/`.
Dependency versions and integrity hashes are in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

The tests cover map geometry, epoch boundaries, ties, ordered settlement, historical mutation
resistance, cooldowns, season changes, eligibility, badges, decoded SVG/JSON, ERC20 failures,
reentrancy, constructor compatibility, bytecode size/opcodes and fund conservation. An independent
eager reference model compares delayed settlement over two seasons against 128 randomized
scenarios. Stateful invariants exercise deposits, moves, retreats, claims, colony changes, time
advances and settlement, checking each territory and each depositor's entitlement.
See [docs/VALIDATION.md](docs/VALIDATION.md) for the recorded local validation and its limits.

## Deployment parameters

The manifest producer can use this dependency order. These are constructor values, not
transactions or a generated manifest:

| Solidity contract | Source | Constructor ABI arguments | Manifest reference |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | none | launch token |
| `HiveWars` | `src/HiveWars.sol` | `address nectarToken_` | `$token` |
| `ConquerorBadge` | `src/ConquerorBadge.sol` | `address hiveWars_` | `$contract:HiveWars` |

All constructors are nonpayable, make no external calls, and require no code at dependency
addresses during construction. Dependency code is checked on first use. Application names fit
the launch's 32-character limit. There are no linked external libraries, proxies, upgrades,
DELEGATECALL, CALLCODE or SELFDESTRUCT paths.

The launch supports passing the token address, so **HiveWars binds NECTAR immutably in its
constructor**. There is no `setNectarToken`, owner, admin, pause, rescue or initialization function.
The optional owner-only one-time setter branch of the brief is therefore unnecessary; tests check
that neither a deployer nor another wallet can call a setter. The frontend should always hide the
optional token-binding panel. Neither the deploying factory nor the launch wallet receives game
or badge privileges. The launch's `$owner` is not an argument to these contracts.

`LaunchToken` is **Nectar / NECTAR**, 18 decimals, with exactly **1,000,000,000 tokens (10^27 minor
units)** minted once to its deploying factory. It has ordinary ERC20 transfers and allowances,
with no additional mint, burn, tax, owner, pause, blocklist or upgrade interface. Neither
application receives any launch allocation; only later player deposits fund the game.

The pinned launch is Ethereum, chain ID **1**, paired with IMD at
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`. The factory handles the 10% swarm distribution,
88% pool allocation and remaining 2% allocation to the paying wallet (or treasury when no wallet
pays). The pool fee is **12500 (1.25%)**, tick spacing **60**, and the manifest's initial price is
`79228162514264337593543950336`. Services derive the effective opening price from the policy's
2,500 IMD opening market cap and token ordering. The token and applications implement no pool
fee logic. The protocol supplies the distributor and initialization guard.

## Game rules and boundary decisions

All token amounts are NECTAR minor units. Colonies are `0 = Amber`, `1 = Obsidian`, `2 = Jade`,
`3 = Crimson`; **4 means neutral / no winner / not joined**. Never interpret an unfinalized
season's default storage value as a winner; `seasonWinner` reverts until finalization.

### Map and clock

The radius-4 axial grid has 61 unique coordinates. Territory 0 is `(0,0)`. Ring IDs are
1–6, 7–18, 19–36 and 37–60, clockwise from `(-radius, radius)`. Core earns 5 points, ring 1 earns
3 per cell, ring 2 earns 2, and rings 3/4 earn 1, for **89 points per fully controlled epoch**.
`territoryCoordinates` and `territoryPoints` expose the mapping.

Epochs are one-based, 24 hours long, relative to `startTime = block.timestamp` at deployment.
An epoch E covers `[startTime + (E-1)*1 day, startTime + E*1 day)`. Each season has 30 epochs;
season 1 starts at deployment. At exactly a boundary, the next epoch/season is current. The
clock advances automatically even without transactions. Ordinary chain timestamp precision
applies; this game does not use randomness.

### Membership and changing colonies

Call `joinColony(0..3)` before deploying. The first explicit colony choice in a season is locked
for that season. In a subsequent season, a wallet may choose again **before its first deploy,
move or retreat of that season**. Such a troop action instead confirms the inherited colony.
A failed action does not confirm it. Claiming a cooldown does not confirm a colony.

Without a new choice, membership and existing troops continue with their previous colony.
Choosing that same colony preserves accumulated eligibility. Choosing a different colony
atomically removes all the wallet's positions from the former colony and places the same amounts
in the new colony as **pending until the next epoch**. No NECTAR is transferred or forfeited.
Earlier contributions in the season stay scored for the former colony and do not count toward
badge eligibility for the newly chosen colony. There is at most one explicit/confirmed choice
per season; historical membership and eligibility in prior seasons never change.

This specifies how the brief's new-season choice interacts with troops left on the map and with
a late first interaction in a season. A wallet cannot retain active forces in two colonies.
`colonyState.members` counts currently affiliated wallets, including idle members; membership
counts do not reset at season boundaries.

### Troops, custody and cooldowns

1. Approve HiveWars to spend the intended amount, then call `deploy(territory, amount)`.
   The deposit is pending in that territory; it becomes active at the start of the next epoch.
2. `move(from, to, amount)` removes troops immediately from the source and makes them pending
   at the destination until the next epoch. Any two distinct territories are allowed; adjacency
   was not a restriction in the brief.
3. `retreat(territory, amount)` removes troops immediately and queues that amount for withdrawal
   at the transaction timestamp plus exactly 24 hours. Both move and retreat consume pending
   troops first, then active troops; no separate pending/active selector is needed.
4. `claimRetreat()` pays the caller's mature queue entries, processing at most 64 per call.
   Repeat if more are ready. Entries created in the same timestamp coalesce; later retreats
   never postpone earlier withdrawals. A failed token transfer reverts the claim completely.

All token-moving functions use OpenZeppelin SafeERC20 and all game mutations have a reentrancy
guard. Withdrawals and troop actions work even with a settlement backlog. There are no rewards,
slashing, fees, keeper payments or privileged withdrawals.

For protocol actions, `NECTAR.balanceOf(HiveWars) = totalStaked + totalCooldown`. Every wei of
those obligations belongs to a depositor. An unsolicited direct ERC20 transfer creates excess
balance, not a troop position or withdrawable credit; there is deliberately no rescue power.
Use `deploy`, not a direct transfer. NECTAR is the fixed, non-rebasing, fee-free launch token,
not an arbitrary asset. Deposits also check the exact amount received. ETH is not accepted.

### Settlement and scoring

Anyone may call `settleEpoch()` after an epoch ends. Each call processes exactly
`lastSettledEpoch + 1`; it cannot skip an epoch, repeat one or settle the current epoch. All
61 territories are processed, and the caller's `keeperSettlements` increments once.

The largest active balance at the **end of that historical epoch** controls each territory.
An outright leader captures it. On any tie for the maximum, its previous controller remains,
including when the incumbent is not among the tied challengers and when all balances are zero.
A neutral territory stays neutral on a tie. This follows the brief's incumbent-retains-ties
rule; previously captured land can keep scoring after its troops retreat until another colony
wins an outright majority of active stake. "Majority" here means the largest individual
colony balance, not more than half of all stake.

Each controlled cell adds its points to that epoch's season. Controllers and troops persist
across seasons; only scores reset. Settling the 30th epoch finalizes that season's winner.
A unique highest score wins. A highest-score tie goes to the Core's controller **if that colony
is among the tied leaders**. Otherwise it is a draw (`NEUTRAL = 4`) with no eligible badges.
This resolves the brief's otherwise unspecified neutral-Core/nonleading-Core tie cases without
arbitrarily favoring a colony ID.

Per-territory history stores at most one checkpoint per epoch with activity. Lazy maturation
projects pending into active after its checkpoint epoch. Binary searches retrieve old epoch
balances, so a later deposit, move, retreat or colony change cannot rewrite unsettled history.
No operation loops over all players or all elapsed epochs; settlement remains one epoch per call.
The live views mature stake even when no state-changing rollover transaction has occurred.
Controllers in those views are the **last settled controllers**, not a prediction.

### Eligibility and badges

A completed epoch counts when a wallet has at least **1,000 NECTAR active across all its
territories throughout that epoch**. Seven qualifying epochs in a season need not be consecutive.
Pending/cooldown balances do not count. A mid-epoch reduction below the threshold disqualifies
that epoch; deposits cannot restore active stake until the next boundary. Active amounts only
increase at boundaries, so the final active amount is also the epoch's minimum. Lazy per-user
checkpoints and a bounded 30-epoch query determine eligibility without keeper iteration over users.

`isEligible(account, season)` also requires a finalized, non-drawn season and that wallet's
colony for the season to match the winner. Advancing the clock alone does not finalize a winner.
Later withdrawals or season changes cannot revoke eligibility from an already ended season.

`ConquerorBadge.claim(season)` safely mints one badge to the caller if eligible. Token IDs start
at 1; `badgeOf(wallet, season)` is 0 when unclaimed. Claims have no deadline. Transfers, approvals
and burns are unavailable. ERC165, ERC721 metadata and ERC5192 locked-token discovery are
supported. Contract wallets must implement `onERC721Received`; a rejecting callback rolls back
the entire claim and can be retried. Mint callbacks cannot reenter minting.

Each `tokenURI` is Base64 JSON containing a Base64 **512×512 SVG** with a hexagonal crest,
"SEASON N CONQUEROR", the winning colony's name/color, and the owner's shortened address.
Attributes include numeric Season and named Colony. Art has no external URLs or mutable settings.

## After launch

No owner-settable service, oracle, subscription, relayer, token binding or initialization is
required. The launch service supplies actual deployment addresses through the manifest references
above; this source tree contains no guessed application address or private key.

- Separate manifest and review assignments produce and independently inspect `launch.json`.
  After this stage, services publish source, establish policy/signed-artifact linkage, attest,
  admit/deploy the contracts, verify deployed source and supply, provide the deployment handoff,
  and start the frontend. This builder does not generate the manifest or broadcast transactions.
- Players acquire and approve NECTAR, choose a colony, manage troops and claim their own cooldowns
  and badges. The launch owner has no application administration to perform.
- Keepers or any player call `settleEpoch` repeatedly when behind. Settlement earns glory only,
  so continued keeper participation is an operational assumption. A backlog delays displayed
  controllers/scores and badge finalization, but never token withdrawals.
- The frontend consumes [docs/ABI.md](docs/ABI.md) and `docs/abi/*.json`, handles neutral value 4,
  distinguishes live balances from settled controllers/scores, and indexes events for the war log,
  keeper leaderboard and each wallet's badges. Use the exact poolKey from the service handoff.
- An independent adversarial review of custody, history, eligibility, constructor arguments and
  the final manifest remains a release responsibility. Local tests are evidence, not an audit
  or proof of correctness. The immutable applications have no emergency pause or upgrade path.
