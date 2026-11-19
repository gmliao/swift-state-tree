# CI test audit and nightly design

Status: proposal, rev 2. Rev 2 revises V3's premise and the nightly's skip and scoping after review, names the effective-config log lines for V2, and says what the queue figures count. Inventory and verdicts only. No test is removed, skipped or moved by this plan. Each move lands in its own PR after the list is approved.

Follows `Notes/plans/2026-11-19-dev-speed.md` (levers 1–3: #618, #620).

## Question

Which CI work repeats what another job already checks, and which of it can run less often (only in the variant it can affect, nightly, or on merge) without losing the bug class it catches?

**What it buys.** Mostly runner-minutes and queue time, not wall time. A push's wall time is set by one e2e-game leg, and this audit shortens that leg by 0–1.5 min. Runner-minutes are what overlapping runs wait on: when pushes and PR runs overlap, jobs queue for minutes (see "Queue time"). About 19 of a push's ~110 runner-minutes, and one of its 15 jobs, are repeats (see "Estimated savings per push").

## Data

- **Runs.** Green `main` pushes at six commits: 96902b99, de537bb9, f2364ce7, c3e58710, 2cb7818a and 7133736e, both workflows each. All six had a **cold** SwiftPM cache:
  - the first five predate the cache (#618);
  - 7133736e's keys all missed (`Cache not found for input keys: swiftpm-…`), being the first run with the digest in the key.

  No warm `main` run exists yet. One will be added when the next code-touching merge lands. The cache saves 8–16 s a job (#618), so the verdicts don't depend on it.
- **Jobs before 7133736e** ran e2e-game as 2 legs (in-turn sync × both row modes in one leg). From 7133736e on, it runs as 4 legs.
- **Sources.** Job and step times come from the Actions API (`startedAt`/`completedAt`). Per-test times come from Swift Testing's `✔ Test "…" passed after N seconds` lines, and e2e section times from the log timestamps.
- **Per-test times are wall time under parallel execution,** not cost. The same test takes 24–39 s depending on the job: that is contention, not the variant. They rank tests; they are not added up into savings. Savings below are by step and job only.

## Where the time goes

Job medians across the runs above, in minutes, with the range and the run count. Steps under 0.3 min are left out.

| job | median | range | n | main steps |
|---|---:|---|---:|---|
| e2e-game (2-leg layout, each leg ran both row modes) | 17.5–17.9 | 14.9–19.9 | 5 | row on 9.8–10.1, row off 6.7–6.8 |
| e2e-game, 4 legs (7133736e) | 9.3–13.7 | — | 1 each | see below |
| examples | 13.8 | 12.2–15.6 | 6 | GameDemo tests 5.4, deep-research 4.5 (moved by #620), Demo build 2.1 |
| build (sync tables off) | 12.3 | 8.9–12.5 | 6 | build + full `swift test` 11.6 |
| build (in-turn sync false) | 10.7 | 10.1–14.4 | 6 | tests 4.5, build 4.2, must-not-compile 1.1 |
| build (per-player sync tables off) | 10.3 | 7.1–12.1 | 6 | build + Transport/NIO tests 9.7 |
| build (in-turn sync true) | 9.3 | 7.6–11.4 | 6 | tests 3.9, build 3.6, must-not-compile 0.9 |
| e2e-tests | 5.1 | 4.2–5.7 | 6 | DemoServer build 2.2, each encoding 0.4 |
| test-ws-loadtest | 2.5 | 2.5–2.6 | 6 | tests 2.1 |
| test-typescript-sdk, wall-clock-tests, shellcheck | ≤ 1.0 | — | 6 | — |

**One e2e-game leg on 7133736e** (in-turn sync false, row addressing on, 12.5 min), by section:

| section | s |
|---|---:|
| GameServer build (`Build complete! (317.93s)`) | 332 |
| json scenarios + replay proofs + replay stream | 87 |
| jsonOpcode, same set | 84 |
| messagepack, same set + ReevaluationRunner build + replay record verification | 145 |
| graceful shutdown, direct-mode regression | 48 |

The row-off leg is the same, plus the `messagepack (USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false)` section (66 s).

**Per push,** the jobs on 7133736e add up to about 110 runner-minutes. The wall time is the slowest job: an e2e-game leg (13.7) or `examples` (15.6, about 10.9 once #620 moves its 4.7 min out).

## Queue time

The wait from a job's creation to its start (`created_at` to `started_at` in the jobs API), over the 74 jobs of the runs above that started. The 6 skipped jobs are left out, as they never start:

| | s |
|---|---:|
| median | 2 |
| p90 | 280 |
| max | 483 |

The waits are all on the two commits whose runs overlapped other runs on the repository, 2cb7818a and 7133736e (2026-11-19 00:29Z and 00:48Z):
Jobs that waited over 60 s, both workflows together:
- 2cb7818a: 11 jobs, 92–483 s;
- 7133736e: 6 jobs, 74–175 s: all four e2e-game legs and two build legs.

The other four commits had none.

A job waits when the account's concurrent-job limit is reached, so a queued push is delayed by the job-minutes ahead of it, not by its own slowest job. On those two commits the wait (up to 8 min) was larger than anything this audit takes off the wall time. Fewer job-minutes per push, and one fewer job (V2), shorten that wait whenever runs overlap. The wait will be measured again after V1 and V2.

## The variant axes and what can read them

| axis | where it is read | what it can reach |
|---|---|---|
| `IN_TURN_SYNC` (build × 2, e2e-game × 2) | `Sources/SwiftStateTree/Runtime/InTurnSync.swift:45` (core) | core, Transport and NIO tests. Not Macros (compile time) nor DeterministicMath (doesn't depend on the runtime). |
| `USE_SYNC_TABLES`, `TYPED_LEAF_VALUES` (sync-tables-off) | `Sources/SwiftStateTreeTransport/TransportEnvConfig.swift:105,112` | **Tests that build an adapter or a land server without an explicit `transportEnvConfig:`**, in whatever test target they are. Mostly Transport and NIO. But `SwiftStateTreeTests` depends on `SwiftStateTreeTransport` too (`Package.swift`, its `testTarget`), and 10 of its files import it. One of them builds an adapter that reads the environment: `DebugProjectionWireShapeTests`, which runs the snapshot-diff fallback in sync-tables-off and nowhere else. The other three core files that build an adapter pass `transportEnvConfig:` (`AtomicPatternIndexAdapterTests`, `ReevaluationMonitorFrameIdentityTests`, `SyncTablesLandCellTests`). Macros (33 `@Test`s) and DeterministicMath (145) can't reach an adapter. |
| `PER_PLAYER_SYNC_TABLES` (per-player-sync-tables-off) | `TransportEnvConfig.swift:82` | Transport and NIO. The job already filters to them. |
| `ROW_ADDRESSING` (e2e-game × 2) | `TransportAdapter.swift:1261`: `rowAddressing = rowAddressingRequested && inTurnSyncEnabled && joinsThroughRouter`; `TransportEncodingConfig.swift:139`: needs an opcode state-update encoding | **Only with in-turn sync on, and only for jsonOpcode and messagepack.** With in-turn sync off, or with json, row addressing is off whatever `ROW_ADDRESSING` says. |
| `TRANSPORT_ENCODING` (e2e-tests × 3, e2e-game × 3 per leg) | the codecs | everything on the wire. |

## Verdicts

Verdicts: **push** (every push and PR, as today), **variant** (only in the variant it can be affected by), **nightly**, or **merge** (push to `main` only). Each "less" verdict names what still catches the same bug class. Savings are runner-minutes per push, from the medians above. The wall-time effect is given where the job is on the critical path.

### V1. e2e-game, row-off legs: drop json (variant)

- **Today:** both row-off legs run json, jsonOpcode and messagepack.
- **Why less:** json has no opcode state-update encoding, so row addressing is never in effect for it (`TransportEncodingConfig.swift:139`). The json run in a row-off leg is the json run of the row-on leg with the same in-turn mode.
- **Still caught by:** that row-on leg's json run.
- **How:** `E2E_ENCODINGS: "jsonOpcode messagepack"` in the row-off step. The script already supports narrowing (`Tools/CLI/test-e2e-game.sh:381`).
- **Saves:** about 1.5 min on each of 2 legs, 3 runner-min. It also cuts about 1.5 min of wall time when a row-off leg is the slowest, as on 7133736e.

### V2. e2e-game, leg (in-turn sync false, row addressing off): fold into (false, on) (variant)

- **Today:** a full leg, the slowest on 7133736e (13.7 min).
- **Why less:** with in-turn sync off, `ROW_ADDRESSING=false` changes nothing (`TransportAdapter.swift:1261`). Its jsonOpcode and messagepack runs repeat the (false, on) leg's. The only thing it adds is the `USE_SYNC_TABLES=false` messagepack section, which the script runs only when `ROW_ADDRESSING=false` (`test-e2e-game.sh:437–486`).
- **Still caught by:** the (false, on) leg for every scenario. That section moves into the (false, on) leg, with `ROW_ADDRESSING=false` set for that section only.
- **Precondition, in the same PR:** show that the two legs' lands run the same effective config on one commit.
  - GameServer's own `📦 Transport encoding configured` line (`Examples/GameDemo/Sources/GameServer/main.swift:95`) logs the *requested* `rowAddressing`, so it differs between the legs by design and proves nothing.
  - The evidence is the adapter's per-land `Transport encoding configured` line (`Sources/SwiftStateTreeTransport/TransportAdapter.swift:1416–1428`): it must show `rowAddressing: off` and the same other fields in both legs.
  - The (false, on) leg also logs `Row addressing requested but not in effect` (`:1447`), and the (false, off) leg doesn't.
- **Saves:** about 13 runner-min. The (false, on) leg grows by about 1.1 min. On wall time, the e2e-game maximum would come down to the (false, on) leg plus 1.1 min. Leg times vary by 3–4 min between identical legs (9.3 against 12.5 on one run), so the wall-time gain can't be read from one run. It will be measured on the PR.

### V3. sync-tables-off: only the tests that can read the flags (variant)

- **Today:** the full `swift test`.
- **Why less:** the flags reach only tests that build an adapter or a land server without an explicit `transportEnvConfig:` (see the axes table). That is most of Transport and NIO, plus `DebugProjectionWireShapeTests` in core. The rest of core, Macros and DeterministicMath run the same code with the flags on or off.
- **Still caught by:** the same core, Macros and DeterministicMath tests in both build legs.
- **How:** two options for the PR to choose between.
  - (a) Filter to Transport, NIO and the core suites that read the flags: today `SwiftStateTreeTests.DebugProjectionWireShapeTests`.
  - (b) Give `DebugProjectionWireShapeTests` an explicit tables-off case, so it covers the fallback in every job, and filter to Transport and NIO, like the per-player job (`--filter 'SwiftStateTreeTransportTests\.|SwiftStateTreeNIOTests\.'`).

  (b) is preferred: a filter that lists core suites silently drops the next core test that builds an adapter from the environment.
- **Either way, the PR adds a check** that lists every `TransportAdapter(` and land-server construction in `Tests/SwiftStateTreeTests` without `transportEnvConfig:`. It fails if one is outside the filter, for (a), or exists at all, for (b).
- **Saves:** about 2 runner-min, an estimate. The per-player job builds the same and runs only Transport and NIO, in 9.7 against 11.6 min. Under (a), less whatever the added core suites take. It's off the critical path.

### V4. Must-not-compile snippets and Lint lessons: one build leg (variant)

- **Why less:** both are compile-time or text checks; `IN_TURN_SYNC` is a runtime environment value.
- **Still caught by:** the same steps in build (in-turn sync true).
- **Saves:** about 1 runner-min. It's off the critical path.

### V5. Macros and DeterministicMath tests: one build leg (variant)

- **Why less:** neither module can read `IN_TURN_SYNC`.
- **Still caught by:** the same tests in build (in-turn sync true).
- **How:** `--skip 'SwiftStateTreeMacrosTests\.|SwiftStateTreeDeterministicMathTests\.'` in the in-turn-false leg. Once #608 merges, its test targets (`SwiftStateTurnsTests`, `SwiftStateTurnsMacrosTests`) get the same check: whether they can read `IN_TURN_SYNC`.
- **Saves:** under 0.5 runner-min (178 short tests). Listed for completeness. Recommend doing it only together with V4, in one PR.

### V6. The slowest tests: no per-test moves (push)

The slowest tests by total time across the variant jobs, in seconds, with each job's median. That is the top 30 names in the logs: two are one test, renamed, so 29 tests.

| total s | in-turn true / false / tables off / per-player off | test (file) | verdict |
|---:|---|---|---|
| 130 + 72 | 36 / 31 / 39 / 24, then 16 / 19 / 30 / 6 | JSON nested up to the limit reaches the payload decode… (`ClientFrameDepthTests`). Named "Nesting up to the JSON parsers' limit…" until c3e58710 (#605), which also bounded nesting at 32 and made it faster. | push |
| 94 | 25 / 29 / 40 / – | Replaying a tickless frame of many one-input passes… (`TicklessReplayPassTests`, core) | push; out of tables-off by V3 |
| 89 | 24 / 27 / 38 / – | Random mutations: the typed per-player diff equals today's one-pass extraction (`SyncTablePerPlayerDiffTests`, core) | push; out of tables-off by V3 |
| 88 | 24 / 27 / 38 / – | Random mutations: the typed per-player diff equals today's separate extraction… (same file) | push; out of tables-off by V3 |
| 74 | 19 / 25 / 30 / – | The nested-policy land (`SyncTablesLandCellTests`, core) | push; out of tables-off by V3 |
| 71 | 19 / 22 / 29 / – | The reevaluation monitor (`MonitorTicketTests`, NIO) | push |
| 70 | 18 / 23 / 28 / – | The shape matrix land (`SyncTablesLandCellTests`, core) | push; out of tables-off by V3 |
| 64 | 17 / 19 / 28 / – | Random mutations: the typed diff equals today's… (`SyncTableDiffTests`, core) | push; out of tables-off by V3 |
| 63 | 15 / 16 / 24 / 8 | A disabled bound never withholds a read (`WebSocketSessionHandlerInboundBacklogTests`) | push |
| 63 | 14 / 18 / 22 / 7 | Dirty tracking stays as configured through many syncs… (`TransportRemovedEnvKeysTests`) | push |
| 62 | 14 / 18 / 23 / 8 | The same script sends the same frames with the tables on and off… (`SyncTablesByteIdentityTests`) | push; candidate (see below) |
| 55 | 15 / 16 / 24 / – | maxPlayers 1: two concurrent joins with no holds installed admit exactly one (`HoldPointsIsolationTests`, core) | push; out of tables-off by V3 |
| 55 | 13 / 14 / 21 / 7 | A total failure ends the land in every configuration (#535) (`PerPlayerSyncTablesScenarioTests`) | push; candidate |
| 54 | 12 / 16 / 19 / 7 | Switching dirty tracking at run time sends the same frames… (`SyncTablesByteIdentityTests`) | push; candidate |
| 51 | 14 / 14 / 22 / – | Verify deterministic replay consistency with async resolvers… (`AsyncResolverConsistencyTests`, core) | push; out of tables-off by V3 |
| 51 | 14 / 15 / 22 / – | Random mutations of the shape matrix… (`SyncTableDiffTests`, core) | push; out of tables-off by V3 |
| 50 | 16 / – / 26 / 8 | A pending join and 300 frames: the adapter's bound closes it… (`WebSocketSessionHandlerInboundBacklogTests`) | push |
| 49 | 11 / 13 / 18 / 6 | Broadcast-only syncs, joins, leaves and supersedes (`PerPlayerSyncTablesScenarioTests`) | push; candidate |
| 48 | 12 / 12 / 17 / 8 | delta and full-snapshot rebuild identical client views after every sync (`SyncStrategyEquivalenceTests`) | push |
| 47 | 11 / 12 / 18 / 6 | Sends from another thread during the handler's removal… (`WebSocketSessionHandlerLoopTests`) | push |
| 42 | 10 / 10 / 16 / 6 | 1, 2: syncNow followed by syncBroadcastOnly… (`TransportAdapterOrderedSendTests`) | push |
| 40 | 8 / 10 / 13 / 9 | T5: mutations of the fixture payloads reach their field decoders (`ClientFrameFuzzTests`) | push |
| 39 | 9 / 10 / 14 / 5 | The same script sends the same frames with dirty tracking on and off (`DirtyTrackingByteIdentityTests`) | push |
| 38 | 9 / 10 / 14 / 5 | A resync re-seeds the reader's per-player boxes (`PerPlayerSyncTablesScenarioTests`) | push; candidate |
| 38 | 9 / 9 / 15 / 5 | While frozen, syncNow, syncBroadcastOnly and a leave's sync send nothing… (`TransportAdapterDebugFreezeTests`) | push |
| 34 | 8 / 8 / 13 / 5 | mixed paths (json): state frames, immediate events and action responses arrive in issue order (`TransportAdapterOrderedSendTests`) | push |
| 34 | 8 / 8 / 13 / 5 | 3: the client copy built from received patches equals the server projection (`TransportAdapterOrderedSendTests`) | push |
| 34 | 8 / 8 / 13 / 5 | Settle waits for a sync cycle already in flight, then runs its own (`TransportAdapterDebugFreezeTests`) | push |
| 48 | 11 / 14 / 17 / 6 | The report (`RowEntryTests`) | push |

**Why no per-test moves:**
- The build legs' test steps are 3.9–4.5 min, run in parallel. A slow test sets the step's tail only when it ends last, so moving one test saves an unknown and probably small amount.
- A skip list by test name breaks silently when a name changes.

**Candidates** are tests that set the tables or typed-leaf flags in their own config: `SyncTablesByteIdentityTests` and `PerPlayerSyncTablesScenarioTests`. If they build their config without reading the environment, their runs in the tables-off and per-player-off jobs repeat the build legs'. A follow-up can check that and move them by file or tag, not by name. No minutes are claimed for it here.

`SyncTablesByteIdentityTests` can't move as a whole in any case. It holds the pinned tests that the variant jobs grep their logs for: the per-player job greps `✔ Test "<pin>"`, so that a filter typo can't pass with nothing run. Those pins stay in every job that greps for them.

### V7. Kept as they are (push)

- **e2e-tests, three encodings:** 0.4 min each on a 5.1-min job. The DemoServer build (2.2) is shared. Cutting an encoding saves under a minute and loses a codec on the real wire.
- **e2e scenarios against unit tests:** every e2e scenario decodes through the TypeScript SDK over a real WebSocket. The Swift unit tests that check frames and convergence (`SyncStrategyEquivalenceTests`, the byte-identity tests, `TransportAdapterOrderedSendTests`) stay in-process with the Swift decoder. The two overlap in what they assert, but not in the decoder or the transport, so neither replaces the other.
  - The scenario sets are game (12), cookie (5), fault (2), visibility, resolver, load and counter.
- **GameDemo tests (5.4 min), Demo build and tests, ws-loadtest, TypeScript SDK, deep-research (after #620):** none runs under a variant, and none repeats another job.
- **in-turn sync false as a whole (build leg and e2e-game):** the legacy tick path ships and still changes (#522). Moving it nightly would let a break merge and surface a day later. Kept on every push. Revisit when the legacy path is removed.

### Nothing proposed for nightly or merge-only yet

No entry above is a nightly or merge-only verdict.
- Each repeated run is already covered by another job on the same push, so V1–V5 drop it from that push rather than delaying it.
- The tests that don't repeat aren't safe to delay.

The nightly below still runs the **full pre-audit matrix**, so whatever V1–V5 drop from push runs is still exercised once a day on `main`.

## Estimated savings per push

| verdict | runner-min | wall time |
|---|---:|---|
| V1 | ~3 | up to ~1.5 when a row-off leg is the slowest |
| V2 | ~13 | e2e-game max becomes the (false, on) leg + ~1.1; to be measured on the PR |
| V3 | ~2 (estimate) | none (off the critical path) |
| V4 + V5 | ~1.5 | none |
| **total** | **~19 of ~110 (≈17%), and 1 of 15 jobs** | **0–1.5 min** |

**The audit mostly saves runner-minutes and queue time, not wall time.** The queue time saved depends on how many runs overlap, so it isn't estimated here. It is measured after V1 and V2 (see "Queue time"). The wall time is set by one e2e-game leg: a 5.5-min GameServer build, then about 5.5 min of scenarios across three encodings. Cutting that needs a different lever, not a removal. Two options are noted for the dev-speed plan, not proposed here:
- one leg per encoding (more runner-minutes, about 8 min of wall time);
- build GameServer once and share the product across legs.

## Nightly workflow

`.github/workflows/nightly.yml`:

- **Triggers:**
  - `schedule` (one run a day, 19:00 UTC);
  - `workflow_dispatch` (no inputs);
  - `push` of tags `measurements-*`.

  To test a branch or tag by hand: `gh workflow run nightly.yml --ref <branch-or-tag>`. The run then checks out that ref, and its `headSha` is that ref's commit. A `ref` input is avoided on purpose: every `actions/checkout`, the `fetch-depth: 0` ones included, would have to pass it through `workflow_call`, and a dispatch run's `headSha` would still be `main`'s.
- **Concurrency:** `group: nightly-${{ github.ref }}`, `cancel-in-progress: false`. Two runs on the same ref queue instead of racing on the report.
- **Gate job, on `schedule` only.** It looks up the last successful **scheduled** run, `gh run list --workflow nightly.yml --event schedule --status success --limit 1 --json headSha`. When that `headSha` equals the commit under test, it skips the rest.
  - Only scheduled runs count. A dispatch or tag run on another ref can't make the next scheduled run skip `main`'s HEAD.
  - A scheduled run's `headSha` is `main`'s HEAD when it started, which is the commit it tested.
  - Dispatch and tag runs always run.
- **Test jobs.** The full pre-audit matrix, via `workflow_call` of the two existing workflows with inputs that restore what V1–V5 drop:
  - all three encodings in the row-off legs;
  - the separate (false, off) leg;
  - the full `swift test` in sync-tables-off;
  - both build legs' checks.

  One definition serves both, so the nightly can't drift from the push runs. That needs `workflow_call` added to both workflows, in the PR that adds the nightly.
- **Report job, on `schedule` only** (`if: always() && github.event_name == 'schedule'`, `permissions: issues: write`):
  - **On failure:** it finds the open issue labeled `nightly-failure`, or opens one (title `Nightly failing on main`, with a milestone and the type and priority labels). It comments with:
    - the run URL;
    - the failed jobs;
    - the commits since the last green scheduled run (`git log --oneline <last-green>..<sha>`, from a `fetch-depth: 0` checkout).

    One issue at a time; a second failure comments on the same issue.
  - **On success with that issue open:** it comments `green at <sha>` and closes it.
  - **Dispatch and tag runs never file or close the issue.** Their result is their own run's status, and a tag run's job summary names the tag.
- **Before a measurement tag.** Pushing a `measurements-*` tag runs the nightly on the tagged commit. The rule for whoever tags: tag only a commit whose push runs are green, and check the tag's nightly run before using its numbers.
- **Limits:**
  - GitHub runs `schedule` only on the default branch;
  - it disables scheduled workflows in a public repository after 60 days without activity;
  - the report job needs `issues: write`, which the push workflows don't have.

## Order, after approval

1. **V1, then V2,** each in its own PR. V2 includes the effective-config check, and both PRs measure the legs on their runs.
2. **V3, then V4 + V5,** one PR each.
3. **The nightly**, with `workflow_call` added to both workflows. It must land before V1–V5 take effect on `main`, or in the same PR as the first of them, so nothing dropped from push runs goes unrun.

Each PR states its verdict's "still caught by" line and shows the remaining run passing.
