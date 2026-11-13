# Per-player fields on typed per-player sync tables (#514)

**Status:** draft, rev 3 (2026-11-13), for review.
- This is step 2's PR 3 (`2026-11-10-flat-storage-step2.md` §5 and §7), which never started. Read at `main` 9bf7df61.
- Rev 1 (65cb9b53) got a no-GO: 4 must-fix, 6 should, 1 nit. Rev 2 (38e59fed) addressed them: M1 in §3, M2 in §1 and §3, M3 in §3, M4 in §2, S1 in §3, S2 in §5 and §7, S3 in §4, S4 in §5 and §6, S5 in §2, S6 in §4, N1 in §3.
- Rev 2 got 2 must-fix, 3 should and 1 nit. Rev 3 addresses them: M5 and M6 in §2 (the selection is today's per-player mode, so the retry set is gone), S7 and N2 in §3, S8 and S9 in §4.
- No code before this plan is reviewed.

**Depends on:** row addressing's default flip (PR F of `2026-11-10-row-addressing.md` §9), which lands first. Section 7 lists the overlap.

**Decided (2026-11-13):**
- D1: per-player fields are diffed only where today's per-player mode compares them (§2, option (a) of the rev 2 review), under the purity contract. No retry set: a dropped or lagging field is re-diffed exactly when today re-diffs it.
- D2: one PR, on by default, with an opt-out. This follows #523's pattern and stays within the approved flattening plan.
- D3: the env key is `PER_PLAYER_SYNC_TABLES`, classified in `deep-research/serverenv.py`.
- D4: a player's second session getting no per-player changes is a bug, #531. This PR keeps today's bytes, and its pin is marked as a known bug citing #531.

## 0. Before starting: the share

#514 asks for this first: measure the share of the visibility land's sync time that per-player fields take, with the broadcast tables on. If it is small, the work stays deferred.

**What is known:**
- The visibility land's sync dominates its iteration. In #527's measurement (10 rooms, 5 players each, tables on), `syncMs` was 3702 ms and `tickMs` 902 ms over 2000 iterations.
- Its only per-player field is `entities`, a `[String: VisibleEntity]` filtered per player (`VisibilityTestLand.swift:203-206`). Every entity moves every tick, so the field is dirty on every sync.

**The measurement:** a sampled profile of `EncodingBenchmark --game-type visibility-test --rooms 10 --players-per-room 5 --parallel false`, release, on the Mac, to get the direction. It buckets sync time into:
- (a) the filter closure;
- (b) per-player conversion: `extractPerPlayerSnapshot` → `SnapshotValue` for each entity a player sees;
- (c) the per-player tree diff (`computePerPlayerDiffFromSnapshot` → `compareSnapshots`) and staging;
- (d) encoding and the rest.

This plan removes (b) and (c), except the conversion of changed leaves. (a) is the land's own code.

**Stop rule:** if (b) + (c) is under 15 % of vis sync time, report it on #514 and keep #514 deferred. Everything below applies only if the share clears 15 %.

## 1. Scope

**Root fields whose policy is player-dependent.** That means every root field the per-player part of `snapshotForSync` handles today (`StateNodeBuilderMacro.swift:583-586`: policy neither `.broadcast` nor `.serverOnly`):

| Policy | Today | Under this plan |
|---|---|---|
| `.perPlayer(f)` | filter per player on the native value, convert the whole output for that player, tree diff | filter per player (unchanged); typed diff of the output against that player's box |
| `.perPlayerSlice()` | the same; the closure returns nil when the player has no entry (`SyncPolicy.swift:89-97`) | the same as `.perPlayer`; nil is "absent" (§3) |
| `.custom(f)` (deprecated, #198) | the same, with the arguments swapped | the same as `.perPlayer`, until #198 removes it |
| `.masked(f)` at the root | in the per-player part: `filteredValue(for: playerID)` gives `mask(value)` | the same as `.perPlayer`, with one box per player. Used only in tests |
| unrecognized (`.unknown`) | per-player part | per-player fallback (below) |

**Per-player descriptors (M2).** Today's typed descriptors have no player:
- `_syncTableFields()` emits `SyncTableField.make(…, read: { filteredValue($0._x.wrappedValue, for: nil) }, convert: …)` (`StateNodeBuilderMacro.swift:429-435`), and its conversion has no player context.
- The per-player part of `snapshotForSync` passes `playerID` into the conversion (`generateConversionCode(…, playerID: "playerID")`, 660-666). So a nested node with player-dependent fields is filtered for that player.

The macro therefore emits a second list, `_syncTablePerPlayerFields()`, one descriptor per player-dependent root field:
- `read: (Self, PlayerID) -> Value?`, which is `Self._syncPolicy_<x>.filteredValue(self._x.wrappedValue, for: playerID)`. This is the call today's per-player part makes.
- **A player-aware converter.** A changed value, and a fallback field's whole output, is converted with today's per-player conversion for that player (`generateConversionCode(…, playerID:)`). A nested player-dependent node, such as a `.perPlayer` or `.custom` field inside a node under a per-player root, is then filtered for the same player.
- **The kind:** resolved by the same `SyncTableField.make` overloads (`SyncTables.swift:73-142`). A node type with player-dependent nested fields (`N.hasPlayerDependentSyncFields`, 218) takes the fallback, as on the broadcast side.

**A typed row is player-independent below its root.** Its synced fields are `.broadcast`, `.serverOnly` or `.masked`, and none depends on the player. A node with any player-dependent field is a fallback. So a typed row's compare and leaf conversion need no player. Only the root read, and the fallback's conversion, take the player.

**Fallback per player:** today's path for that one field and that one player. The output is converted with the player-aware converter and diffed against the player's cached `SnapshotValue` of that field. This covers unknown policies, nodes with player-dependent nested fields, and the shapes the broadcast side sends to the fallback.

**Not in scope:** nested player-dependent policies below a broadcast root, which keep the broadcast side's fallback; per-player row addressing (§7); row-level visibility (step 2 §6).

## 2. What changes in the diff path

**Today, per sync,** with the tables on (`TransportAdapter.extractSyncSnapshots`, 5012-5083):
1. Deduplicate the recipients by player (`seenPlayers`).
2. Take one of two branches:
   - **(B1) One-pass**, when `useSnapshotForSync` and the broadcast diff dropped nothing (5040-5056). If the state has no per-player fields, there is **no entry** at all. Otherwise, per player, `extractPerPlayerSnapshot(mode: .include(perPlayerFields))` converts every per-player field. If any of them throws, it falls to B2.
   - **(B2) Separate extraction** (5063-): one entry **per player, whatever the state has**, empty when it has no per-player fields. A throwing field is dropped for that player alone, and counted.
3. Per recipient, in recipient order: `generatePerPlayerUpdateFromSnapshot` (or `generateUpdateFromBroadcastDiff` for the combined JSON frame) diffs the entry against `staged.perPlayer[p] ?? lastPerPlayerSnapshots[p]` and stages the new snapshot. Then:
   - `.noChange` is skipped;
   - under a key reset (`typesFirstSync`), the update becomes `keyScopeResetUpdate`, so an empty entry is a `.firstSync([])` frame (5146-5150).

**Under this plan, per sync:**
1. Deduplicate by player, as today.
2. **The same two branches, with the same predicate.** An entry exists exactly when today's branch would make one. B1 makes none for a state without per-player fields. B2 makes an empty one per player, which under a key reset still becomes `.firstSync([])` (M4). B1's all-or-nothing fallback to B2 is kept, and so are B2's drop counts, because the branch decides which entries exist.
3. **Per player that has an entry,** per per-player root field that today's mode compares (D1 below), call `read(state, playerID)` and diff the output against the player's box (§3). The broadcast tables' differs do the work, and only a changed leaf is converted.
4. **Stage per (player, field)** in the plan's per-player staging (§3, separate from the broadcast staging).
5. **Hand the per-player patches to the recipients in recipient order** (§3, S1).

**Kept as today:**
- **Throwing conversions.** No patches for that field and that player, its box isn't advanced, and the drop is counted as B2 counts it.
- **Patch order.** Every state-update encoder sorts each frame's patches by the land's canonical order (`CanonicalFrameOrder`, set at registration, TA 1262 and 1291). The typed diff's emit order therefore can't change bytes. The frame identity tests check this.
- **Key reset.** Unchanged.

**What the visibility land saves per player per sync:** the `SnapshotValue` build of every visible entity, the whole-map tree diff, and the per-player snapshot staged. It still pays the filter, a typed compare of each visible entity's `id` and `position`, and the conversion of changed positions.

**D1: the selection is today's per-player mode (M5, M6).** Today every per-player field is *extracted* every sync, but only the mode's fields are *compared* and merged into the cache: `compareSnapshots(…, dirtyFields: mode.fields)`, then `mergeDirtyFields` for a `.dirtyTracking` mode or a whole replace for `.all` (SE 800-830). The mode comes from the branch:
- **B1 (one-pass):** `modesBesideTables` (TA ~5003-5009) gives `.dirtyTracking(planDirtyFields)` whenever dirty tracking is on and the plan is dirty, with broadcast names included, and `.all` otherwise. The same mode is used when B1 falls to B2.
- **B2 with one-pass off:** `computeSyncModes` (TA ~4972-4994) gives `.dirtyTracking(the dirty per-player fields)` when any per-player field is dirty, and `.all` otherwise.
- **extractAll, or dirty tracking off:** `.all`.

The per-player tables compute the mode with the same functions and diff exactly the per-player fields it names:
- **`.all`:** every per-player field of the player. The box is replaced, so a field the output hides becomes absent, with a delete as today's `.all` compare emits. A dropped field keeps its box value, as an extraction drop keeps its cached value.
- **`.dirtyTracking(S)`:** the per-player fields in S. The others aren't read, their boxes are untouched, and no delete is emitted for them, as with today's `dirtyFields` rule (SE 333-343).
- **An empty `.dirtyTracking` on a player with a box:** nothing, as SE 800-803.

The saving against today is the extraction of fields the mode doesn't compare. Its patches equal today's by construction.

**Throws.** Only a read field can throw. Today a B1 failure falls to B2 with the same mode, and B2 extracts only the mode's fields, so it counts drops only among them. A field outside the mode that would throw is never counted in either version. The drop counts are therefore equal.

**Lag, as today (M6).** A total per-player encode failure for p removes `p`'s staging (§3), as today removes `staged.perPlayer[p]` (TA 4929-4939). `beginSync` has already cleared the dirty marks (TA 3252-3256), so p's client lags its committed boxes until a later mode compares those fields:
- with one-pass off and only broadcast fields dirty next cycle, the mode is `.all` and the lag is re-diffed;
- with one-pass on, the mode is `.dirtyTracking(planDirtyFields)`, and p stays behind on a clean per-player field until it is written again.

The PR keeps that behavior byte for byte and pins it in both settings. Whether today's one-pass lag after a per-player encode failure is a bug is a separate question for its own issue, not changed here (§8).

**Every write to a per-player field marks it dirty.** A per-player field is a root `@Sync` field, and each mutation route goes through its wrapper:
- the setter, which sets `_isDirty`;
- the in-place `_modify` from #519, which marks before the yield;
- a nested node write and a map subscript write, which go through the root's `_modify`.

Today the `.dirtyTracking` modes already depend on these marks for the compare, so no new dependency is added. The PR still pins each route on a per-player field: the setter, `state.entities[k] = v`, `state.entities[k]?.position = …`, a nested node field write, and `f(&state.entities)`.

**Tests for D1,** each against today's output, with dirty tracking on and off:
- a dropped, clean per-player field while another per-player field is dirty, with one-pass on and with one-pass off (M5);
- a transient per-player encoder failure for p, then a broadcast-only mutation, with one-pass on and with one-pass off (M6);
- the B2 fallback triggered by a broadcast drop;
- a failed plan, then a committed one.

## 3. Storage, transitions, staging and the lifecycle

**Boxes.** A new `SyncTablePerPlayerDiff<State>` sits next to `broadcastTables` in the adapter. For each synced player it holds one box per per-player root field. A box is typed (`[K: N]`, `N`, `N?`, `V`) or, for the fallback, a `SnapshotValue`. It uses the same box types as the broadcast `SyncRootSlot`s (`SyncTables.swift:1065-1346`), plus a presence state (M1).

**Not slot-addressed, no splits.** Boxes are built without a path cursor, so the slotted `diffRows` never tags a row (`isSlotAddressed { cursor != nil }`, 1172). Per-player patches carry no split, as today, and the opcode encoders split their paths themselves. §7 explains why.

**Presence transitions (M1).** The broadcast root slots return early when the reader gives nil: `guard let value = read(state) else { return nil }` (`SyncTables.swift:1146, 1198, 1364`). On the broadcast side nil never follows a sent value. Per player it does: `.perPlayerSlice()` returns nil when the player's entry goes, and any filter can hide a field it showed. Today that is a root delete of the field, with the field dropped from the cache (`SyncEngine.swift:333-343`; `mergeDirtyFields`, 440-446). So the per-player box keeps a presence state, seeded or unseeded, and if seeded, present (with last-sent) or absent:

| Box | `read` gives | Emits | Stages |
|---|---|---|---|
| no box for the player | anything | nothing: today's first diff seeds the cache from the extraction and returns no patches (SE 805-808) | the read fields (B1: every per-player field, as its extraction; B2: the mode's fields) |
| present(old) | a value | the typed diff of old → new | the new value |
| present(old) | nil | a delete of the field's root path, as today's diff does | absent |
| absent | a value | a set of the whole field, as today's diff of a field that appears | present(new) |
| absent | nil | nothing | — |

- **The rows apply only to the fields the mode compares** (D1). A field outside a `.dirtyTracking` mode isn't read, and its box and presence are untouched. That is today's `dirtyFields` rule, under which a delete is emitted only for a field in the dirty set (SE 333-343). Under `.all` every per-player field is read, and a field the output lacks is deleted, as today's `.all` compare does.
- **A field never seeded in a player's existing box** is absent: today's compare sees it as new and sets it.
- **A full-view seed replaces presence** from the view: present when the view has the field, absent otherwise.
- Typed and fallback boxes follow the same table.

**Staging (M3).** Per-player writes are staged in their own namespace on the plan, `plan.stagedPerPlayerTables`, not inside the broadcast `SyncTableStaged`. A broadcast-only failure resets the broadcast staging (`plan.stagedTables = SyncTableStaged()`, TA 4766-4769 and 5470) while the per-player frames still go out. With one struct, the per-player boxes would fall behind the clients. The rule is to mirror today's `plan.staged.perPlayer[p]` exactly. Every place that sets, keeps or removes `plan.staged.perPlayer[p]` does the same to `p`'s staged per-player writes and seed. The cases depend on the branch (S7):
- **Opcode 107 merged frame** (`useStateUpdateWithEvents`, TA 4471-4494). When the merged broadcast frame can't encode, the broadcast staging is reset (TA 4766-4769) and `staged.perPlayer` is kept, while the per-player frames still go out. So the per-player staging is kept.
- **Combined frame** (json and opcodeJsonArray, `collectCombinedPendingUpdates`): each player's frame encodes both scopes. A failure there is a total per-player failure for that player (below), not a broadcast-only one.
- **Total per-player failure** for p (`data == nil`, TA 4929-4939, in either branch): `staged.perPlayer[p]` and the firstSync mark are removed, so `p`'s per-player staging is discarded. A re-encode that succeeds after dropping, such as the row-drop remake (TA 4586-4598), isn't a total failure and keeps the staging as today does. Only `data == nil` removes it.
- **The broadcast-only sync** (`planBroadcastOnlySyncPhase`) diffs no per-player fields, so there is nothing per-player to keep or discard (N2).
- **Failed plan:** all of it is discarded, as today.
- **Commit:** `commitSyncPhase` applies the per-player staging with `syncEngine.applyStaged` and `broadcastTables?.apply` (4229-4230).

**Players with several sessions (S1, D4, #531).** The diff runs once per player. Today's per-session output is kept exactly, by consuming the patches in recipient order:
- **The player's first recipient in recipient order** gets the update built from the player's patches, as `generatePerPlayerUpdateFromSnapshot` builds it.
- **Each later recipient of the same player** gets the update built from no per-player patches. That is what today's diff against the first recipient's staged snapshot yields:
  - `.noChange`, which is skipped;
  - under a key reset, `keyScopeResetUpdate` of it, a `.firstSync([])`;
  - in the combined JSON frame, the broadcast patches alone (`generateUpdateFromBroadcastDiff` with an empty per-player part).
- **Today the second session never receives per-player changes in a normal sync.** That is #531. The frame identity case that pins it is marked as a known bug citing #531, so the later fix changes the pin deliberately.

**Today's per-player cache, read and write by read and write.** SE = `SyncEngine.swift`, TA = `TransportAdapter.swift`.

| Today | Under the per-player tables |
|---|---|
| Diffs read `staged.perPlayer[p] ?? lastPerPlayerSnapshots[p]` (SE 778-830); `applyStaged` writes it (SE 94-103) | `p`'s staged writes, else its committed boxes. Applied at commit |
| A full view (late join, resync) re-stages `staged.perPlayer[id] = extractPerPlayerSnapshot(.all)` (TA 4669) | Stage a seed of `p`'s boxes and presence from the same state copy, with the player-aware read. The broadcast tables are untouched |
| The late-join view fills a dropped field from the caches (SE 1508-1534) | That field of `p`'s box, converted to `SnapshotValue` (nothing when absent) |
| Per-player encode failure (TA 4934-4940) | Discards `p`'s per-player staging (above) |
| `cachedPerPlayerSnapshot` (SE 116), read by `SyncOutputShadow` | Unchanged: the shadow runs its own engine |
| `cachedPerPlayerSnapshotForTesting` | With the per-player tables in effect, `p`'s boxes as a `StateSnapshot` |

**Two clears, two invariants (N1).** The boxes are cleared beside `clearCacheForDisconnectedPlayer`, at its exact placement in each path:
- **Disconnect** (TA ~1593, outside a turn): only when the player has no other session (`membershipCoordinator.sessionIDs(for:)` is empty), checked after the `keeper.leave` await in the same synchronous segment as the clear. A re-joined player's boxes are never cleared (`Notes/solutions/2026-11-05-callback-outlives-its-instance-clears-by-key.md`).
- **Supersede** (TA ~1973, at admission): unconditionally. The new session starts from empty, like a first join.

**A debug assertion** pins that nothing on the sync path reads `lastPerPlayerSnapshots` while the per-player tables are in effect, as `broadcastCacheRetired` does (SE 49-55).

## 4. The switch (D2, D3, S3, S6)

**One effective rule:** `perPlayerTablesInEffect = usesSyncTables && PER_PLAYER_SYNC_TABLES`.
- `usesSyncTables` is the adapter's effective broadcast-tables flag, `(useSyncTables || rowAddressing) && syncStrategy == .delta`. Here `rowAddressing` is row addressing **in effect**: requested, in-turn sync on, joins through the router, and the delta strategy (TA 1249-1252).
- So the per-player tables follow the broadcast tables, however those were turned on (S8).

| `USE_SYNC_TABLES` | row addressing | `syncStrategy` | `PER_PLAYER_SYNC_TABLES` | broadcast tables | per-player tables |
|---|---|---|---|---|---|
| on (default) | any | `.delta` | on (default) | on | **on** |
| on | any | `.delta` | off | on | off: today's path |
| off | not requested | `.delta` | any | off | off |
| off | requested, **in effect** (in-turn sync, router joins) | `.delta` | on | on (forced by rows) | **on** |
| off | requested, in effect | `.delta` | off | on (forced by rows) | off |
| off | requested, **not in effect** (a direct adapter, or in-turn sync off) | `.delta` | on | off | off |
| any | any | `.fullSnapshot` | any | off | off |

- **The env key:** `PER_PLAYER_SYNC_TABLES`, default on, read with `getEnvBool` as `USE_SYNC_TABLES` is (`TransportEnvConfig.swift:12, 86-90`).
- **Its settings:** a package config property, and an `@_spi(Diagnostics)` accessor for the effective value, for tests in other packages.
- **With the switch off,** per-player fields take today's code unchanged, so the switch is a rollback, not a second implementation.
- **Tests assert the effective state,** through the Diagnostics accessor, for every row of the table, the requested-but-not-in-effect row included.
- **CI:** `build (sync tables off)` covers off/off. A new matrix entry runs the Transport and NIO targets with `PER_PLAYER_SYNC_TABLES=false`. The identity tests toggle the three configurations in process.
- **`deep-research/serverenv.py` (S6, S9):** the key goes into `SERVER_ENV` beside `USE_SYNC_TABLES`, and into `ADDED_LATER`, with its date and PR in the comment. Without that, `failure()` rejects every older record that lacks it (serverenv.py:79-85). `test_serverenv.py` gains a case with an older record without the key, and runs locally in the same PR.
- **Docs:** the env table in `docs/transport` and its zh-TW companion.

## 5. Tests

**Red first:**
- the differential test and the identity cases, with the per-player tables on;
- the `lastPerPlayerSnapshots` assertion;
- a pin, through a test-only counting hook, that a state with per-player fields doesn't call `extractPerPlayerSnapshot` for them in a normal sync.

**Differential (engine level):** random mutation sequences, at least 10 000 steps per state type, with the seed printed on failure. It compares per player, as logical patch lists in canonical order, against `computePerPlayerDiffFromSnapshot`. The states:
- `VisibilityTestState` (radius and all);
- the `NestedNodePolicyTests` roots (`.perPlayer`, `.perPlayerSlice` and `.masked` root maps, nested `.serverOnly`), plus a new root holding a node with nested `.perPlayer` and `.custom` fields under a per-player root, which is M2's fallback with the player-aware converter;
- `DirtyIdentityState` (`.perPlayerSlice`);
- a state with an unknown policy.

The cases:
- outputs gaining and losing keys;
- **visible → hidden → visible** for the whole field (M1), typed and fallback, `.perPlayerSlice()` included: a player's entry removed and added again;
- an output going empty and back;
- nil ↔ value for an optional node output;
- NaN / −0.0;
- a conversion that throws for one player only: that player's patches, box and drop count as today's, the other players unaffected;
- a failed plan, after which the next plan equals today's;
- NFC and NFD forms of one key;
- players added and removed between steps.

**Frame identity (adapter level):** every encoding, per recipient, exact bytes, frame counts compared first. Three configurations run against each other in process:
- broadcast tables off;
- broadcast tables on with per-player tables off;
- both on.

They extend:
- `Examples/GameDemo/Tests/SyncTablesFrameIdentityTests.swift`: visibility radius and all; the broadcast twin (no per-player fields); the card game (`hands`); Hero Defense;
- `Examples/Demo/Tests/DemoContentTests/SyncTablesFrameIdentityTests.swift`: the cookie game;
- `Tests/SwiftStateTreeTests/SyncTablesLandCellTests.swift`: the shape matrix (no per-player fields) and the nested-policy land;
- `Tests/SwiftStateTreeTransportTests/SyncTablesByteIdentityTests.swift`: encoding × dirty × onePass × schema.

Each run includes:
- joins mid-run;
- a forced resync;
- a forced key reset (`syncPlanFaultForTesting`, and an encode drop);
- a throwing per-player conversion with a late join right after;
- a disconnect and reconnect;
- a supersede;
- the D1 cases (§2: M5's dropped clean field and M6's transient encoder failure, each with one-pass on and off).

**The failure paths, explicitly (M3, M4):**
- **Opcode 107:** the merged broadcast frame fails to encode while the per-player frames go out (TA 4766-4769). Then the next plan's frames and the committed boxes must equal today's.
- **Combined frame** (json, opcodeJsonArray): one player's frame fails, which is a total per-player failure for that player.
- **A total per-player failure** in each branch, against a re-encode that succeeds after a row drop, which keeps the staging.
- **The broadcast-only sync:** per-player boxes unchanged.
- **No per-player fields, B2:** a state without per-player fields, with one-pass off, then a key reset. The `.firstSync([])` frames must match today's count. The same with a broadcast extraction failure instead of one-pass off.
- **No per-player fields, B1:** the same state with one-pass on and a key reset, where no per-player frame is expected.

**Two sessions of one player** (direct `registerSession`, the only way two coexist; see #531): the first session gets the per-player patches; the second gets `.noChange`, `.firstSync([])` under a key reset, and the broadcast part alone in the combined JSON frame. Marked as a known bug citing #531.

**With row addressing in effect (S2, S4).**
- **Why a router-backed case:** the frame identity harnesses and the benchmark build direct adapters, whose initializer sets `joinsThroughRouter: false` (TA 1186). Row addressing never takes effect there.
- **The case:** a router-backed identity case for the visibility land (and the card game) that first asserts that `rowAddressing` is in the adapter's effective feature list.
- **What it asserts:** no patch rooted at a per-player policy field carries a row tag, and the full view's broadcast row bindings stay as F checks them.
- **What it doesn't assert:** that per-player frames hold no row entry. A full view goes through the per-player encode path, and with rows in effect `planFullViewUpdate` replaces the broadcast map patches with tagged table-view patches (TA 4677-4681), so join and resync frames carry ops 6–9 legitimately.

**Unchanged outputs:**
- verify-views;
- the sync-output goldens;
- the replay state hash;
- a recorded visibility run with the per-player tables on verifies against `SyncOutputShadow` with 0 mismatches.

**Mutants,** each killed by a named test:
- skip the resync seed;
- share one box across players;
- tag per-player patches with a row;
- advance a dropped field's box;
- skip the disconnect clear;
- keep presence on nil (M1);
- read a nested per-player field without the player (M2);
- stage per-player writes in the broadcast namespace (M3);
- suppress B2's empty entries (M4);
- send the patches to every session of the player (S1);
- select per-player fields other than today's mode names, in either direction (D1);
- discard the per-player staging on a successful dropping re-encode (S7).

## 6. Measurement (host A/B under the off-path instruction gate)

`2026-11-13-off-path-instruction-gate.md` applies: off-path work is judged by windowed `instructions:u`, and sync, this change's own path, by time. The host brief is drafted from this section once the PR has a head.

**Base:** `main` at run time, with F merged. **Head:** the PR merged with that main. Both run on defaults.

**Common flags,** as #527's: messagepack-pathhash, 2000 iterations, `--parallel false`, `--dirty-tracking on`, `--row-addressing` pinned.

| Cell | Command | Row addressing | Sync time (`syncMs`) | Off-path instructions |
|---|---|---|---|---|
| `vis-tick` | `--game-type visibility-test --rooms 10 --players-per-room 5` | **not in effect** (direct adapters) | judged: the main beneficiary. #514's gate is ≤ +5 %, and a gain is expected | judged (`ticks` window) |
| `vis-p16` | `--game-type visibility-test --rooms 2 --players-per-room 16` (the land's `maxPlayers`) | **not in effect** | judged: per-player cost grows with players | judged (`ticks` window) |
| `vis-broadcast` | `vis-tick` with `VISIBILITY_TEST_FILTER=broadcast` (no per-player fields) | **not in effect** | judged, control: within the bar | judged |
| `cap100-local` | `--game-type hero-defense --rooms 1 --monster-cap 100` (no per-player fields) | not in effect | judged, control: within the bar | judged (`nonsync` window) |

- **Sync bar:** head's mean above base's by more than max(2 %, base's spread) is a SYNC REGRESSION. A gain is head's mean below base's min.
- **Off-path bar:** the gate plan's max(0.5 %, 3 × base's spread) on instructions. Time is reported beside it, and "layout move (#517)" is printed where time moves but instructions don't.
- **Bytes and digests:** identical in every cell, base = base again = head. The capture pass adds head with `PER_PLAYER_SYNC_TABLES=false`, which must give base's bytes and digests.
- **Repeats:** ABBA, a warm-up pair and 5 pairs per cell, for both the timed set and the perf set. The perf set runs with `SWIFT_DETERMINISTIC_HASHING=1` and the FIFO window, in the standing container scope.
- **The summary script** includes the gate plan's script changes and its synthetic cases, plus this PR's (the opt-out capture).
- **Before the host:** a Mac direction number on `vis-tick` (ABAB, switch on against off). If sync time doesn't fall, stop and report.

## 7. Overlap with row addressing's default flip (F)

F flips `rowAddressing` on by default, and it lands first.

**A tagged per-player patch would become a row entry in the broadcast slot space.** `RowEntryPlan.plan` takes any patch with `split.row` and one dynamic key (`RowEntryPlan.swift:44-110`). Both opcode encoders apply it whatever the key scope (`OpcodeJSONStateUpdateEncoder.swift:289-291`, `OpcodeMessagePackStateUpdateEncoder.swift:227-228`). That is why the boxes have no cursor (§3), why §5 has the router-backed check (S2, S4), and why one mutant adds the tag.

**Per-player slot spaces** (row addressing §5: one per (player, table), told apart by `tableId`) are a follow-up, not #514.

**Shared files:**
- `TransportAdapter.swift`: `planSyncPhase`, `planFullViewUpdate`, `lateJoinSnapshot`, and the encode-failure and row-drop handling;
- `SyncTables.swift`: the root slots, extended for presence;
- the macro, for `_syncTablePerPlayerFields`;
- the frame identity tests, whose defaults F changes;
- EncodingBenchmark's `--row-addressing` default.

This PR branches after F merges and pins `--row-addressing` in the brief.

**F's full-view rule** (a full view takes the staged or the committed broadcast table by recipient) concerns the broadcast tables. A per-player seed reads the same state copy. The router-backed case runs a join and a resync with rows in effect.

## 8. Related issues

- **#531** (a player's second session gets no per-player changes): pinned, not fixed (§3).
- **#198** (remove `.custom`): handled like `.perPlayer` until then.
- **#192** (one frame per sync for per-player lands): unaffected; frame count and kinds are unchanged.
- **#130** (an independent per-player oracle): still open. The differential test compares against today's engine.
- **#199** (policies that read the root state): D1 relies on filter purity, as today's `.dirtyTracking` modes already do. A root-state policy needs its field dirtied by what it reads, as #199 notes.
- **The lag after a per-player encode failure with one-pass on** (§2, M6): today's behavior, kept and pinned. Whether it gets its own issue is decided outside this PR.
- **#314** (hash-seed-independent patch order): frames are canonically ordered (#435).
- **#524** (`PlayerHandle`): the boxes are keyed by `PlayerID`; a handle could key them by slot later.

## 9. Public API

None.
- `SyncTablePerPlayerDiff`, `_syncTablePerPlayerFields` and the config property are package-level or underscored macro members, as `_syncTableFields` is.
- The Diagnostics accessor is SPI.
- The env key `PER_PLAYER_SYNC_TABLES` is new and documented.

## 10. Commit plan

One PR against `main`, after F, in this order:
1. the share measurement on #514 (§0), and its go/no-go;
2. red tests (§5);
3. the macro's `_syncTablePerPlayerFields` (player-aware read and converter) and its expansion tests;
4. `SyncTablePerPlayerDiff`, presence, the per-player staging namespace and the commit;
5. the adapter: the two branches, recipient-order consumption, full views, the failure paths, the two clears;
6. the switch, `serverenv.py`, and the docs;
7. the Mac direction number in the PR body, then the host A/B before merge.

A solutions entry follows if the work finds a reusable trap.
