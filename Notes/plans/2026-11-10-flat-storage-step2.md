# Flat storage step 2: typed sync tables behind today's API

Status: design, for review. Step 2 of `2026-11-10-flat-state-storage.md` (section 12). Step 1 passed the stop bar: X = 89.9 % on cap100 (draft PR #439, never merged; joint 88.3 %, cap500-idle 96.8 %; the iteration totals are 62 / 50 / 76 %). The code builds on the canonical emit order (#435) until that merges. Read at `origin/main` 43a9f28c and `feat/canonical-emit-order` 7bcfa4e9.

**One proposal here changes how decision 10.1 is realized, and it is marked as a decision.** The land author's API stays as decided. What moves is where the tables live: they are the sync side's typed state, not the live storage (section 1). The rest follows the decided plan.

## 1. Where the tables live: a decision for the maintainer

The parent plan's option 1 makes the tables the live storage, with `state.monsters` a view over them. Two facts from the code and from step 1 argue for keeping the live state as it is, and putting the tables on the sync side.

**1. The land code needs the exact native types, not something shaped like them.** GameDemo passes node maps as plain dictionaries:
- `CombatSystem.processPlayerShoot(player: inout PlayerState, monsters: inout [Int: MonsterState])` (`CombatSystem.swift:94-96`), called as `&state.monsters` (`HeroDefenseLand.swift:62, 140`);
- `findNearestMonsterInRange(monsters: [Int: MonsterState])` and `TurretSystem.isValidTurretPosition(existingTurrets:)`, taking the map by value (`CombatSystem.swift:44`, `TurretSystem.swift:13`);
- standalone `[Int: MonsterState]` values in unit tests (`CombatSystemTests.swift`, `TurretSystemTests.swift`), and `MonsterSystem.spawnMonster` returning a `MonsterState`.

A view type is not a `[Int: MonsterState]`. To keep these call sites compiling, every access would have to materialize the whole dictionary, and every write-back would compare it whole: one materialization per `state.monsters[id]` access, several per tick. The parent plan's fallback (section 3) still pays one O(n) compare per access.

**2. Step 1 measured exactly the other layout.** The bound kept the native structs as the source of truth. It compared them into typed tables (`mirror`), diffed the tables against last-sent buffers, and encoded from them:
- X ≈ 90 % on the sync span;
- the compare cost 6–22 µs per walk (cap100 to cap500).

Nothing in step 1 measured live-table storage.

**Proposal:**
- The live state stays native `@StateNodeBuilder` structs. Land code, helpers and tests don't change at all.
- Each sync walks the live state of the root fields marked dirty. It compares each row against typed last-sent tables, emits typed patches in canonical order, and stages the updated rows for the commit.
- `SnapshotValue` trees, the tree diff and the path splitting (buckets A, B and C) leave the hot path, which is where step 1's gain came from.

**What this gives up**, compared with live tables:
- **Dirty-row marks:** a dirty root field is walked row by row. Writes don't mark rows, since `@Sync` marks only its root field, and a nested write goes through the root's `_modify`. The walk is typed compares, measured above at 6–22 µs.
- **Tick-side copy-on-write savings:** the stage 0 profiles show the native dictionary copy in Hero Defense's tick. That cost is outside stage 1's bar (sync), and this design doesn't change it either way.

**Alternative:** the parent plan's live tables. They need:
- the view type;
- the materializing `_modify` for exact-type call sites;
- a separate measurement of the tick, since step 1 didn't cover it.

They also reopen section 3's costs. Recommended: the sync-side tables. Live tables stay possible later. The sync tables, typed patches and encoder path below are the same in both layouts, so nothing here is wasted if the decision goes the other way.

Everything below assumes the proposal.

## 2. The tables

**Per node type: one table per occurrence.** An occurrence is a root field, or a nested node field, of that type. There are two kinds:
- **broadcast tables**, shared by every recipient;
- **per-player tables** (section 5).

**Rows.** Each row has:
- **its key chain:** the dynamic keys from the root, as today's paths have them, stored as strings, with the canonical-order key precomputed (`CanonicalPatchOrder.Template`);
- **a last-sent copy of the node struct** (an array of structs, owned by the table and never shared with the live state, so no copy-on-write ever triggers on the live side);
- **metadata:** alive, seen-epoch, and the reserved visibility slot (section 6);
- **a key index:** key chain → row.

Freed rows are reused, lowest index first. Row indices never reach the wire, so reuse is safe (section 6 of the parent plan).

**Per-field compare.** The macro generates one static function per node type:

```swift
static func _syncDiff(_ new: Self, _ old: Self, into out: inout SyncFieldMask)
```

It compares each synced field with typed `==` and sets that field's bit. `.serverOnly` and `@Internal` fields are skipped. Field bits are the rank in UTF-8 name order, the same as `FieldMergeTable`'s merge bit and the canonical order's field order.

**Equality must match today's diff:**
- **Float and Double:** compare as `SnapshotValue.sameValue` does, including NaN and -0.0. The generated compare calls a shared `_syncSame` helper with overloads per primitive type, and each overload's semantics is tested against `sameValue`.
- **Atomic values** (`@SnapshotConvertible(atomic: true)`) are compared and sent whole, as today.
- **Non-atomic structs, maps of values and arrays:** handled by the field kinds below.

## 3. The macro mapping, per shape

**How kinds are resolved: by the compiler, not by a cast.** The macro emits one registration call per field:

```swift
_syncField(\Self.x, ...)
```

Overload resolution then picks the shape from the field's static type:
- `[K: V] where V: StateNodeProtocol`;
- `V?` where V is a node;
- `V: StateNodeProtocol`;
- `[K: V]` for any other V;
- the generic value case.

A typealias resolves correctly, unlike today's text parsing (parent plan, fact 4). `Notes/solutions/2026-11-06-protocol-extension-default-wins-overload-resolution.md` shows how overload ranking can surprise, so the shape tests in PR 1 check, for every shape below, which overload was picked.

**Shape table.** The counts are from `origin/main`: Examples and Sources, with tests in brackets.

| Shape | Where it is used | Mapping |
|---|---|---|
| Scalar or atomic value | everywhere | A field of its row. Typed compare, value sent whole. |
| Non-node struct (`@SnapshotConvertible`, `StateProtocol`) | `Viewer`, `PlayerHand`, `CardGamePlayerState` | A field of its row. Compared with `==` when `Equatable`. The changed field is then diffed per entry by today's `compareSnapshotValues` on that field's `SnapshotValue` only, which keeps today's per-entry patches. |
| `[K: Value]`, `[Value]`, `Set<Value>` | ~75 maps, ~25 arrays | As non-node structs: `==`, then today's per-entry diff for the changed map (per key). Arrays and sets are sent whole, which is today's semantics (`SyncEngine.swift:411-416`). |
| Node held directly | `HeroDefenseState.base` | A child table with one row and the empty key chain component (`""`, as in the canonical chain). |
| Optional node | [tests only, 9] | A child table with zero or one row. nil → value creates the row (set of the whole node); value → nil removes it (delete), as today. |
| `[K: Node]`, K = String, Int or PlayerID | `monsters`, `players`, `turrets`, `entities`, Cookie | A child table keyed by the key's string form, which is today's path component. Rows are created, compared or removed by walking the live map against the key index with a seen-epoch (as in step 1's bound). |
| `[Node]` | [tests only, 7] | Today's semantics: the array is one value, sent whole on any change. So it is a value field (generic case) that compares the array with `==` and converts it to `SnapshotValue` only when it changed. |
| Nested node collections: `[Int: [Node]]`, `[PlayerID: Node?]`, `[[Node]]?`, `Set<Node>` | [tests only, 3+1] | The fallback field (below). |
| Enum, including one with a node payload (`NodeChoice`) | [tests only, 1] | The fallback field. |
| Node inside a non-node struct | [tests only] | The fallback field. |
| `ReactiveDictionary` / `ReactiveSet` | no state field | The fallback field. Their own tests are unchanged. |

**The fallback field** is today's path, kept for that one field: extract its `SnapshotValue` (`SnapshotValue.make`), diff it against its own cached `SnapshotValue` with `compareSnapshotValues`, and emit `StatePatch`es with paths. It is correct for every shape today's engine supports, and costs what that field costs today. It is the safety net for shapes no land uses on the hot path.

**Two more rules decide the field kind:**
- **Nested policies:** a node type whose subtree holds a player-dependent policy below its root field (`NestedNodePolicyTests`) is mapped as a fallback field in the per-player part. The broadcast/serverOnly nesting that Examples use (`MonsterState`'s serverOnly fields) is a typed row. `SyncPolicyNesting.validate` is unchanged.
- **Unknown policies** (a named `SyncPolicy` constant, recorded as `.unknown`) take the fallback.

**What the macro adds:**
- `_syncDiff`;
- the field registration list;
- `static let _syncTableSchema` (field names, bits, policies, the kind chosen by overload).

**What it keeps:** every member it generates today. `snapshot(for:)`, `fullStateSnapshot()` and `snapshotForSync` stay for firstSync, resync, the fallback field, the replay hash and the verifier oracle (section 4). Nothing is removed in step 2.

**`.perPlayer` whole-field contract:** section 5.

## 4. The sync cycle, firstSync, resync, key reset, recording, the "off" switch

**Normal cycle** (both paths: in-turn on the keeper's live state, legacy on `beginSync`'s copy):
- For each root field marked dirty (`planDirtyFields`, carried fields included), walk its tables in canonical order: tables by number, rows by key bytes, a row's own patch before its fields.
- **Typed rows:** compare against last-sent and emit typed patches (below). A created row is a set of the whole node, as today. A removed row is a delete.
- **Fallback fields:** today's extraction and diff for that field. Their patches are merged into canonical order with the others.
- **Staging:**
  - Updated rows go into a staged list `(table, row, new struct)`, with created and removed rows.
  - `applyStaged` writes them at commit, as `StagedCaches` does today (`SyncEngine.swift:66, 75`).
  - A failed plan leaves last-sent untouched, and its dirty fields are carried as today (`TransportAdapter.swift:3480`). The 11-04 rules hold.
- **No `SnapshotValue` tree and no tree diff,** except in fallback fields.

**Typed patches** carry the address the encoder needs: the pattern hash (the path index) and the dynamic keys, plus the operation and the value.
- The value is the changed field's `SnapshotValue`, built per changed leaf field only, never a tree.
- The MessagePack and opcode JSON encoders take the split from the patch: `FieldMergePlan.splitsAndEntries` already takes `splits` as input, so `PathHasher.split` (bucket C) isn't called.
- A path string is built from the pattern and keys only where it is needed:
  - the JSON object encoding;
  - the sync-stream digest while recording (10.4 (a));
  - logs.
- The patches come out of the walk already in canonical order. The encoder's sort stays as a safety net, with a sorted-input fast path: one linear check, then no sort.

**firstSync and resync** stay on today's path: `lateJoinSnapshot` and the diff from empty, through the same encoders. They run once per join or resync, not per sync, and keeping them leaves the full-view bytes byte-identical by construction.
- The new part is the seeding. When a recipient is first synced, the broadcast tables are seeded from the same state copy if they are empty (the shared broadcast tables are seeded once, like today's `lastBroadcastSnapshot`, SE:1491). That recipient's per-player tables are seeded too.
- A resync re-seeds that player's per-player tables, as today's `.all` per-player cache is restaged (TA:4210-4216). The broadcast tables are untouched.
- The staged-cache removal on an unsent resync (TA:4436-4450) covers the seeded tables.
- Disconnect and supersede clear the player's tables (`clearCacheForDisconnectedPlayer`).

**Key reset** (`keyScopeResetPending`, `resetsKeyScopes`): no change.
- A reset re-types the frame as `.firstSync` over the normal diff patches (TA:4224, 4268), and the encoders reset their key tables on `forceDefinition`.
- The typed patches are encoded through the same call, so a reset works exactly as today. Step 1's gate didn't exercise it; the gates here do (section 8).

**Recording and replay:**
- **Sync-stream digest:** while recording, the typed patches are converted to `StatePatch` with paths for `CanonicalPatchList` (10.4 (a)). No format change.
- **Replay verifier:** `SyncOutputShadow` keeps running today's `SyncEngine` (`SyncOutputVerifier.swift:249`). It becomes an independent oracle for the typed diff: a recorded run whose live sync used the tables must verify against the old engine's output.
- **Replay state hash** (`fullStateSnapshot`, `liveStateHash`) and **`ENABLE_STATE_SNAPSHOT_RECORDING`:** unchanged, since the live state is unchanged.

**Dirty tracking "off" (10.5, permanent, package-level):**
- "Off" walks every root field each sync, ignoring the root marks. It yields the same patches as "on", which is what the byte-identity check needs. "On" skips clean root fields.
- `ENABLE_DIRTY_TRACKING` keeps working.
- The auto switch (`maybeAutoSwitchDirtyTracking`, #391's sampling) is removed in PR 4.
- The change count becomes the number of rows with a nonzero mask plus the fallback fields' changed objects. No sampling is needed.

**`syncStrategy: .fullSnapshot` and `USE_SNAPSHOT_FOR_SYNC`:** `.fullSnapshot` (debug and compatibility) and the snapshot-extraction switch keep today's path. The tables serve `.delta` only.

## 5. Per-player policies

**`.perPlayer` and `.custom`** keep the whole-field contract:
- The closure runs once per player on the whole native field value, exactly as today. No materialization: the native dictionary is already the input.
- Its output, a value of the field's type, is walked against that player's per-player tables with the same typed compare. A node map's output gets per-player row tables, keyed like the broadcast ones.
- The visibility test's `entities` (`VisibilityTestLand.swift:203`, a filter over the whole map) is this case.

**Gate (section 11 of the parent plan):** vis sync no more than 5 % above today's. The expected saving is the `SnapshotValue` build and tree diff of each player's output.

**`.perPlayerSlice()`:** a `.perPlayer` closure that reads `value[playerID]`. It maps as above. A later optimization may key it directly, but not in step 2.

**`.masked`:**
- A broadcast field whose value is transformed once per extraction (SyncPolicy.swift:65-72).
- The transform runs on the field's value when the root field is dirty. The result is compared like any field.
- A masked node (`NestedNodePolicyTests.swift:488, 506`) takes the fallback.

**Players with several sessions** keep today's deduplication (TA:4517-4518): the tables are per player, the frames per session.

## 6. The visibility slot (10.7, reserved only)

Every row carries a `UInt32` visibility slot, with 0 meaning "inherit the field's policy". Step 2 never reads or writes another value. Stage 2's object-level permission API (for example `ownerOnly` on a node type) fills it at row creation and filters per row in the walk, without changing the table layout or the patch path.

## 7. Commit plan

Four reviewable PRs, each targeting `exp/next`, branched from the canonical-order branch until #435 merges. Each PR keeps today's path as the default until PR 4.

1. **Tables and typed diff, unused by the adapter.**
   - The overload-based field registration;
   - `_syncDiff` and `_syncTableSchema` from the macro;
   - the table runtime (rows, key index, staging, seeding);
   - the typed patch, with its conversion to `StatePatch`;
   - the fallback field.

   Tests:
   - macro expansion tests;
   - per-shape overload tests (section 3);
   - a differential test: the typed diff against today's `SyncEngine` on random mutation sequences over `ShapeMatrixState`, `HeroDefenseState`, `VisibilityTestState` and the `NestedNodePolicyTests` and `FullStateHashTests` states. It compares logical patch lists in canonical order, including create, remove, nil ↔ value, and NaN / -0.0.
2. **The adapter's broadcast diff on the tables,** behind a package switch (default off).
   - The typed patches feed the three encoders: MessagePack and opcode JSON take the splits directly, JSON builds paths.
   - Staging, failed plans, key reset, the digest path while recording, firstSync seeding, disconnect cleanup.
   - Per-player fields stay on today's path in this PR.
3. **Per-player policies on the tables:** `.perPlayer`, `.custom`, `.perPlayerSlice`, `.masked`, resync re-seeding, multi-session players. Still behind the switch.
4. **The default flips to the tables.**
   - The auto dirty switch is removed, and "off" stays as the package switch.
   - The change count comes from rows.
   - Today's path stays reachable for `.fullSnapshot`, the fallback field and the verifier oracle.

   The stage 0 harness numbers go into this PR.

## 8. Gates per PR

**Every PR:**
- `swift test` (full) and CI green;
- E2E for every encoding;
- `ts-sdk` and `ws-loadtest` checks;
- Review GO.

**PR 1:**
- The differential test passes over at least 10 000 random steps per state type, with a seed printed on failure.
- The per-shape overload checks pass.
- Every expected kind in section 3's table is asserted.

**PRs 2 and 3, with the switch on and off in the same run:**
- **Frames byte-identical:** an exact per-recipient comparison in every encoding, as in #435's `DirtyTrackingByteIdentityTests` (5 processes). Cells: Hero Defense (cap100, joint), the visibility land, the shape matrix land, and the nested-policy land. The run includes:
  - joins mid-run (firstSync);
  - a forced resync;
  - a forced key reset: a failed plan injected with `syncPlanFaultForTesting`, and an encode drop;
  - a disconnect and reconnect.
- **Unchanged outputs:**
  - verify-views;
  - the sync-output goldens and their re-recorded record bytes;
  - the shape matrix, atomic-array-shapes and field-merge fixtures;
  - the replay state hash.
- **Recording on:** a recorded run with the switch on verifies against `SyncOutputShadow` (today's engine) with 0 mismatches.
- **PR 3 only:** the vis sync time gate (≤ +5 %), stage 0's harness, Mac for direction, the host for the number.

**PR 4:**
- **Stage 0's harness, host:** cap100 sync time at most 50 % of today's (X ≥ 50 %; step 1 bound 89.9 %, so this allows for the generic code keeping 0.56 of the bound's saving).
- **Tick:** joint and cap500-idle reported with tick next to sync, and the tick no more than 3 % above today's. No tick work is added; this checks it.
- **Recording on:** the cost with recording on is reported (10.4 (a)).
- **Bytes:** all cells' bytes identical to the canonical-order baseline.
- **Drain:** the measurement uses a drain that doesn't sleep between spans (`Notes/solutions/2026-11-10-a-sleep-between-timed-spans-slows-the-next-span.md`), on both sides, once the open host check on that harness is decided.

## 9. Not in step 2

- Wire changes: row addressing and wire IDs are step 3. This design keeps today's dynamic keys and paths, built from the key chain.
- Live table storage (section 1's alternative).
- Removing today's snapshot path. It stays as the oracle and for full views until after step 3.
- Row-level per-player policies and the object-level permission API (stage 2).
