# Flat storage step 2: typed sync tables behind today's API

Status: reviewed (#379), section 1 decided 2026-11-10: sync-side tables. Step 2 of `2026-11-10-flat-state-storage.md` (section 12). Step 1 passed the stop bar: X = 89.9 % on cap100 (draft PR #439, never merged; joint 88.3 %, cap500-idle 96.8 %; the iteration totals are 62 / 50 / 76 %). The code builds on the canonical emit order (#435) until that merges. Read at `origin/main` 43a9f28c and `feat/canonical-emit-order` 7bcfa4e9.

**Section 1 changes how decision 10.1 is realized.** The land author's API stays as decided. What moves is where the tables live: they are the sync side's typed state, not the live storage. The maintainer chose this on 2026-11-10. The rest follows the decided plan.

## 1. Where the tables live (decided: sync side)

The parent plan's option 1 makes the tables the live storage, with `state.monsters` a view over them. Two facts from the code and from step 1 argue for keeping the live state as it is, and putting the tables on the sync side.

**1. The land code needs the exact native types, not something shaped like them.** GameDemo passes node maps as plain dictionaries:
- `CombatSystem.processPlayerShoot(player: inout PlayerState, monsters: inout [Int: MonsterState])` (`CombatSystem.swift:94-96`), called as `&state.monsters` (`HeroDefenseLand.swift:62, 140`);
- `findNearestMonsterInRange(monsters: [Int: MonsterState])` and `TurretSystem.isValidTurretPosition(existingTurrets:)`, taking the map by value (`CombatSystem.swift:44`, `TurretSystem.swift:13`);
- standalone `[Int: MonsterState]` values in unit tests (`CombatSystemTests.swift`, `TurretSystemTests.swift`), and `MonsterSystem.spawnMonster` returning a `MonsterState`.

A view type is not a `[Int: MonsterState]`. To keep these call sites compiling, every access would have to materialize the whole dictionary, and every write-back would compare it whole: one materialization per `state.monsters[id]` access, several per tick. The parent plan's fallback (section 3) still pays one O(n) compare per access.

**2. Step 1 measured a close relative of this layout, not this layout.** The bound kept the native structs as the source of truth. After each tick it compared them into typed tables (`mirror`), and at sync it diffed the tables against last-sent buffers and encoded from them:
- X ≈ 90 % on the sync span;
- the compare cost 6 µs (cap100) to 22 µs (cap500-idle) per walk, one walk per tick. #439 lists 12, 6 and 44 µs per iteration at two ticks per sync. This design walks once per sync.

Two differences are unmeasured:
- The bound's typed columns held only synced fields, and its sync visited only rows it had marked. This design keeps whole node structs as last-sent copies, `serverOnly` fields and heap-backed members included, so it adds retains, releases and copies. It also compares every row of a dirty root field inside the sync.
- The direction should hold, but the number isn't known. PR 2 therefore gets a Mac direction number (broadcast on the tables, Hero Defense cap100) before PR 3 starts (section 8).

Nothing in step 1 measured live-table storage.

**Proposal:**
- The live state stays native `@StateNodeBuilder` structs. Land code, helpers and tests don't change at all.
- Each sync walks the live state of the root fields marked dirty. It compares each row against typed last-sent tables, emits typed patches in canonical order, and stages the updated rows for the commit.
- `SnapshotValue` trees, the tree diff and the path splitting (buckets A, B and C) leave the hot path, which is where step 1's gain came from.

**What this gives up**, compared with live tables:
- **Dirty-row marks:** a dirty root field is walked row by row. Writes don't mark rows, since `@Sync` marks only its root field, and a nested write goes through the root's `_modify`. The walk is typed compares, about 6–22 µs per walk in the bound's form (see point 2).
- **Tick-side copy-on-write savings:** the stage 0 profiles show the native dictionary copy in Hero Defense's tick. That cost is outside stage 1's bar (sync), and this design doesn't change it either way.

**Alternative:** the parent plan's live tables. They need:
- the view type;
- the materializing `_modify` for exact-type call sites;
- a separate measurement of the tick, since step 1 didn't cover it.

They also reopen section 3's costs. Recommended: the sync-side tables. Live tables stay possible later. The sync tables, typed patches and encoder path below are the same in both layouts, so nothing here is wasted if the decision goes the other way.

**Decision (maintainer, 2026-11-10): sync-side tables.** The live state stays native `@StateNodeBuilder` structs, and each sync compares the rows of dirty root fields against typed last-sent tables. The reasons:
- users' code doesn't change at all;
- it is the cheaper `.perPlayer` path, since the closures already take the native value and nothing is materialized per player;
- live tables stay possible later, on the same tables, typed patches and encoder path.

Everything below assumes this decision.

## 2. The tables

**Per node type: one table per occurrence.** An occurrence is a root field, or a nested node field, of that type. There are two kinds:
- **broadcast tables**, shared by every recipient;
- **per-player tables** (section 5).

**Keys.** The key index compares keys with `String` equality (canonical equivalence), never UTF-8 bytes. That is how the native `Dictionary` and `SnapshotValue` treat NFC and NFD keys, so one live entry is one row. Only the canonical order compares bytes.

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

**Equality must match today's diff.** The reference is `SnapshotValue.sameValue`, which `compareSnapshotValues` checks first (SE 363):
- **Float and Double:** `a == b || (a.isNaN && b.isNaN)`, with -0.0 equal to 0.0. The generated compare calls a shared `_syncSame` helper with overloads per primitive type, and each overload's semantics is tested against `sameValue`. Keeping last-sent at the older of two `sameValue`-equal values is equivalent for every later compare.
- **The contract for other value types:** non-node structs, value maps and atomic types are prefiltered with the type's own `Equatable`. The contract is that, for a synced value type, `a == b` implies `sameValue(snapshot(a), snapshot(b))`.
  - A synthesized `==` meets it, erring the safe way: NaN is unequal, so the field falls through to the per-entry diff.
  - A custom `==` that ignores a field or compares with a tolerance would hide a change today's diff sends. Debug builds therefore assert the contract: when `==` says equal, the two snapshots must be `sameValue`. The differential test includes a type with a deliberately lax `==`, and checks that the debug assertion catches it.
- **A synced value that isn't `Equatable`** takes the fallback field (section 3).
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

A typealias resolves correctly, unlike today's text parsing (parent plan, fact 4).

**The runtime check at registration.** Static overloads miss three cases:
- a generic node type (`struct Box<T: …>: StateNodeProtocol { var items: [String: T] }`), whose field resolves at the declaration, so `T` gets the value overload even when it is a node;
- optional collections (`[K: Node]?`, `[Node]?`);
- non-`Equatable` values.

So the value overload also checks once, at registration, whether the field's type is or holds a node: it unwraps optionals, dictionary values and array elements, as `CanonicalPatchOrder.Builder.shape(of:)` does. A node found anywhere, or a type that isn't `Equatable`, routes the field to the fallback. PR 1's per-shape tests include all three cases. `Notes/solutions/2026-11-06-protocol-extension-default-wins-overload-resolution.md` shows how overload ranking can surprise, so the shape tests in PR 1 check, for every shape below, which overload was picked.

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
  - The key index, the free list and the seen-epoch also change only in `applyStaged`. During the plan, a created row gets a staged row index and a removed row a staged free. Take a plan that removes key A and creates key B: B's staged row may reuse A's index only in the staged view, never in the committed one.
  - A failed plan discards all of it (rows, index, free list, epoch), leaves last-sent untouched, and carries its dirty fields as today (`TransportAdapter.swift:3480`). The 11-04 rules hold.
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

**Today's snapshot caches under the tables.** `lastBroadcastSnapshot` and `lastPerPlayerSnapshots` stop advancing once the diff moves to the tables, so every reader must move with it. Each read and write maps as follows (SE = `SyncEngine.swift`):

| Today | Under the tables |
|---|---|
| The broadcast and per-player diffs read the caches (`cached`, SE 680, 754) and write them through `applyStaged` (SE 81, 84) | The tables' last-sent rows, staged and applied the same way |
| A dropped field in the per-scope extraction takes its cached value (`fallback`, SE 1413, 1435) | Typed path: that field's last-sent value, which isn't advanced (extraction drops, below). Fallback field: its own cached `SnapshotValue` |
| The late-join view fills a dropped field from `lastBroadcastSnapshot ?? lastPerPlayerSnapshots` (SE 1481-1483) | The table's last-sent row, with that one field converted to `SnapshotValue`; a fallback field reads its own cache. This is the field clients were last sent, as today |
| A first late join seeds the caches when they are empty (SE 1492-1497; the older seeding helpers at SE 513-587, 1142-1181) | Seeds the tables (firstSync and resync, above) |
| `clearCacheForDisconnectedPlayer` (SE 1155) | Clears that player's tables |
| `cachedBroadcastSnapshot` and `cachedPerPlayerSnapshot` (SE 95-102), read by `SyncOutputShadow` | Unchanged: the shadow runs its own engine, and its caches advance through its own diff |
| `cachedBroadcastSnapshotForTesting` and `cachedPerPlayerSnapshotForTesting` (`TransportAdapterSyncPhaseTests.swift:773`) | With the switch on, they return the tables converted to `StateSnapshot`, so the tests keep comparing a cache |

With the switch on, nothing on the sync path reads the snapshot caches. With it off, nothing reads the tables, and `.fullSnapshot` keeps today's caches.

**Extraction drops** (`ExtractionDrops`, SE 1332-1364). The typed path follows today's rule, per scope (broadcast, per-player, view):
- **Trigger:** a field whose conversion throws. That can be the changed leaf's `SnapshotValue`, or a fallback field's extraction.
- **Patch:** no patch for that field.
- **Last-sent:** that field's last-sent isn't advanced, while the row's other changed fields are. Staging is per field (the row's staged copy takes the new values of the fields that converted, and keeps last-sent for a dropped one), not per row.
- **Count:** the drop is noted in `ExtractionDrops` with the first error, as today.

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
   - a differential test: the typed diff against today's `SyncEngine` on random mutation sequences over `ShapeMatrixState`, `HeroDefenseState`, `VisibilityTestState` and the `NestedNodePolicyTests` and `FullStateHashTests` states. It compares logical patch lists in canonical order. The cases:
   - create, remove, nil ↔ value, and NaN / -0.0;
   - a field whose conversion throws: patches, last-sent and drop counts must match today's;
   - a type with a lax custom `==`, which the debug assertion must catch;
   - a failed plan that removes key A and creates key B, after which the next plan's patches must equal today's;
   - NFC and NFD forms of one key.
