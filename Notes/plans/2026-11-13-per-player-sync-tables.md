# Per-player fields on typed per-player sync tables (#514)

**Status:** draft, for review. Step 2's PR 3 (`2026-11-10-flat-storage-step2.md` §5 and §7), which never started. Read at `main` 9bf7df61. No code before this plan is reviewed.

**Depends on:** row addressing's default flip (PR F of `2026-11-10-row-addressing.md` §9), which lands first. Section 7 lists the overlap.

## 0. Before starting: the share

#514 asks for this first: measure the share of the visibility land's sync time that per-player fields take, with the broadcast tables on. If it is small, the work stays deferred.

**What is known:**
- The visibility land's sync dominates its iteration. In #527's measurement (10 rooms, 5 players each, tables on), `syncMs` was 3702 ms and `tickMs` 902 ms over 2000 iterations.
- Its only per-player field is `entities`, a `[String: VisibleEntity]` filtered per player (`VisibilityTestLand.swift:203-206`). Every entity moves every tick, so the field is dirty on every sync.
- The broadcast fields (`viewers`, `motion`, `viewEntries`, `viewExits`, `tickCount`) are small, and they are already on the tables.

**The measurement:** a sampled profile of `EncodingBenchmark --game-type visibility-test --rooms 10 --players-per-room 5 --parallel false`, release, on the Mac, to get the direction. It buckets sync time into:
- (a) the filter closure itself;
- (b) per-player conversion: `extractPerPlayerSnapshot` → `SnapshotValue` for each entity the player sees;
- (c) the per-player tree diff (`computePerPlayerDiffFromSnapshot` → `compareSnapshots`) and staging;
- (d) encoding and everything else.

This plan removes (b) and (c), except the conversion of changed leaves. (a) stays, because the closure is the land's own code.

**Stop rule:** if (b) + (c) is under 15 % of vis sync time, report it and keep #514 deferred. The result goes on #514 either way.

## 1. Scope

**Root fields whose policy is player-dependent.** That means every root field the per-player part of `snapshotForSync` handles today (`StateNodeBuilderMacro.swift:583-586`: policy neither `.broadcast` nor `.serverOnly`):

