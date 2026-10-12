# Local validation record

Validated on 2026-10-12 with Foundry 1.8.5 and the pinned Solidity 0.8.26 compiler.
Configuration: optimizer enabled, 200 runs, Cancun, metadata bytecode hash disabled.

| Check | Result |
| --- | --- |
| `forge build` | Passed. No Solidity compiler errors or warnings. |
| `forge test -vv` | **64 passed, 0 failed, 0 skipped**, across 7 suites; approximately 230 seconds. |
| Stateful invariants | Three invariant properties passed together over **128 runs / 8,192 calls / 0 reverts**. |
| Independent eager reference model | **128 randomized scenarios** passed, comparing lazy historical settlement and eligibility over two complete seasons. |
| Token and deploy/move/retreat fuzz tests | 256 inputs each passed. |
| `forge fmt --check` | Passed. |
| `python3 scripts/export_abis.py --check` | All three exported ABIs matched the built artifacts. |
| `sha256sum --check docs/dependencies.sha256` | All 56 vendored source/license files matched. |
| Local launch compatibility checks | Factory supply preserved, constructors succeed with dependency addresses that have no code, and first use rejects missing dependency code. |
| Local runtime scan | All production runtimes present, within EIP-170, without DELEGATECALL, CALLCODE or SELFDESTRUCT, scanning past PUSH immediates. |
| Creation bytecode linking | Empty library link references for all three production contracts. |

## Runtime sizes

| Contract | Runtime bytes | EIP-170 limit |
| --- | ---: | ---: |
| LaunchToken | 1,722 | 24,576 |
| HiveWars | 12,660 | 24,576 |
| ConquerorBadge | 8,191 | 24,576 |

## Tested risks and boundaries

- Exact map ring counts, unique axial coordinates, points, and all 61 cells populated by four colonies.
- Pending activation at boundaries, immediate active removal, mixed pending/active moves and retreats.
- Neutral ties, incumbent ties, tied challengers, outright captures, score ties broken by the Core,
  neutral-Core draws and a Core holder outside the highest-score tie.
- Only-ended and exactly-once sequential settlement, keeper counters, season score reset,
  three-season settlement backlog with colony changes, and exact season-boundary mutations.
- Single-choice season locks, inherited-colony confirmation, failed-action rollback,
  atomic migration of all 61 positions, preserved prior-season eligibility and limited current-season credit.
- Separate cooldown deadlines, exact 24-hour maturity, no delayed older entries, coalescing,
  64-entry bounded claims, duplicate claims, unauthorized withdrawals and token payout failure/retry.
- 1,000-token threshold including one wei below it, seven completed epochs, partial/nonconsecutive
  epochs, aggregation across territories, winning-colony membership and long-idle lazy accounting.
- Failed, false-return, short-transfer and no-return ERC20 behavior; attempts to reenter every game
  mutator during deposit and to double-claim during payout. The production token is the immutable
  standard LaunchToken, not the adversarial test tokens.
- Badge finalization gating, duplicate claims, multiple seasons and players, rejection of every
  transfer/approval route, nonexistent tokens, safe-mint callback failure/retry and reentrant mint.
- Independent decoding and parsing of Base64 JSON and SVG, all four palettes, season labels,
  short wallet addresses, 512×512 dimensions, traits, ERC165/721/5192 discovery and immutable art.
- Exact contract liabilities and each player's entitlement under randomized activity, matching
  every territory's colony balances to its players and matching global accounting to actual token custody.

## Build lint observations

Foundry also emits heuristic lint notices. Their sites were reviewed locally: the timestamp
modulo is a countdown, not a randomness source; timestamp comparisons implement the specified
24-hour cooldown; exact received-amount equality rejects altered deposits; coordinate casts have
radius/step bounds of 4; Solidity initializes numeric locals to zero; validation in bounded map
loops rejects no valid map ID; badge events follow a safe mint protected by the reentrancy guard.
These notices are not hidden by build configuration.

## Scope of this evidence

The test suites do not read or set environment variables, access filesystem cheatcodes, use FFI,
use forked networks, broadcast transactions or hold wallet keys. All dependencies are local.
Test mocks and fixture addresses live only under `test/`; they are not deployment parameters.
The original protected harness was read as a specification; it is not copied into the delivered
suite or represented as an independently executed attestation.

No Slither/Mythril run, independent adversarial audit, deployment, explorer verification, signed
artifact attestation, admission decision or manifest review is claimed. Separate reviewers must
check the accepted source and actual manifest arguments before release. Service policy and
signed-artifact linkage are service responsibilities. The builder's checks are reproducible local
evidence only, and immutable custody contracts still require independent review.