2. **The adapter's broadcast diff on the tables,** behind a package switch (default off).
   - The typed patches feed the three encoders: MessagePack and opcode JSON take the splits directly, JSON builds paths.
   - Staging, failed plans, key reset, the digest path while recording, firstSync seeding, disconnect cleanup.
   - Per-player fields stay on today's path in this PR.
   - A debug assertion that, with the switch on, nothing on the sync path reads `lastBroadcastSnapshot` (and, from PR 3, `lastPerPlayerSnapshots`), which pins the invariant in section 4.
   - **The Mac direction number, before PR 3 starts:** Hero Defense cap100, broadcast on the tables, stage 0's harness with the non-sleeping drain, ABAB against the switch off. If X falls below 50 % here, stop and report before PR 3.
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
  - a synced field whose conversion throws on some syncs, with a late join right after a drop;
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

## Addendum (2026-11-10, PR 1 #443)

Two changes to section 2, agreed in review before PR 1 was written:

- **The last-sent store is per root field, as typed boxes of native values** (`[K: N]`, `N`, `N?`, `V`), not row arrays.
  - A root node map's rows are written in place. A whole value gets its own buffer at commit, so last-sent doesn't share a container with the live state.
  - The key index is the native `Dictionary`.
  - There are no row indices, free list or seen-epoch: row identity is a step-3 concern.