| Policy | Today | Under this plan |
|---|---|---|
| `.perPlayer(f)` | filter per player on the native value, convert the whole output, tree diff | filter per player on the native value (unchanged), typed diff of the output against that player's last-sent |
| `.perPlayerSlice()` | the same (a `.perPlayer` closure reading `value[playerID]`) | the same as `.perPlayer` |
| `.custom(f)` (deprecated, #198) | the same, arguments swapped | the same as `.perPlayer`, until #198 removes it |
| `.masked(f)` at the root | in the per-player part: `filteredValue(for: playerID)` gives `mask(value)` for every player | the same as `.perPlayer`: one last-sent per player. Sharing one masked value across players is a possible later optimization. Root `.masked` is used only in tests. |
| an unrecognized policy (`.unknown`) | per-player part | a per-player fallback field (below) |

**Field kinds** are resolved exactly as for broadcast fields, through `SyncTableField.make`'s overloads (`SyncTables.swift:73-142`): node map, node, optional node, value, or fallback. The filter's output has the field's type, so the same kind applies.

**Fallback per player:** today's path, kept for that one field and that one player. The field's output is converted to `SnapshotValue` and diffed against the player's cached `SnapshotValue` of that field. This covers:
- unknown policies;
- a field whose node type has player-dependent nested fields (`N.hasPlayerDependentSyncFields`, `SyncTables.swift:218`);
- the shapes the broadcast side sends to the fallback.

**Not in scope:**
- Nested player-dependent policies below a broadcast root field. They stay as the broadcast side handles them: the node takes the fallback.
- Row addressing for per-player rows (section 7).
- Row-level visibility (step 2 §6).

## 2. What changes in the diff path

**Today, per sync** (`TransportAdapter.extractSyncSnapshots`, 5012-5083, with the tables on):
1. Deduplicate the recipients by player (`seenPlayers`).
2. Per player, run `extractPerPlayerSnapshot(for:from:mode: .include(perPlayerFields))`. For each per-player field it calls `filteredValue(native, for: playerID)` and converts the whole output to `SnapshotValue`. It covers **every per-player field of every player**, dirty or not.
3. If any field throws, the separate per-field extraction takes over and drops only that field (the one-pass rule, `Notes/solutions/2026-11-10-a-rewritten-extraction-must-keep-the-empty-result-rule.md`).
4. Per recipient (session), `generatePerPlayerUpdateFromSnapshot` (or `generateUpdateFromBroadcastDiff` for the combined JSON frame) diffs that snapshot against `staged.perPlayer[player] ?? lastPerPlayerSnapshots[player]` with `compareSnapshots`, then stages the new snapshot.

**Under this plan, per sync:**
1. Deduplicate by player, as today.
2. Per player, per per-player root field: `out = filteredValue(native, for: playerID)`. The call and its input are unchanged.
3. Diff `out` against that player's last-sent box for the field, with the broadcast tables' differs (`SyncNodeMapDiffer.diffRows`, `SyncNodeDiffer`, `SyncValueDiffer`, `SyncEquatableDiffer`). A changed leaf is converted to `SnapshotValue`. Nothing else is converted.
4. Stage the writes per (player, field) in the plan's `SyncTableStaged`, beside the broadcast staging.
5. Per recipient: the per-player patches of its player become its update, as `generatePerPlayerUpdateFromSnapshot` builds it today. That is `.noChange` when there are no patches, and the combined JSON frame merges broadcast and per-player patches with `mergePatches`.

**What the visibility land saves per player per sync:** the `SnapshotValue` build of every visible entity, the tree diff of the whole map, and the snapshot copy staged per player. What it still pays:
- the filter (the land's closure);
- a typed compare of each visible entity's synced fields (`id`, `position`);
- the conversion of the `position` values that changed.

**Kept exactly as today**, since the gate is byte identity:
- **The empty-result rule.** A state with no per-player fields produces no per-player entry at all, so no update is planned. This rule is the reason for the 11-10 solutions entry.
- **Throwing conversions.** A field whose conversion throws for a player gets no patches for that player, and its last-sent for that player isn't advanced. The drop is counted in `ExtractionDrops` as the separate extraction counts it. The one-pass all-or-nothing fallback has nothing left to fall back from: the typed path is already per field. The differential test pins equality with today's output, counts included.
- **Patch order.** Every state-update encoder sorts each frame's patches by the land's canonical order before planning or encoding them (`CanonicalFrameOrder`, set at registration, TA 1262 and 1291), so the typed diff's emit order can't change bytes. The frame identity tests check it rather than assume it.
- **Key reset.** `typesFirstSync` → `keyScopeResetUpdate`, unchanged.

**Decision D1, for review: honor the dirty marks for per-player fields.** Today every per-player field of every player is extracted and diffed on every sync. Under the documented contract the filter is a pure function of (value, player). So a clean field's output equals last-sent, and diffing it emits nothing. The tables could therefore skip clean per-player fields, as they skip clean broadcast fields. The gain:
- the card game and the cookie demo (`.perPlayerSlice` maps that change rarely);
- the per-player fields of any land, whenever only broadcast fields changed.

The visibility land's `entities` is dirty on every sync, so it gains nothing. A skipped field is still diffed:
- when its player is new or resynced (seeding, section 3);
- when it is in the retry set after a drop;
- whenever dirty tracking is off.

**Recommended: yes.** The risk is an impure filter (one that reads state outside its arguments), which would then stop updating until its field changes. #199 is the place for such filters, and it already notes this dependency. Bytes stay identical under the contract, and the identity tests run with dirty tracking on and off.

## 3. Storage, seeding and the lifecycle

**Last-sent per player:** a new `SyncTablePerPlayerDiff<State>`, held by the adapter next to `broadcastTables`. For each player that has been synced, it keeps one typed box per per-player root field (`[K: N]`, `N`, `N?`, `V`, or a fallback `SnapshotValue`). These are the same box types as the broadcast `SyncRootSlot`s (`SyncTables.swift:1065-1346`), keyed by `PlayerID`.
- **Not slot-addressed.** The boxes are built without a path cursor, so the slotted `diffRows` never tags a row (`isSlotAddressed { cursor != nil }`, 1172). No per-player patch carries a row split. Section 7 explains why this matters once F is in.
- **No splits on per-player patches.** Today they carry none, and the opcode encoders split their paths themselves. A cursor that gives splits without row tags would be a third mode of the differ. It is left for later, if the numbers show path splitting matters.

**Staging and commit:**
- `SyncTableStaged` gains the per-player writes, `[PlayerID: per-field staged writes]`, and a set of per-player seeds.
- `commitSyncPhase` applies them with the broadcast part (`broadcastTables?.apply(plan.stagedTables)`, `TransportAdapter.swift:4229-4230`).
- A failed plan discards them with the rest of `stagedTables`.

**Where today's per-player cache is read and written, and what replaces each.** SE = `SyncEngine.swift`, TA = `TransportAdapter.swift`. This is the per-player half of step 2 §4's table:

| Today | Under the per-player tables |
|---|---|
| Per-player diffs read `staged.perPlayer[p] ?? lastPerPlayerSnapshots[p]` (SE 778-830) and write it through `applyStaged` (SE 94-103) | The player's staged boxes, or else its committed boxes. They are staged and applied with the broadcast tables |
| A full view (late join, resync) re-stages `staged.perPlayer[id] = extractPerPlayerSnapshot(.all)` (TA 4669) | Stage a seed of that player's boxes from the same state copy. The broadcast tables are untouched |
| The late-join view fills a dropped field from the caches (SE 1508-1534) | That field of the player's box, converted to `SnapshotValue`. This is what the client was last sent, as today |
| A per-player encode failure drops `plan.staged.perPlayer[p]` and the firstSync mark (TA 4934-4940) | Also drops that player's staged per-player writes and seed |
| `clearCacheForDisconnectedPlayer` (SE 1186-1189), from the last session's leave (TA 1593, outside a turn, in the same segment as the `sessionIDs(for:)` check) and from supersede (TA 1973) | Also clears the player's boxes, at the same two call sites and in the same segment. The clear is by player and is guarded by the same "no other session" check, so it can't clear a re-joined player's boxes (`Notes/solutions/2026-11-05-callback-outlives-its-instance-clears-by-key.md`) |
| `cachedPerPlayerSnapshot` (SE 116), read by `SyncOutputShadow` | Unchanged: the shadow runs its own engine |
| `cachedPerPlayerSnapshotForTesting` | With the per-player tables on, returns the player's boxes converted to a `StateSnapshot` |

**A debug assertion** pins that nothing on the sync path reads `lastPerPlayerSnapshots` while the per-player tables are on, as `broadcastCacheRetired` does for the broadcast cache (SE 49-55).

**Players with several sessions.** The diff runs once per player. Today's output is kept exactly: the update loop runs per recipient (TA 5122-5200), and a later session of the same player diffs against what the first session just staged. In a normal sync that later session therefore gets `.noChange`. Newest-wins (#92) normally leaves one session per player, so this rarely arises.
- This PR keeps that output, and a frame identity case pins it.
- **Decision D4, for review:** whether that is a bug, which would be a separate issue. It isn't changed here, because this PR's gate is byte identity.

## 4. The opt-out switch

**Decision D2, for review: one PR, on by default, with an opt-out.** The alternative is step 2's pattern of a switch defaulting off and a separate flip PR. A single PR fits because:
- the runtime it uses (the differs, boxes and staging) is the broadcast tables', which are already the default;
- the gate is byte identity against today's path in the same run;
- the host A/B can then measure base against head on defaults, as #523's and #527's did.

**The switch:**
- A package env key `PER_PLAYER_SYNC_TABLES`, default on, read through `getEnvBool` as `USE_SYNC_TABLES` is (`TransportEnvConfig.swift:12, 86-90`).
- A config property, plus the `@_spi(Diagnostics)` accessor for equivalence tests in other packages.
- **Decision D3:** the key's name. It is an additive env key, as before.
- **Its effect** depends on the broadcast tables:
  - with `USE_SYNC_TABLES=false`, the per-player tables are off too;
  - row addressing forces the broadcast tables on (TA 1252), but not the per-player tables;
  - with `PER_PLAYER_SYNC_TABLES=false`, per-player fields take today's path. That is exactly today's code, so the switch is a rollback, not a second implementation.
- **CI:** the existing `build (sync tables off)` job covers off/off. A new matrix entry runs the Transport and NIO test targets with `PER_PLAYER_SYNC_TABLES=false`, the tables-on, per-player-off combination. The frame identity tests toggle all three combinations in process anyway.
- **Docs:** the env table in `docs/transport` and its zh-TW companion.

## 5. Tests

**Red first:**
- the differential test and the frame identity cases below, with the per-player tables on;
- the "nothing reads `lastPerPlayerSnapshots`" assertion;
- a pin that a state with per-player fields doesn't take the snapshot path for them (a counting hook on `extractPerPlayerSnapshot`, test-only).

**Differential (engine level):** random mutation sequences, at least 10 000 steps per state type, with the seed printed on failure. It compares the per-player typed diff against `computePerPlayerDiffFromSnapshot`, per player, as logical patch lists in canonical order. The states:
- `VisibilityTestState` (radius and all filters);
- the `NestedNodePolicyTests` roots (`.perPlayer`, `.perPlayerSlice` and `.masked` root maps, nested `.serverOnly`);
- `DirtyIdentityState` (`.perPlayerSlice`);
- a state with an unknown policy (the fallback per player).

Cases:
- a player's output gaining and losing keys (entities entering and leaving view): sets and deletes;
- an output going empty and coming back;
- nil ↔ value for an optional node output;
- NaN / −0.0 in an output value;
- a field whose conversion throws for one player only: that player's patches, its last-sent and the drop count match today's, and the other players are unaffected;
- a failed plan, after which the next plan's patches equal today's;
- NFC and NFD forms of one key;
- players added and removed between steps (seeding, clearing).

**Frame identity (adapter level, every encoding, per recipient, exact bytes, frame counts first):** extend the existing tables-on/off identity tests with a third configuration (broadcast tables on, per-player tables on) against today's path:
- `Examples/GameDemo/Tests/SyncTablesFrameIdentityTests.swift`: visibility radius and all; the broadcast twin, which has no per-player fields and so checks the empty-result rule; the card game (`hands`, `.perPlayerSlice`); Hero Defense, which has no per-player fields.
- `Examples/Demo/Tests/DemoContentTests/SyncTablesFrameIdentityTests.swift`: the cookie game (`privateStates`).
- `Tests/SwiftStateTreeTests/SyncTablesLandCellTests.swift`: the shape matrix (no per-player fields) and the nested-policy land.
- `Tests/SwiftStateTreeTransportTests/SyncTablesByteIdentityTests.swift`: across encoding × dirty × onePass × schema.

Each run includes (step 2 §8's list):
- joins mid-run;
- a forced resync;
- a forced key reset (`syncPlanFaultForTesting`, and an encode drop);
- a throwing per-player conversion with a late join right after;
- a disconnect and reconnect;
- a supersede;
- a player with two sessions, pinning today's output (section 3).

**Unchanged outputs:**
- verify-views;
- the sync-output goldens;
- the replay state hash;
- a recorded run with the per-player tables on verifies against `SyncOutputShadow` with 0 mismatches (the visibility record, as #523's E2E leg does).

**With row addressing in effect** (after F): per-player frames hold no row entry (no ops 6–9), and bytes are equal with the per-player tables on and off.

**Mutants**, each killed by a named test:
- skip the seed on resync;
- share one last-sent box across players;
- give per-player patches a row tag;
- advance last-sent for a dropped field;
- skip the disconnect clear;
- diff a clean per-player field's output against an empty box (an over-eager D1);
- drop the empty-result rule.

## 6. Measurement (host A/B under the off-path instruction gate)

`2026-11-13-off-path-instruction-gate.md` applies: off-path work is judged by windowed `instructions:u`, and sync, which is this change's path, by time. The host brief is drafted from this section once the PR has a head.

**Base:** `main` at run time, with F merged. **Head:** the PR merged with that main. Both run on defaults.

| Cell | Command (common flags as #527's: messagepack-pathhash, 2000 iterations, `--parallel false`, `--dirty-tracking on`, `--row-addressing` pinned to the default) | Sync time (`syncMs`) | Off-path instructions |
|---|---|---|---|
| `vis-tick` | `--game-type visibility-test --rooms 10 --players-per-room 5` | judged: the main beneficiary. #514's gate is "no more than 5 % above today's"; a gain is expected | judged (`ticks` window) |
| `vis-p16` | `--game-type visibility-test --rooms 2 --players-per-room 16` (the land's `maxPlayers`) | judged: per-player cost grows with the player count | judged (`ticks` window) |
| `vis-broadcast` | `vis-tick` with `VISIBILITY_TEST_FILTER=broadcast` (no per-player fields) | judged, control: within the bar | judged |
| `cap100-local` | `--game-type hero-defense --rooms 1 --monster-cap 100` (no per-player fields) | judged, control: within the bar | judged (`nonsync` window) |

- **Sync bar:** head's mean above base's by more than max(2 %, base's spread) is a SYNC REGRESSION. A gain is head's mean below base's min.
- **Off-path bar:** the gate plan's rule, max(0.5 %, 3 × base's spread) on instructions. Time is reported beside it, with "layout move (#517)" where time moves and instructions don't. No tick code changes, so the expectation is within the bar everywhere.
- **Bytes and digests:** identical in every cell, base = base again = head, as in #527's capture pass.
- **The opt-out, in the capture pass:** head with `PER_PLAYER_SYNC_TABLES=false` must give base's bytes and digests too.
- **Repeats:** ABBA, one warm-up pair and 5 pairs per cell, for both the timed set and the perf set. The perf set runs with `SWIFT_DETERMINISTIC_HASHING=1` and the FIFO window (`--tmpfs /perfctl`), in the standing container scope.
- **The summary script** needs the gate plan's script changes (its open item). The A/B script for this PR includes them, with the gate plan's synthetic cases plus this PR's (a capture with the opt-out side).
- **Before the host:** a Mac direction number on `vis-tick` (ABAB, switch on against off). If sync time doesn't fall, stop and report before the host set.

## 7. Overlap with row addressing's default flip (F)

F flips `rowAddressing` on by default, and it lands first. Where it meets this plan:
- **Row entries are encoded for any tagged patch, whatever its key scope.** `RowEntryPlan.plan` takes a patch that has `split.row` and one dynamic key (`RowEntryPlan.swift:44-110`), and both opcode encoders apply it whatever the scope (`OpcodeJSONStateUpdateEncoder.swift:289-291`, `OpcodeMessagePackStateUpdateEncoder.swift:227-228`). A per-player patch with a row tag would therefore be written as a row entry in the broadcast table's slot space. Every client would apply it to the wrong table.
  - So the per-player boxes are not slot-addressed and carry no splits (section 3).
  - A test runs with row addressing in effect (section 5), and a mutant adds the tag.
- **Per-player slot spaces** (`2026-11-10-row-addressing.md` §5: a slot space per (player, table), told apart by `tableId`) are a follow-up, not part of #514. Per-player node maps keep today's entries.
- **Shared files:**
  - `TransportAdapter.swift`: `planSyncPhase`, the full-view paths (`planFullViewUpdate`, `lateJoinSnapshot`), and the encode-failure and row-drop handling;
  - `SyncTables.swift`: `SyncTableStaged`;
  - the frame identity tests, whose defaults F changes;
  - EncodingBenchmark's `--row-addressing` default.

  This PR branches from `main` after F merges, and pins `--row-addressing` in the brief.
- **F's full-view rule** (row addressing §4: a full view takes the staged or the committed table by recipient) concerns the broadcast tables. A per-player full view seeds the player's own boxes from the same state copy, so the two don't interact. The frame identity cases with a join and a resync run with row addressing in effect.

## 8. Related issues

- **#198** (remove `.custom`): handled like `.perPlayer` until then. Removing it touches the policy table in section 1 only.
- **#192** (one frame per sync for per-player lands): unaffected. Frame count and frame kinds are unchanged.
- **#130** (an independent per-player view oracle): the differential test here compares against today's engine, not an independent oracle, so #130 stays open.
- **#199** (policies that read the root state): D1 depends on the filter's purity. A root-state policy would need its field marked dirty by the fields it reads, as #199's constraints already say.
- **#314** (hash-seed-independent patch order): the frames are canonically ordered (#435). The typed differ's order is canonical by construction.
- **#524** (`PlayerHandle`): the boxes are keyed by `PlayerID`. A handle would key them by slot later.

## 9. Public API

None. `SyncTablePerPlayerDiff` and the config property are package-level, and the Diagnostics accessor is SPI. The env key `PER_PLAYER_SYNC_TABLES` is new and documented (D3).

## 10. Commit plan

One PR against `main`, after F, in this order:
1. the share measurement result on #514 (section 0), and its go/no-go;
2. red tests (section 5);
3. `SyncTablePerPlayerDiff`, staging and the commit;
4. the adapter: extraction, the update loop, full views, failures, disconnect;
5. the switch and docs;
6. the Mac direction number in the PR body, then the host A/B before merge.

A solutions entry follows if the work finds a reusable trap.
