# Experiment: per-player visibility under movement

Status: open. Rev 2 after Review's design check (filter cost in the tick, exact consistency check, recorder hook, ticks per sync fixed), design only (no runs).

## Question

When each player receives only the entities within its view, and entities enter and leave that view every tick:

1. Is every recipient's reconstructed state equal to its server projection at every sync?
2. Does re-evaluation of the record reproduce every per-player sync output?
3. How many bytes does each recipient receive per sync, against a control that sends every entity to every player, and what does visibility cost the server per room: computing it in the tick, and the per-player output in the sync?

Each answer is a table over view size, entity count, viewers per room and ticks per sync.

Offline, viewers never move: churn comes only from entity motion. Viewer motion (`MoveViewer`) appears only in the live check (D6).

## What exists (main 490c7c14)

- **The land.** `VisibilityTestLand` (`Examples/GameDemo/Sources/GameContent/VisibilityTestLand.swift`) has 40 moving entities that bounce in a 100 × 100 arena. A viewer sees an entity within `viewRadius` (15) of it. `entities` is `@Sync(.perPlayer)`, filtered by each entity's server-only `visibleTo`. Viewers take one of four fixed slots. The broadcast counters `viewEntries` and `viewExits` count (entity, viewer) transitions. `MoveViewerEvent` moves a viewer, and `PlaceEntityAction` / `ParkEntitiesAction` place entities by hand.
- **Where visibility is computed.** In the land's rules, not in the sync: the Tick, OnJoin, OnLeave and `MoveViewer` call `updateVisibility`, which tests every (entity, viewer) pair with `Position2.isWithinDistance` (quantized Int64, `distSq <= thresholdSq`) and writes each entity's server-only `visibleTo`. The sync-time filter is only `visibleTo.contains`.
- **Benchmark runner.** `EncodingBenchmark --game-type visibility-test` runs the land through the generic multi-room runner (`runMultiRoomBenchmarkLand`). That runner reports bytes and sync time, but doesn't time the ticks (`stepTickOnce`) or write view captures: `--capture-views` is refused for any game type but hero-defense (`BenchmarkConfig.swift` ~397).
- **The gate.** `ws-loadtest verify-views` decodes each recipient's captured frames with the SDK and compares them with that recipient's captured projection after every sync. `time-decode` times the same streams. Neither depends on hero-defense, apart from the baselines' decoders.
- **E2E.** `Tools/CLI/test-e2e-game.sh` runs `scenarios/visibility-test/` with three clients in each encoding, and a re-evaluation record and verify of `test-visibility-edges.json` (`reevaluation-e2e-game.ts`).
- **Re-evaluation.** `ReevaluationRunner --input <record> --verify` knows both test lands. It compares every recorded sync output scope (broadcast, per-player, seed) with the replay's.
- **Load.** `ws-loadtest` has `scenarios/visibility-test/` (default and smoke). Its phases' `verify` flag is parsed, but no state check runs under load.

## Design

### D1. Capture the generic runner (Examples change, first)

`runMultiRoomBenchmarkLand` writes the same capture as the hero-defense runner: a header (format, schema, sessions, cell, git, environment) and, per sync, the frames sent to each session plus each player's projection. The projection is `SyncEngine().snapshot(for:from:mode: .all)` on the state the sync used, and it is side-effect free. `--capture-views` is then allowed for `visibility-test`. Card game stays refused until something needs it.

*Rejected:* a separate capture tool for this land. The gate, `time-decode`, `projhash.py` and the run-directory layout would be duplicated, and that is the part that already has mutation checks.

### D2. Knobs (Examples change)

The land's layout constants become environment keys in a `VisibilityTestEnvKeys` enum, read with `EnvHelpers`. Defaults stay as they are, so E2E and the scenarios don't change:

- `VISIBILITY_TEST_ENTITY_COUNT` (40);
- `VISIBILITY_TEST_VIEW_RADIUS` (15);
- `VISIBILITY_TEST_FILTER`: `radius` (default) or `all`. `all` is the control: the same `perPlayer` policy whose filter returns every entity. Under `all` the land still runs `updateVisibility` everywhere it does under `radius`, so state, counters (`viewEntries`, `viewExits`, `visibleTo`) and tick work are identical, and only the per-player output differs.

The viewer slots extend to a deterministic grid, so 16 viewers per room don't stack four per slot. Each knob value goes into the capture header's `environment` and the results' `params`.

*Why the control keeps the per-player path.* With an identity filter the sync path, schema and path table stay the same, so the byte difference is only what filtering removes. A `@Sync(.broadcast)` variant would also change the path (one shared diff instead of one per player) and the schema, which mixes two effects. One broadcast cell at the default point (radius 15, 40 entities, 4 viewers) reports bytes only, so a reader sees how close the identity control is to what a developer would ship without filtering. The broadcast variant's CPU question stays under Extensions.

### D3. Matrix

All cells: release build, serial, delta sync, `messagepack-pathhash`, motion on, server events off.

**Ticks per sync is a matrix constant: 1.** The land declares no `StateSync`, and a keeper without one syncs at its tick interval (`LandKeeper.performInitialization`, the fallback with its warning). So the live server syncs this land once per 50 ms tick, which matches the benchmark's default for this land. Every cell records `ticksPerSync` in the capture header and the results' `params`, and `regenerate.py` refuses a cell whose value differs from the table's. Churn per sync, the stated driver of the savings, scales with it, so the matrix has a ticks-per-sync axis at its default point: 1 (live) and 2 (one sync per 100 ms, hero-defense's cadence, which a developer adding `StateSync` would likely pick).

| Axis | Values | Fixed elsewhere |
|---|---|---|
| view radius | 8, 15, 30 | 40 entities, 4 viewers |
| entity count | 40, 160, 640 | radius 15, 4 viewers |
| viewers per room | 4, 16 | radius 15, 40 entities |
| ticks per sync | 1, 2 | radius 15, 40 entities, 4 viewers; every other cell at 1 |
| filter | radius, all | each cell above runs both; plus one broadcast cell (bytes only) at the default point |

Rooms: 10 per cell for bytes and server time, with the first 2 captured for the gate. Iterations: as the entity-delta topic uses. One run per cell gives the bytes (they are deterministic). Server time takes the median of three repeats.

### D4. Metrics

Metric semantics (one unit of each):

- `bytes_per_recipient_sync`: the bytes of every frame one recipient receives in one sync, summed over recipients and divided by recipients × syncs. A frame sent to `*` counts once per recipient. Raw, and per-recipient raw deflate as `roomBytes` defines it (`ws` defaults, Z_SYNC_FLUSH per message, checkpoint 0 compressed and not counted).
- `visible_per_recipient`: entities in one recipient's projection, the mean over recipients and syncs.
- `view_changes_per_recipient_sync`: (`viewEntries` + `viewExits`) increments over the run, divided by recipients × syncs. It says how much churn each cell has.
- `sync_us_per_room_sync`: the server's sync time per room and sync, as `collect.py` defines it for the entity-delta topic. It holds the per-player diff, encode and `visibleTo.contains`, but not the computation of visibility.
- `tick_us_per_room_tick`: the time of the runner's `stepTickOnce` calls, summed and divided by rooms × ticks. It holds `updateVisibility` (O(entities × viewers)) together with the motion. The runner gains this timer (Examples change), next to its sync timer and with the same clock. `radius` and `all` run the same tick, so the two should match within noise: a difference means the control didn't keep the tick identical.
- The tables report sync and tick separately, never summed.
- `gate_passed`, `gate_comparisons`: from `verify-views` over the captured rooms. A decode error fails the gate.
- `replay_verdict`: `ReevaluationRunner --verify` over the record of each captured room (passed, or the first mismatching scope and tick).
- `client_decode_us_per_frame`: `time-decode` over the captured streams, reported with the caveat of #303 (the SDK's apply cost, and what each decoder produces).