- **Staging and extraction drops are per root field.** That matches `extractDroppingThrowingFields`, which drops a whole root field.
  - A throw anywhere in a root field discards its patches and its writes.
  - Since commits only write values that converted, a failing value is retried, and dropped, on every later diff of its field, as today.

The section 3 kinds and the runtime fallback check are as described. A changed value is diffed by today's per-value diff on its two snapshots, so no primitive needs its own equality. Conversion purity joins the `==` contract.


## Addendum (2026-11-10, PR 2)

Readings and details fixed while the adapter's broadcast diff moved to the tables:

- **The tables serve `.delta` whatever `USE_SNAPSHOT_FOR_SYNC` says.** Only `.fullSnapshot` keeps today's path. Section 4's line that the snapshot-extraction switch "keeps today's path" was wrong: that switch defaults to on, so the tables would never run.
  - With the switch on, the broadcast diff takes the one-pass extraction's single field set (every dirty field, or all). With it off, it takes the broadcast one (dirty broadcast fields, or all when none is dirty).
- **Per-player fields beside the tables follow the one-pass extraction's rules** while they stay on today's path (until PR 3):
  - every per-player field of every player;
  - no entry at all for a state without per-player fields, so no per-player update is planned;
  - the separate per-field extraction when a dirty broadcast field or a per-player field throws.
- **Seeding follows the plan's field set.** A broadcast diff that finds nothing seeded seeds only the plan's fields and sends nothing, as the empty cache takes the plan's extraction today. A late join seeds every field only while nothing is committed, and its seed overrides a partial one staged by the same plan. A field left out of a committed seed is set whole by its first diff.
- **The split travels on `StatePatch`; paths stay eager.** The diff walks the encoder's path trie as it descends, and a patch carries the split (pattern hash and dynamic keys) of that walk. An opcode encoder takes a carried split only from its own hasher and splits the path itself otherwise (a fallback field, a path outside the schema, no path hashes). `==` and `Codable` ignore the split. A typed patch with a lazy path through the whole pipeline is a separate change, worth doing only if the direction number shows that building path strings matters.
- **Change-object metrics** extract their own broadcast snapshot on a sampled sync, with last-sent standing for the cache, until PR 4 counts rows.
- **The switch** is `USE_SYNC_TABLES` (off by default), also settable per config inside the package and through the Diagnostics SPI for equivalence tests in other packages. A config built with `init` reads the environment too, so a whole test run can be switched. CI runs the transport and NIO test targets with it on until PR 4 flips the default.
