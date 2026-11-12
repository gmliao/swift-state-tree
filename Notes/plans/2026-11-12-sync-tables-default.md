# Sync tables by default, and the auto dirty switch removed (step 2, PR 4)

Status: open (rev 3, for review; rev 2's review addressed: one must-fix, seven shoulds, three nits). PR 4 of [Flat storage step 2](2026-11-10-flat-storage-step2.md) (§7). The maintainer decided on 2026-11-12 both what flips with the tables (section 2) and what happens to the auto switch's public API (section 4).

**Prerequisite: #513** (`TYPED_LEAF_VALUES`) merges first. Section 1's base and line numbers are re-pinned to `main` after it merges, before the PR starts.

## 0. Scope

- The broadcast diff runs on the typed sync tables by default, for every adapter on the delta strategy.
- The auto dirty-tracking switch and the change-object metric that feeds it are removed.
- Today's snapshot diff stays reachable as an explicit opt-out (`USE_SYNC_TABLES=false`). It is documented as a fallback to be removed later, with no date.
- **The opt-out and row addressing.** `USE_SYNC_TABLES=false` is not an opt-out while row addressing is in effect: row addressing turns the tables on by itself (`(useSyncTables || rowAddressing) && .delta`, `TransportAdapter.swift:1310`). Until F, row addressing is off by default, so the opt-out is complete. F's plan must define the full opt-out (row addressing off as well).
- **Not in this plan:**
  - Row addressing's default (its plan's PR F). It changes the wire and requires clients to declare the feature. F follows as a separate PR right after this one:
    - the server default on;
    - ws-loadtest declaring the feature by default, with an opt-out flag for comparability;
    - its gate is this PR's plus decoded client state equal to the old format's;
    - its plan defines the full opt-out, with row addressing off as well.
  - Per-player fields on the tables (#514).
  - Any later flattening step. Flattening ends with this PR and #514.
- **Lessons consulted:**
  - `Notes/solutions/2026-11-12-an-equality-trace-misses-a-key-bug-when-keys-collide.md`: removing the metric removes its oracle with it.
  - The #517 note: a non-sync delta of a few percent needs an instructions check before it is attributed.
  - `Notes/solutions/2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md`: the drain used for measurements.

## 1. What exists today (main at `50e76feb`)

**The tables switch.**
- `TransportEnvConfig.useSyncTables` is `package` and reads `USE_SYNC_TABLES` once per process (`TransportEnvConfig.swift:64`, `:104`). It defaults to off. The Diagnostics SPI `syncTablesEnabled` exposes it.
- The adapter turns the tables on at init when `(useSyncTables || rowAddressing) && syncStrategy == .delta` (`TransportAdapter.swift:1315`). The choice is fixed for the adapter's lifetime: nothing turns the tables off at run time.
- With the tables on, the adapter:
  - builds `SyncTableBroadcastDiff` (`:1361`);
  - retires the broadcast snapshot cache (`syncEngine.broadcastCacheRetired`);
  - logs once per state type, as a warning, the fields that take the snapshot fallback (`:1369`).

**What the tables can't express** is decided per field at registration, never per land. A field takes the `fallback` kind, which is today's snapshot diff for that field, when its value:
- isn't `Equatable`;
- is or holds a reference type;
- holds a state node outside the walked shapes;
- is a node type with player-dependent fields, with no typed field description, that is a class, or that is declared atomic (an atomic node type falls back whatever its layout).

The reasons come from `SyncTables.swift:68-73` and `:186-201`. A nested node type with no field description is reported through its parent field's reason. A state with no typed field description (a hand-written `StateNodeProtocol` without the macro) runs entirely on the fallback, with the reason "has no typed field description". No land is refused, and no field falls back silently:
- `syncTableFallbackFields(of:)` lists every such field, recursively;
- the adapter logs that list once per state type per process (`SyncTableFallbackLog`).

**The one decision at run time** comes with #513's typed leaves, and only with them on. A field registered with the standard conversion is checked on its first changed value. If its `convert` throws or writes something other than the leaf form, the field drops the leaf form for good. That is logged through `reportRelease`. The field keeps the tables and takes today's per-value diff. This is separate from the static fallback list.

**The auto dirty switch** is `maybeAutoSwitchDirtyTracking` (`TransportAdapter.swift:5863`).
- The change-object metric runs on every sync (`AUTO_DIRTY_SAMPLE_EVERY`, default 1) whenever `AUTO_DIRTY_TRACKING` (default on) or `ENABLE_CHANGE_OBJECT_METRICS` is set.
- The switch turns dirty tracking off after 30 consecutive samples with the change rate's EMA ≥ 0.55. It turns it back on after 30 consecutive samples ≤ 0.30.
- On Hero Defense cap100 it turns dirty tracking off at about sample 35 and leaves it off (#516's traces).
- Dirty tracking changes only which root fields a sync reads, never the bytes. On the tables, "off" walks every root field and "on" skips the clean ones.
- Dirty tracking also decides whether `beginSync` clears the dirty marks: "off" skips the recursive `clearDirty()` (`TransportAdapter.swift:703-710`). So "off" costs more reads but saves the reset, and which is cheaper depends on the land.

**Per-player fields** (`.perPlayer`, `.perPlayerSlice`, `.custom`) aren't in the broadcast tables. They take today's per-player snapshot diff against `lastPerPlayerSnapshots`, with or without the tables. That stays so until #514.

## 2. What flips (decided)

**Decided (the maintainer, 2026-11-12, choice (a)):** `USE_SYNC_TABLES` and `TYPED_LEAF_VALUES` (#513) both flip to on, and each keeps its opt-out (`=false`).
- Both are byte-identical to today's path, and neither changes what a client receives.
- Their gains are already attributed by their own A/Bs (#465/#509 for the tables, #513 for leaf values).
- **Rejected:**
  - (b) flipping `TYPED_LEAF_VALUES` later in its own PR: one more A/B for a gain already measured;
  - (c) folding in row addressing's flip F, which changes the wire. F is its own PR, after this one.

**After the flip,** for an adapter on `.delta`:
- **Broadcast fields:**
  - on the tables;
  - a leaf of a known type converted by its typed form;
  - the logged fallback for fields the tables can't express (section 1).
- **Per-player fields:** today's per-player snapshot diff, unchanged, until #514. A node with player-dependent fields stays on the fallback as today. Its view without a player is refused (#179).
- **`.fullSnapshot` strategy:** today's path. The tables serve `.delta` only.
- **Recording and replay:** unchanged.
  - The recorded sync stream is the same bytes.
  - The replay verifier's `SyncOutputShadow` keeps running today's `SyncEngine`. On a recorded run with in-turn sync, it becomes an independent oracle for the tables. It compares canonical patch hashes, not frame bytes.
- **In-turn sync off** (the legacy tick path): the tables are on there too. That path records no sync stream (`TransportAdapter.swift:3893-3897`), so it has no replay oracle. Its evidence is the frame-identity cells under CI's `build (in-turn sync false)` job, which runs them with the tables on from this PR on.

**Each land type in this repo after the flip.** The PR pins every shipped state's recursive fallback list (`syncTableFallbackFields(of:)`) in a test, so a nested field that starts falling back shows up in review. Root kinds alone (today's pin for two of them) miss a nested field:

| Land | Broadcast on the tables | Per-player | Pinned today |
|---|---|---|---|
| hero-defense (GameDemo) | all root fields typed | none | root kinds only (`SyncTablesFrameIdentityTests`) |
| visibility test (GameDemo) | typed | `.perPlayer` `entities`, today's path | root kinds only |
| card-game (GameDemo) | to be pinned | `.perPlayerSlice` `hands`, today's path | no |
| cookie, counter (Demo) | to be pinned | cookie: `.perPlayerSlice`, today's path | no |
| reevaluation monitor | to be pinned | to be pinned | no |

The PR pins the recursive list for all six.

If a shipped land turns out to have a fallback field, the PR reports it in its body and leaves the field on the fallback. Making the type `Equatable` is a separate change.

## 3. The auto switch and the metric removed

- **Removed:**
  - `maybeAutoSwitchDirtyTracking`;
  - the change-object metric (`DirtyTrackingMetrics`, `DirtyTrackingSampling`, `logChangeObjectMetrics`, and #516's row counts with their debug oracle);
  - the candidate counters, and the `ENABLE_CHANGE_OBJECT_METRICS`, `CHANGE_OBJECT_METRICS_*` and `AUTO_DIRTY_*` keys.
- **Dirty tracking is fixed per adapter:** `ENABLE_DIRTY_TRACKING` (default on), or `setDirtyTrackingEnabled(_:)` at run time. Both are kept.
- **The opt-out path** also runs with that fixed mode. Its frames don't change. Its speed on a high-change land may, and that isn't gated: it is a fallback.
- **A set but removed key** (any of the env keys above) gets one warning per process, at the first adapter's init, naming it and saying it is ignored. A deployment that set one isn't changed silently, and a multi-room process logs it once.
- **#516's metric tests** (`ChangeMetricsFromRowsTests`) and the metric-oracle comments go with the metric. The plan of #516 said this PR removes the metric.
- **EncodingBenchmark:**
  - `--dirty-tracking` takes `on` (the new default, matching the adapter's) and `off`.
  - `auto` is an error, since there is no switching left. Today `auto` is the default (`BenchmarkConfig.swift:196`), so a run with no flag moves from `auto` to `on`. Its JSON records `dirtyTracking: on` (`DirtyTrackingMode.current`), with the help text updated.
  - `apply()` no longer sets `AUTO_DIRTY_TRACKING` (today it does for `on` and `off`, `:89-90`), so the benchmark doesn't trip the ignored-key warning.
  - The recorded env key lists (`ResultsMetadata.swift:168-170`, `EncodingBenchmarkMain.swift:1034-1036`, `ViewCapture.swift:93`) keep the removed keys. A run where one is set then shows it, and the adapter warns about it.
  - `dirtyTrackingEffective` stays and reports the fixed mode.
  - `config.useSyncTables` and `typedLeafValues` record the effective value, not "as set".
- **Topic scripts:** none passes `auto`. The ones that run EncodingBenchmark without the flag (`deep-research/{snapshot-baseline,entity-delta-baseline,single-room-entity-scaling,visibility,wire-ablation-2026-11}/run.sh`) now run with dirty tracking on. Their READMEs get a line saying that a rerun from this commit on records `on` where older results record `auto`.
- **`deep-research/serverenv.py`:** the removed keys stay in `SERVER_ENV`, marked removed, so old run metadata still parses and a record with one set is still refused. Its docstring's "`USE_SYNC_TABLES` … default off" and `test_serverenv.py`'s comments are updated. So is `deep-research/wire-ablation-2026-11/README.md`'s description of the knob.

## 4. Public API and behavior (decided)

**Decided (the maintainer, 2026-11-12, choice (a)):** remove the auto switch's public surface.
- **`TransportEnvConfig`'s public lets:**
  - `enableChangeObjectMetrics`, `changeObjectMetricsLogEvery`, `changeObjectMetricsEmaAlpha`;
  - `enableAutoDirtyTracking`, `autoDirtyOffThreshold`, `autoDirtyOnThreshold`;
  - `autoDirtyRequiredConsecutiveSamples`, `autoDirtySampleEvery`.
- **Its public init:** the matching parameters.
- This is source-breaking for a caller that passes them. There are no users yet (the maintainer, 2026-11-10).
- **Rejected:**
  - (b) keeping them as deprecated no-ops until the opt-out path goes: code kept for no user;
  - (c) keeping the switch on the opt-out path only: it keeps the metric, its oracle and the sampling alive for a fallback.

**Behavior changes:**
- `USE_SYNC_TABLES` and `TYPED_LEAF_VALUES` default to true. Unset now means on, and `=false` opts out.
- `TransportEnvConfig.init` already reads both from the environment, so a test that wants the old path sets `=false` or uses the SPI.
- The adapter's config log keeps its `syncTables` and `typedLeafValues` entries and drops the auto-dirty ones.

**No new enum cases. No new public API.** The kept SPIs (`syncTablesEnabled`, `typedLeafValuesEnabled`) are unchanged.

## 5. Docs (bilingual)

Both languages in the same PR:
- **`docs/transport/README`:**
  - the env table: `USE_SYNC_TABLES` and `TYPED_LEAF_VALUES` default true, described as the default path with `=false` as a fallback to be removed;
  - the `ENABLE_CHANGE_OBJECT_METRICS`, `CHANGE_OBJECT_METRICS_*` and `AUTO_DIRTY_*` rows removed.
- **`docs/core/sync`:**
  - "experimental and off by default" becomes the default path;
  - the "Dirty Tracking" section loses runtime auto switching and keeps `setDirtyTrackingEnabled`.
- **`docs/FAQ`:** "When should I disable dirty tracking?" The answer follows section 7's on/off measurement. Off reads every root field but skips the dirty-mark reset, so the measurement decides the wording. The opt-out path's old advice is kept in one sentence.

## 6. Tests and CI

- **The whole suite runs with the new defaults:** every job, `SwiftStateTreeTests` included. That closes Review's #513 should (r4550190007): the land cells, the atomic pattern adapter tests and the leaf tests now run with typed leaves in CI.
- **The `build (sync tables on)` job becomes `build (sync tables off)`:**
  - `USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false`;
  - the whole `swift test`, not the transport and NIO filter, so the opt-out path keeps the coverage the default had;
  - its guard checks that the test pinning the switch ran (renamed for the new default);
  - its stale comment about "the one adapter built in SwiftStateTreeTests" goes.
- **Tests that set the switch:** the cells that set `config.useSyncTables = tables` (the land cells, byte identity, row addressing and the atomic pattern adapter tests) set both sides explicitly, so they don't depend on the default.
- **Tests that depended on the auto switch:**
  - Every test that passes the removed init parameters loses them. The list is `git grep -lE 'enableAutoDirtyTracking:|autoDirty[A-Za-z]*:|changeObjectMetrics[A-Za-z]*:|enableChangeObjectMetrics:'`: about 20 files in `Tests/`, among them `DirtyTrackingByteIdentityTests`, `SyncStrategyEquivalenceTests`, `TransportAdapterSyncDirtyWindowTests` and `TransportAdapterMergedBroadcastTests`, plus `Examples/GameDemo/Tests/SyncTablesFrameIdentityTests.swift`.
  - `SyncTablesLandCellTests`'s `landCellConfig(autoDirty:…)` helper loses that parameter. Its auto-switch cells and `ChangeMetricsFromRowsTests` go.
  - `AutoDirtySamplingTests` and the auto-switch decisions in `SyncTablesByteIdentityTests` (the per-sync `dirtyTrackingEnabledForTesting` sequence and `changeMetricsSamplesForTesting`) are removed with the switch.
  - A new test checks that a set `AUTO_DIRTY_TRACKING` key logs the ignored-key warning once per process and changes nothing.
- **New pins:** each shipped land's fallback list (section 2's table).
- **E2E:** `test-e2e-game.sh`'s #80 variant (`AUTO_DIRTY_TRACKING=false`) becomes the opt-out leg, `USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false` on messagepack, with the same scenarios. #80's case, metrics off, is the default from now on. The description in `Tools/CLI/scenarios/game/test-broadcast-field-and-event.json` that names the variant is updated.
- **Effective state, not env:** the off job and the E2E opt-out leg each assert that the tables are actually off, not just that the env is set:
  - the off job through a test reading `usesSyncTablesForTesting()`;
  - the E2E leg through the server's `syncTables=off` config log line.
  Row addressing would turn them back on (section 0).

## 7. Gate for merge

Each item below needs its evidence in the PR:

1. **Host A/B, base (main before this PR) against head, default settings on both sides.** This uses #392's flip gate as decided on 2026-11-11 (no 50 % bar).
   - **Cells:** cap100 through the router, cap100 without it, the visibility land's cells, and cap500-idle.
   - **cap500-idle** is `--monster-cap 500 --monster-active-every 40` (the knob landed on `main` first). At 2 ticks per sync, about 5 % of the monsters are written per sync, the parent plan's idle share. On the Mac its bytes per sync were 4.7 % of the same cell with every monster active.
   - **No regression:** #373's bounds on sync time.
   - **Outside the sync:** a delta beyond the code-layout band of #517 (±3–4 %) needs an instructions check (`perf stat`, user mode only) before it counts as a regression or is cleared.
   - **Tick time** is reported next to sync time.
   - **Reported whatever their size:**
     - CPU (sync phase and total);
     - bytes per player per second, which should be identical;
     - peak RSS. The retired broadcast cache should lower it.
   - **Recording on:** its cost is reported.
   - **Drain:** the non-sleeping drain on both sides.
   - **Attribution pair, reported, not gating.** Base against head on default settings mixes three changes: the tables and leaf flip, the per-sync metric going away, and the dirty mode (base's Hero Defense switches off at about sync 35; head stays on). One extra pair on cap100 through the router isolates the flip: base with `AUTO_DIRTY_TRACKING=false ENABLE_DIRTY_TRACKING=true` (dirty on, no metric) against head with its defaults.
   - **Dirty on against off, on head, reported:** cap100 and cap500-idle, `--dirty-tracking on` against `off`. That is the evidence that a fixed "on" costs nothing on a high-change land, and it is what section 5's FAQ wording follows.
2. **Received streams equal.**
   - Per-session digests from `Examples/GameDemo/scripts/capture-digest.py` (#515) must be equal between base and head for every land type the benchmark can capture: hero-defense and visibility-test.
   - The other land types (card-game, cookie, counter, the reevaluation monitor) get in-process per-recipient frame-identity cells with the tables on and off, in all three encodings, as `SyncTablesFrameIdentityTests` does for the two above.
   - E2E servers have no capture, so E2E proves convergence (`assertConverged`) on both legs rather than equal digests.
   - **Replay:** two recorded tables-on runs, both with in-turn sync on, verify with `SyncOutputShadow`:
     - visibility-test through the benchmark's `--capture-views --record-dir` (only that land records there);
     - hero-defense through the E2E's reevaluation leg.
     The PR reports each one's status (verified), comparison count (> 0) and skips.
3. **E2E** in all three encodings, both in-turn sync modes, plus the opt-out leg.
4. **CI:** green, with the `build (sync tables off)` job of section 6 running the whole suite.

The usual: full `swift test` locally under the default and the opt-out, the `ts-sdk` and `ws-loadtest` checks, and Review GO.

## 8. Commit plan

One PR to `main`:
1. **`Sources/`:**
   - the defaults flip;
   - the switch, the metric and their keys removed;
   - the ignored-key warning;
   - the config log entries.
2. **`Tests/` and `.github/workflows/`:** tests adjusted and added, and the off job.
3. **`Examples/` and `Tools/`:** EncodingBenchmark's mode and config record, the land pins in the Examples tests, and the E2E opt-out leg.
4. **`docs/`:** both languages.

The A/B and the digests run on the PR's head. The PR body carries their tables.
