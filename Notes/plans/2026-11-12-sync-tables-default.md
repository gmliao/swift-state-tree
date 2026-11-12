# Sync tables by default, and the auto dirty switch removed (step 2, PR 4)

Status: open (rev 1, for review). PR 4 of [Flat storage step 2](2026-11-10-flat-storage-step2.md) (§7). Two choices wait on the maintainer and are marked **provisional** where they apply: what flips with the tables (section 2), and what happens to the auto switch's public API (section 4).

## 0. Scope

- The broadcast diff runs on the typed sync tables by default, for every adapter on the delta strategy.
- The auto dirty-tracking switch and the change-object metric that feeds it are removed.
- Today's snapshot diff stays reachable as an explicit opt-out (`USE_SYNC_TABLES=false`). It is documented as a fallback to be removed later, with no date.
- **Not in this plan:**
  - Row addressing's default (its plan's PR F). It changes the wire and requires clients to declare the feature. It is not promised here.
  - Per-player fields on the tables (#514).
  - Any later flattening step. Flattening ends with this PR and #514.
- **Lessons consulted:**
  - `Notes/solutions/2026-11-12-an-equality-trace-misses-a-key-bug-when-keys-collide.md`: removing the metric removes its oracle with it.
  - The #517 note: a non-sync delta of a few percent needs an instructions check before it is attributed.
  - `Notes/solutions/2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md`: the drain used for measurements.

## 1. What exists today (main at `50e76feb`)

**The tables switch.**
- `TransportEnvConfig.useSyncTables` is `package` and reads `USE_SYNC_TABLES` once per process (`TransportEnvConfig.swift:64`, `:104`). It defaults to off. The Diagnostics SPI `useSyncTablesEnabled` exposes it.
- The adapter turns the tables on at init when `(useSyncTables || rowAddressing) && syncStrategy == .delta` (`TransportAdapter.swift:1315`). The choice is fixed for the adapter's lifetime: nothing turns the tables off at run time.
- With the tables on, the adapter:
  - builds `SyncTableBroadcastDiff` (`:1361`);
  - retires the broadcast snapshot cache (`syncEngine.broadcastCacheRetired`);
  - logs once per state type, as a warning, the fields that take the snapshot fallback (`:1369`).

**What the tables can't express** is decided per field at registration, never per land, and never at run time. A field takes the `fallback` kind, which is today's snapshot diff for that field, when its value:
- isn't `Equatable`;
- is or holds a reference type;
- holds a state node outside the walked shapes;
- has player-dependent fields;
- is a class;
- is an atomic type without an atomic layout node.

The reasons come from `SyncTables.swift:68-73` and `:186-200`. A state with no typed field description (a hand-written `StateNodeProtocol` without the macro) runs entirely on the fallback, with the reason "has no typed field description". No land is refused, and no field falls back silently: `syncTableFallbackFields(of:)` lists every such field, and the adapter logs that list.

**The auto dirty switch** is `maybeAutoSwitchDirtyTracking` (`TransportAdapter.swift:5863`).
- The change-object metric runs on every sync (`AUTO_DIRTY_SAMPLE_EVERY`, default 1) whenever `AUTO_DIRTY_TRACKING` (default on) or `ENABLE_CHANGE_OBJECT_METRICS` is set.
- The switch turns dirty tracking off after 30 consecutive samples with the change rate's EMA ≥ 0.55. It turns it back on after 30 consecutive samples ≤ 0.30.
- On Hero Defense cap100 it turns dirty tracking off at about sample 35 and leaves it off (#516's traces).
- Dirty tracking changes only which root fields a sync reads, never the bytes. On the tables, "off" walks every root field and "on" skips the clean ones.

**Per-player fields** (`.perPlayer`, `.perPlayerSlice`, `.custom`) aren't in the broadcast tables. They take today's per-player snapshot diff against `lastPerPlayerSnapshots`, with or without the tables. That stays so until #514.

## 2. What flips (provisional: maintainer)

**Provisional choice (a):** `USE_SYNC_TABLES` and `TYPED_LEAF_VALUES` (#513) both flip to on, and each keeps its opt-out (`=false`).
- Both are byte-identical to today's path, and neither changes what a client receives.
- Their gains are already attributed by their own A/Bs (#465/#509 for the tables, #513 for leaf values).
- **Rejected:**
  - (b) flipping `TYPED_LEAF_VALUES` later in its own PR: one more A/B for a gain already measured;
  - (c) folding in row addressing's flip F, which changes the wire.

**After the flip,** for an adapter on `.delta`:
- **Broadcast fields:**
  - on the tables;
  - a leaf of a known type converted by its typed form;
  - the logged fallback for fields the tables can't express (section 1).
- **Per-player fields:** today's per-player snapshot diff, unchanged, until #514. A node with player-dependent fields stays on the fallback as today. Its view without a player is refused (#179).
- **`.fullSnapshot` strategy:** today's path. The tables serve `.delta` only.
- **Recording and replay:** unchanged.
  - The recorded sync stream is the same bytes.
  - The replay verifier's `SyncOutputShadow` keeps running today's `SyncEngine` and becomes an independent oracle for the tables on every recorded run.
- **In-turn sync off** (the legacy tick path): the tables are on there too. CI's `build (in-turn sync false)` job covers it from this PR on, where until now only local runs did.

**Each land type in this repo after the flip.** The PR pins every shipped land's fallback list in a test, so a later field change that falls back shows up in review:

| Land | Broadcast on the tables | Per-player | Pinned today? |
|---|---|---|---|
| hero-defense (GameDemo) | all fields typed | none | yes (`SyncTablesFrameIdentityTests` kinds) |
| visibility test (GameDemo) | typed | `.perPlayer` `entities`, today's path | yes |
| card-game (GameDemo) | to be pinned | `.perPlayerSlice` `hands`, today's path | added in this PR |
| cookie, counter (Demo) | to be pinned | cookie: `.perPlayerSlice`, today's path | added in this PR |
| reevaluation monitor | to be pinned | to be pinned | added in this PR |

If a shipped land turns out to have a fallback field, the PR reports it in its body and leaves the field on the fallback. Making the type `Equatable` is a separate change.

## 3. The auto switch and the metric removed

- **Removed:**
  - `maybeAutoSwitchDirtyTracking`;
  - the change-object metric (`DirtyTrackingMetrics`, `DirtyTrackingSampling`, `logChangeObjectMetrics`, and #516's row counts with their debug oracle);
  - the candidate counters, and the `ENABLE_CHANGE_OBJECT_METRICS`, `CHANGE_OBJECT_METRICS_*` and `AUTO_DIRTY_*` keys.
- **Dirty tracking is fixed per adapter:** `ENABLE_DIRTY_TRACKING` (default on), or `setDirtyTrackingEnabled(_:)` at run time. Both are kept.
- **The opt-out path** also runs with that fixed mode. Its frames don't change. Its speed on a high-change land may, and that isn't gated: it is a fallback.
- **A set but removed key** (any of the env keys above) gets one warning at adapter init that names it and says it is ignored, so a deployment that set one isn't changed silently.
- **#516's metric tests** (`ChangeMetricsFromRowsTests`) and the metric-oracle comments go with the metric. The plan of #516 said this PR removes the metric.
- **EncodingBenchmark:**
  - `--dirty-tracking` keeps `on` and `off`.
  - `auto` stays accepted and now means the adapter's default, dirty tracking on, with no switching. Host scripts that pass it keep working, and the results record the effective mode.
  - `dirtyTrackingEffective` stays and reports the fixed mode.
  - `config.useSyncTables` and `typedLeafValues` record the effective value, not "as set".

## 4. Public API and behavior (provisional: maintainer)

**Provisional choice (a):** remove the auto switch's public surface.
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

**No new enum cases. No new public API.** The kept SPIs (`useSyncTablesEnabled`, `typedLeafValuesEnabled`) are unchanged.

## 5. Docs (bilingual)

Both languages in the same PR:
- **`docs/transport/README`:**
  - the env table: `USE_SYNC_TABLES` and `TYPED_LEAF_VALUES` default true, described as the default path with `=false` as a fallback to be removed;
  - the `ENABLE_CHANGE_OBJECT_METRICS`, `CHANGE_OBJECT_METRICS_*` and `AUTO_DIRTY_*` rows removed.
- **`docs/core/sync`:**
  - "experimental and off by default" becomes the default path;
  - the "Dirty Tracking" section loses runtime auto switching and keeps `setDirtyTrackingEnabled`.
- **`docs/FAQ`:** "When should I disable dirty tracking?" On the tables, off reads more fields for the same patches, so the answer becomes "keep it on". The opt-out path's old advice is kept in one sentence.

## 6. Tests and CI

- **The whole suite runs with the new defaults:** every job, `SwiftStateTreeTests` included. That closes Review's #513 should (r4550190007): the land cells, the atomic pattern adapter tests and the leaf tests now run with typed leaves in CI.
- **The `build (sync tables on)` job becomes `build (sync tables off)`:**
  - `USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false`;
  - the whole `swift test`, not the transport and NIO filter, so the opt-out path keeps the coverage the default had;
  - its guard checks that the test pinning the switch ran (renamed for the new default);
  - its stale comment about "the one adapter built in SwiftStateTreeTests" goes.
- **Tests that set the switch:** the cells that set `config.useSyncTables = tables` (the land cells, byte identity, row addressing and the atomic pattern adapter tests) set both sides explicitly, so they don't depend on the default.
- **Tests that depended on the auto switch:**
  - `SyncTablesFrameIdentityTests`'s `autoDirty*` config arguments go.
  - `AutoDirtySamplingTests` and the auto-switch decisions in `SyncTablesByteIdentityTests` (the per-sync `dirtyTrackingEnabledForTesting` sequence and `changeMetricsSamplesForTesting`) are removed with the switch.
  - A new test checks that a set `AUTO_DIRTY_TRACKING` key logs the ignored-key warning and changes nothing.
- **New pins:** each shipped land's fallback list (section 2's table).
- **E2E:** `test-e2e-game.sh`'s #80 variant (`AUTO_DIRTY_TRACKING=false`) becomes the opt-out leg, `USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false` on messagepack, with the same scenarios. #80's case, metrics off, is the default from now on.

## 7. Gate for merge

Each item below needs its evidence in the PR:

1. **Host A/B, base (main before this PR) against head, default settings on both sides.** This uses #392's flip gate as decided on 2026-11-11 (no 50 % bar).
   - **Cells:** cap100 through the router, cap100 without it, the visibility land's cells, and cap500-idle. EncodingBenchmark has no idle-monster knob today (#513 skipped that cell). The knob comes first, as a separate Examples change, or the cell is reported as skipped; Main decides which.
   - **No regression:** #373's bounds on sync time.
   - **Outside the sync:** a delta beyond the code-layout band of #517 (±3–4 %) needs an instructions check (`perf stat`, user mode only) before it counts as a regression or is cleared.
   - **Tick time** is reported next to sync time.
   - **Reported whatever their size:**
     - CPU (sync phase and total);
     - bytes per player per second, which should be identical;
     - peak RSS. The retired broadcast cache should lower it.
   - **Recording on:** its cost is reported.
   - **Drain:** the non-sleeping drain on both sides.
2. **Received streams equal.**
   - Per-session digests from `Examples/GameDemo/scripts/capture-digest.py` (#515) must be equal between base and head for every land type the benchmark can capture: hero-defense and visibility-test.
   - The other land types (card-game, cookie, counter, the reevaluation monitor) get in-process per-recipient frame-identity cells with the tables on and off, in all three encodings, as `SyncTablesFrameIdentityTests` does for the two above.
   - E2E servers have no capture, so E2E proves convergence (`assertConverged`) on both legs rather than equal digests.
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