The table's main comparison is `bytes_per_recipient_sync` for `radius` against `all`, next to `visible_per_recipient` and `view_changes_per_recipient_sync`. An entering entity is sent whole and a leaving one as a remove, so the savings should depend on churn, not only on the visible fraction. The table shows both.

### D5. Re-evaluation in the benchmark

The benchmark gets a recorder option (Examples change): `--record-dir` records each captured room with the land's re-evaluation recorder, and `ReevaluationRunner --verify` runs on those records. `replay_verdict` then covers the measured rooms and their schedule (the runner's ticks per sync).

*Rejected:* a twin record from `ReevaluationRunner --record`. Its sync cadence can differ from the benchmark's ticks per sync, so the replay would verify a different schedule. It would be acceptable only with a proof that it is the same run (its per-player projection hashes equal the measured capture's, sync by sync). The hook is less work than that proof.

### D6. Live check (one cell, after the offline matrix)

`ws-loadtest scenarios/visibility-test/default.json` with radius 15 and 40 entities, against a GameServer with `ENABLE_REEVALUATION=true`, followed by `ReevaluationRunner --verify` on a sample of the rooms' records. This shows that the offline result holds through real sockets, with a viewer that moves (`MoveViewer` at 2/s). It adds no bytes table: socket bytes there include the transport's framing, and the offline cells already answer question 3.

## Gates (a cell is refused if any fails)

- `verify-views`: zero differences and zero decode errors in every captured room.
- `replay_verdict` passed in every captured room.
- **Consistency of `radius` and `all`.** `collect.py` checks, for each captured room, recipient and sync:
  - The visible set: the `radius` projection's entity ids equal the `all` projection's entities that the land's rule admits. That rule is recomputed as the land computes it: quantized integer positions from the wire, `distSq <= thresholdSq` in 64-bit integers (inclusive), with `thresholdSq` from the quantized radius, viewer positions from the broadcast `viewers`, and entity positions from the `all` projection at the same sync.
  - The values: each visible entity's fields in the `radius` projection equal the `all` projection's. This shows the two runs share the same motion, which the set check depends on.
  - Unit tests on hand-built pairs: an entity exactly at the radius (included), one a quantum past it (excluded), and a pair whose positions differ (the value check fails).
  - It isn't run in D6: the live run has no `all` twin to compare against. (`MoveViewer` recomputes visibility in its own handler, so a moving viewer doesn't make `visibleTo` stale.)
- Release build, clean tree, recorded `swift --version` (as `regenerate.py --check` already refuses for the entity-delta topic).

Mutation checks before the first run:

1. A filter that leaks one out-of-view entity to one recipient. The gate stays green, because the projection leaks the same way, but the `radius`/`all` consistency check must fail.
2. A capture that drops one remove frame. The gate must fail.
3. A replay with one `visibleTo` computed differently. `replay_verdict` must fail on the per-player scope.

## Where it lands

- D1 and D2: Examples changes on main, verified with `./Tools/CLI/test-e2e-game.sh`, since the land is in its scenarios.
- A topic `deep-research/visibility/` with `run.sh`, `collect.py`, `regenerate.py`, tests and README, built like `entity-delta-baseline`.
- No `Sources/` change is expected. If D5 needs a recorder hook in the benchmark, it's in Examples.

## Out of scope

- Area-of-interest strategies other than a radius (grid cells, hysteresis). The land has one rule. The question is what the framework does with a filter, not which filter is best.
- The entity-delta and Colyseus baselines. Both are written for hero-defense's shape, and per-player filtering would need a filtered-view model for each, which is another design.
- Network impairment: that experiment has its own plan.

## Extensions

- A `@Sync(.broadcast)` variant of the land, for the server CPU of per-player diffing against one shared diff.
- More viewer slots (64) once the 16-viewer cells are in.

## Open questions for Review

1. (Settled in rev 2: the identity filter, plus one broadcast cell for bytes.)
2. (Settled in rev 2: the recorder hook, D5.)
