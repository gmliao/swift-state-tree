# Flat per-type state storage (#379 stage 1)

Status: decided 2026-11-10 (section 10); step 0 in progress. A design note; no code. It folds in #392 (patch addressing) and supersedes #393 (the per-type converter cache). The maintainer answered all eight questions on 2026-11-10; two changed the proposal (10.5, 10.7).

**The guiding principle (10.1):** users' convenience comes first, and the design finds a way to make it work. Where a choice costs land authors syntax or a source change, the design absorbs that cost instead.

Read at `exp/next` `0ca8c8cf`. Line references are to that commit.

## 1. Why

#379's stage 0 measured where sync time goes. It used a release build of `EncodingBenchmark` on a Mac, which shows direction only:

| Bucket (share of sync time) | joint | cap100 | vis |
|---|---|---|---|
| A. Building `SnapshotValue` trees | 20 % | 28 % | 28 % |
| B. Diffing | 32 % | 32 % | 1 % |
| C. Splitting patch paths for the path-hash encoder | 19 % | 17 % | 19 % |
| D. Per-player projection and policy filtering | 0.1 % | 0.1 % | 29 % |
| E. MessagePack encoding | 14 % | 12 % | 11 % |
| F. The rest (mostly the auto dirty-tracking calculator, #391) | 14 % | 10 % | 13 % |

The cells:
- **joint:** Hero Defense, 20 active players, cap 20 monsters.
- **cap100:** Hero Defense, 5 players, cap 100.
- **vis:** the visibility test, 20 players with per-player views.

A, B and C are 70 % (joint) and 77 % (cap100) of sync time. They all come from one shape: the state is a tree of native structs, the sync layer converts the changed part into a generic `SnapshotValue` tree, diffs that tree against a cached one, and names each change by a path string that the encoder splits again.

### Facts about today's code that the design relies on

1. **Dirty marks exist only per root `@Sync` field.**
   - `@Sync`'s setter marks its own field (`Sources/SwiftStateTree/Sync/SyncPolicy.swift:119-126`), and `getDirtyFields()` returns root field names only.
   - Writing `state.monsters[42]!.hp` marks both the root `monsters` field and the element's own `hp` field. The sync reads only the root mark. The element mark is never read: nested nodes are snapshotted with `dirtyFields: nil` (`Sync/SnapshotValue.swift:194, 249, 390`).
   - The element mark is also never cleared. `clearDirty()` doesn't recurse into dictionaries, arrays or sets (`StateNodeBuilderMacro.swift:673, 736-740`).
   - `ReactiveDictionary` and `ReactiveSet` track dirty keys, but no land uses them; only their own tests do.
   - So a dirty `monsters` re-extracts and re-diffs the whole map.
2. **Emit order is hash-seeded per process.**
   - The diff iterates a `Set` of keys (`Sync/SyncEngine.swift:280-282, 380-382`), and the wire encoders iterate dictionaries for object values.
   - Since #292, dynamic-key slots don't depend on that order, so encoded sizes are identical across runs. Bytes are not: patch order within a frame still varies (`Notes/solutions/2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`).
   - Records stay deterministic because the sync-stream digest orders patches canonically (`CanonicalPatchList`).
3. **The wire already addresses by numbers**, after the path string is split:
   - the path index;
   - dynamic-key slots, which are never freed;
   - field-merge masks (`[parentId, dynamicKey, op, fieldMask, values…]`);
   - positional atomic values.

   Clients have no identity for an object beyond its path (`sdk/ts/src/core/view.ts`).
4. **The macro sees syntax, not types.**
   - Whether a field holds a node is decided by a runtime `as? any StateNodeProtocol` cast (`StateNodeBuilderMacro.swift:486, 499, 683, 688`).
   - Container shapes are guessed from the type text (`1292-1337`), so a typealias defeats the guess.

## 2. Storage layout

**One table per `@StateNode` type.**
- Columns are typed arrays, one per `@Sync` field. `@Internal` fields are columns too, never synced.
- Each row carries metadata:
  - its generation;
  - an alive bit;
  - its parent `(table, row, field number)`;
  - its key, for a row in a keyed collection;
  - a visibility slot (an owner or a policy), reserved in stage 1 and unused until stage 2's object-level permissions (10.7), so adding them needs no format change.

**The root** is a table with one row.

**Collections:**
- **A keyed collection of nodes** (`[K: Node]`) becomes child rows whose parent link points at the owner's row and field. The owner keeps an index from key to row per field, for lookups and for canonical order.
- **An array of nodes** is the same, with the position as the key.
- **An optional node** is a child link that may be absent.
- **A collection of non-node values** stays one column value:
  - arrays (`[Int]`) and sets, which the wire already treats as one value (`SyncEngine.swift:411-416`);
  - maps of values (`[String: Int]`);
  - plain structs that aren't nodes.

  The diff still compares maps and non-atomic structs per entry, as today's tree diff does (section 5), so the wire doesn't change.

**Handles:**
- A storage handle is `(index, generation)`.
- A freed row's index is reused lowest-first, and its generation goes up.
- A stale handle fails by generation, like `GenerationTable`.
- Handles never go on the wire (section 6).

**Parent links are a column, not a table per parent.** Reparenting then doesn't move rows. flecs and Bevy 0.16 (`ChildOf`) do the same.

**Value semantics:** the state stays a value type. Each column is a copy-on-write array, so copying the state is cheap until a column is written. A write to a column that a live copy shares copies the whole column. Section 9 says how step 1 measures that.

## 3. Macro mapping

The land author's API stays `state.monsters[42]!.hp -= 1`, under option 1 (section 10.1):
- `monsters` returns a view of the Monster table, scoped to this owner's row and field;
- `[42]` resolves to a row through the owner's key index;
- `.hp` is a column accessor with `_modify`, so the write is in place and marks the row and field dirty.

Reading a whole `MonsterState` materializes the struct from its row. Assigning one compares it with the row column by column, and writes and marks only the columns that changed. Inserting a key creates a row; removing one frees it, along with its child rows (cascade).

**What the existing lands use.** GameDemo's lands use this part of the map API on node maps:
- subscripts with `!` and `?.` (`state.players[id]?.resources`, `state.monsters[id]!.hp`);
- `keys`, `count`, `isEmpty` and `removeValue(forKey:)`;
- iteration;
- helpers that take the map `inout`: `CombatSystem` takes `monsters: inout [Int: MonsterState]` (`Examples/GameDemo/Sources/GameContent/Systems/CombatSystem.swift:96, 221`).

How the views cover each:
- **`[id]?.field` and `[id]!.field`:** the subscript's `_modify` yields a row proxy, so a field write goes to its column.
- **`keys`, `count`, `isEmpty`, `removeValue` and iteration:** forwarded to the owner's key index.
- **A helper taking `inout [K: V]`:** it keeps compiling (10.1's principle). The field also offers a dictionary-typed `_modify` that materializes the map, yields it, and writes it back through compare-on-assign (section 4), so only the rows the helper changed are marked. The cost is one materialization and an O(n) compare of the whole map per write-back; step 2 measures it on `CombatSystem` at cap100, and a helper may switch to the view type to avoid it, as an optimization, never a requirement.
  - If that cost is significant, the fallback keeps the user's syntax and makes it cheaper (for example a copy-on-write snapshot whose rows are compared by storage identity before any value compare), never a source change.
- **`!` and `?.`:** a missing key traps under `!` and yields `nil` under `?.`, as on a dictionary today.

So option 1 is source-compatible for land code, helpers that take a node map as a plain dictionary included.

**What the macros still generate:**
- the column list and the field numbers;
- the accessors;
- the field metadata that SchemaGen reads.

**What they no longer generate:**
- `snapshot(for:)`, `broadcastSnapshot` and `snapshotForSync` on the sync path;
- the per-field `@Sync` dirty flags.

`fullStateSnapshot()` stays for the replay hash (section 5).

**Node vs value fields.** The syntactic limit (fact 4) has two ways out:
- A registration step at startup resolves each field's type once. That is the converter idea from #393, run at registration.
- An explicit attribute on node-typed fields.

Section 10.1 compares the macro options.

## 4. Dirty marks and change counts

**Per table:**
- a dirty-row set: a bitset over row indices plus a list of the dirty indices;
- a per-row mask of changed fields: 64 bits, and a second word for a type with more synced fields. Storage marks aren't bound by the wire's 32-bit field-merge mask: fields ranked 32 and above go out as plain entries, as today;
- lists of the rows created and removed this cycle.

**Marks are set on every write, whether dirty tracking is on or off,** so a metric never depends on the mode it decides. "Off" stays permanently, as a package-level switch (not public API) that treats every row as dirty, for ablation, measurement and byte-identity checks (10.5).

**A whole-row assignment marks only the fields that changed.** GameDemo's lands update entities by read-modify-write. Every tick, Hero Defense reads each monster, moves it, and assigns the whole struct back (`Examples/GameDemo/Sources/GameContent/HeroDefenseLand.swift:98-106`); turrets are written back the same way, with a `defer`. Today's `@Sync` setter marks without comparing (`Sync/SyncPolicy.swift:119-126`). If a row assignment did the same, every row would be dirty every tick and the dirty-row lists would buy nothing. The typed per-column `==` is cheap next to the diff it saves.

**Change count:** the number of changed objects is the sum of the tables' dirty-row counts. It needs one generic loop, with no per-type hook. It replaces #391's metric when this lands.

**Clearing** stays where it is: the sync commit's `clearDirtyFlags`, both in the in-turn path and in the legacy path. The rules from #67 and the 11-04 fix hold: a metric never gates a send, and never changes which marks a cycle clears.

## 5. What replaces SnapshotValue on the sync path

**Last-sent copies are owned column buffers,** never assigned from the live columns:
- one copy per broadcast column;
- per player, a copy of the player-dependent columns, holding the values that player was sent.

A copy taken by assignment would share the live column's buffer, and every tick's first write to that column would then copy the whole column. Instead, the commit updates the last-sent buffers in place, element by element, for the dirty rows only. Rows created or removed in the cycle grow or retire their slots there.

**The diff:**
- It walks the dirty rows of each table in the canonical order (section 8).
- For each dirty field, it compares the column value with the last-sent one using typed `==`.
- A field whose value is a map or a non-atomic struct is compared per entry, as today's tree diff does. A `@SnapshotConvertible` type gets a generated per-field differ; any other value type falls back to `SnapshotValue` for that field only.
- It emits typed patches `(table, row, field number, sub-key path, value reference)` into a buffer. No path string is built.

**The encoder** writes values straight from the columns, with atomic values positional as today. Until the wire changes (step 3), it writes today's entries: the path index comes from `(table, field)`, and the dynamic keys come from the row's key chain. Both are computed from the row, not parsed from a string.

**Policies:**

| Policy | Input today | In tables |
|---|---|---|
| `.broadcast`, `.serverOnly` | none | per column |
| `.masked` | the field's value (`Sync/SyncPolicy.swift`) | a computed column, evaluated on dirty rows |
| `.perPlayerSlice()` | the field's whole map; returns that player's entry | a row filter on the key |
| `.perPlayer(closure)` | the field's whole value (`Sync/SyncPolicy.swift:24`) | unchanged: evaluated on the whole field, materialized from the table, whenever any row of the field is dirty |
| `.custom` (deprecated) | the field's whole value (`:39`) | as `.perPlayer` |
| nested policies | | row filters per table, with today's nesting validation (`SyncPolicyNesting`) kept |

**`.perPlayer` and `.custom` keep their contract.**
- A closure may depend on the whole field: it can filter by other entries, take the top N, or count. So it can't run on dirty rows alone without missing changes to its output for unchanged rows.
- The closure's output is diffed against that player's last-sent value as today.
- The cost: the visibility cell's per-player projection (bucket D, 29 %) gains nothing beyond cheaper materialization.
- A row-level policy form that could gain there is a new contract, so it is a question (10.7).

**SnapshotValue stays, off the hot path:**
- the replay state hash: sorted-key JSON of `fullStateSnapshot()` (`ReevaluationEngine.swift:405-429`), unchanged;
- the JSON encoding;
- the `.perPlayer`/`.custom` materialization and the fallback differ above;
- records, logs and debug tooling.

## 6. Wire IDs and storage handles (#392)

**Storage handles stay internal.** Handles are reused (lowest index first, generation bumped). A reused number on the wire would let a client that missed a delete bind an old ID to a new row. That is the Colyseus refId lesson: Colyseus never recycles refIds.

**Wire IDs are monotonic and never reused.**
- A row gets one when it is first sent.
- A per-table map holds row → wire ID, and the client holds wire ID → object.
- Wire IDs replace the dynamic-key slots for node rows. A row's key goes on the wire once, in its create entry, so clients keep their keyed maps.
- **Scope: one counter per land (10.2),** shared by every recipient.
- **Overflow guard:** the counter never wraps. Near its type's limit, the land refuses to create new rows and logs an error, so a reused wire ID can't happen even in a land that runs far past its expected length. Step 3 fixes the counter's type and the guard's margin, with a test that drives the counter to the margin.

**Assignment is deterministic.** New rows are numbered in the canonical order (section 8), so the same run gives the same IDs in every process. Replay, goldens and byte gates all rely on that.

## 7. Patch encoding and SDK decoding

**Entries.** New entry forms, behind a new `stateUpdateFeatures` flag `rowAddressing`, negotiated like `pathIndex`. A client without the feature gets today's entries.

| Kind | Entry |
|---|---|
| create | `[tableId, wireId, op=create, parentWireId, parentField, key, mask, values…]` |
| field set / add | `[tableId, wireId, op, mask, values…]`: field merge's form, addressed by row instead of by parent path and dynamic key |
| delete | `[tableId, wireId, op=delete]`; the client cascades to child rows (10.3) |

Root fields are addressed as `[tableId=root, wireId=0, …]`. `tableId` and the field numbers come from the schema, as the path index does today, so both sides derive them with no new schema content.

**SDK:**
- a per-land map from wire ID to `(object, key, parent)`;
- a create entry links a new object under its parent at its key;
- a field entry writes into the object;
- a delete removes it.

The public `StateTreeView` stays path-based (it can rebuild a path from the parent links), and the generated client code doesn't change.

**Other decoders** follow the SDK: the Swift `StateUpdateDecoder`, ws-loadtest's protocol decoder and the CLI.

**The JSON encoding** keeps path strings, built on demand from the parent links.

**Rollout**, as for `pathIndex` (#297 → #308):
1. The feature lands default-off, with the SDK in the same PR.
2. It flips on in its own PR.
3. The old entry forms stay until a later removal.

## 8. Step 0: canonical emit order on today's path

### The order, defined once

Every step emits a frame's patches in one order: the order the tables produce naturally. Step 0 makes today's tree path produce exactly this order, so every byte gate from step 0 to step 3 compares like with like.

**Definitions:**
- **Table ID:** the schema's node types in topological order of the type graph (Kahn's algorithm). The root is 0; ties among the ready types go to the one a depth-first walk of the schema, taking fields by field number, meets first. A parent's table always comes before its children's, even when a type is reached through several parents (first-meet order alone breaks that). Recursive types, which schema generation refuses, get their cycle and what is reached only through it last, in first-meet order. Implemented in step 0 (#435).
  - That needs an acyclic type graph. `PathFlattener` has two walks: the lenient `flatten` follows a recursive type down to where it re-enters itself, and `flattenRejectingRecursion` refuses it (`SchemaGen/PathFlattener.swift:13-45`, #286). The trie is built with the refusing walk at registration, so an acyclic graph is enforced, not assumed.
  - If recursion is ever allowed, the prefix-first chain rule still orders parent before child within a type's own table. A cycle across two types would need the table order replaced by chain order for the types in the cycle.
- **Field number:** a field's rank among its type's named children in the schema, by UTF-8 bytes. That is exactly field merge's bit rank (`FieldMergeTable`), so a field's merge bit and its number are the same.
- **Key chain:** the row's `(field number, key)` pairs from the root down.
  - The field number is part of the chain because two fields can hold the same node type (`players` and `spectators`, both `[PlayerID: PlayerState]`) and so share one table. With keys alone, `p1` under each would tie, and the parent link would be ambiguous.
  - Keys compare by their UTF-8 bytes, as `CanonicalPatchList` does (`utf8Less`), not by `String` `<`.
  - Chains compare element by element, and a prefix comes before its extensions, so within one table a parent row sorts before its descendants.
- **Sub-key path:** inside a field's value (a map of values or a non-atomic struct), the components below the field, compared the same way.

**The order:** a patch's sort key is `(table ID, key chain, field number, sub-key path)`.
- A patch addressing a row itself (an object-level set at create, or a delete) has no field number and sorts before that row's field patches.
- Object values inside a patch are encoded with their keys in UTF-8 byte order, for MessagePack and JSON alike.

**How the tree path produces it in step 0:**
- After the diff and before encoding, the frame's patches are sorted by that key.
- **The key comes from splitting the patch's path against a pattern trie.**
  - The pattern gives the table and the field numbers, the captured keys give the key chain, and anything below the matched pattern is the sub-key path.
  - The trie is built at registration from the land's schema, by the same walk `PathFlattener` does, for every land and every encoding. It doesn't depend on `pathHashes`.
- **Opcode encodings with path hashes** already split every path once (`PathHasher.split`). The split moves before the sort and is reused, not done twice.
- **The JSON encoding, and opcode JSON without path hashes,** don't split today. With step 0 they split each patch once.
  - At stage 0's split cost (bucket C: 158 µs for 91 patches on joint, 254 µs for 149 on cap100, about 1.7 µs a patch), that adds roughly 150–250 µs per sync on Hero Defense.
  - These aren't the shipped encoding (GameServer ships `messagepack`). The canonical order is always on for MessagePack and JSON alike, with no switch: JSON's extra cost is accepted, since JSON serves format comparison only (10.6). Step 0 measures it.
  - **Planned re-baseline:** it moves any CPU number measured for those encodings, roughly 15–30 % of joint's and cap100's sync time. Two topics compare encodings by CPU and include JSON: `deep-research/single-room-entity-scaling/` (every wire form per cell) and `deep-research/snapshot-baseline/` (`--format json-object`). Their tables are re-run at step 0's commit before any comparison across it. Data recorded at earlier commits (such as `multiroom-load-2026-02`) stays as recorded, with its commit.
- **A path no pattern matches in full** (the #287 class: below an optional field):
  - The longest matching pattern prefix gives the table and the field.
  - The remaining components are the sub-key path, compared by UTF-8 bytes.
  - In tables those components are inside the field's column value, where the diff orders them the same way, so both paths agree.
- **A land whose schema has no node fields below the root** gets one table. Its field numbers are the root fields' ranks by UTF-8 name, so the order reduces to (root field name bytes, sub-key path) on both paths.
- The diff's own iteration order stops mattering.

**Order dependence:**
- A delete or replace of an entity and a field set inside it never come out of one diff for the same entity. Parents' tables come before children's, so a created parent precedes its children.
- Field merge closes a group on a patch at, above or below its parent. Under this order such patches sit next to the group, never between two of its members, so the merged groups are the same as with any other order that keeps them adjacent.

### What step 0 changes

**Which measured numbers move:**
- **Frame sizes: none.** Since #292, dynamic-key slots depend on the set of a frame's new keys, not their order, and the merged groups don't change (above).
- **Bytes across repeats:** they become identical without `SWIFT_DETERMINISTIC_HASHING`. That is the point of the step.
- **Sync time:** it goes up by the sort. The split moves earlier and isn't repeated. The estimate is a few microseconds per sync against 818 / 1518 / 510 µs; the step measures it with stage 0's harness.

**Goldens, fixtures and captures:**
- **The sync-output goldens don't change.** They hash `CanonicalPatchList`, which is already canonical, and their `apply-cases.json` files are already in canonical order (their equality check would flake otherwise).
- **The field-merge and shape-matrix fixtures don't change.** They encode explicit patch lists, not diff output.
- **`HeroDefenseWireBytesTests` doesn't change:** it checks sizes.
- **`DynamicKeySlotOrderTests` stays as is:** it feeds patches in both orders on purpose.
- **ws-loadtest's captured frames stay valid.** The `hero-defense-frames-*.json.gz` and `view-capture-*.ndjson.gz` files and the apply p10/p50 inputs are decoder inputs recorded once. Decoders don't depend on order within a frame, so they aren't regenerated.
- **The JSON encoding sorts object keys too** (`SnapshotValue.encode` iterates a dictionary today). Otherwise "byte-identical in every encoding" fails for JSON.
- The step's PR shows the full run as evidence.

**New test:** the same scripted sync, encoded in two processes (or with two dictionary capacities in one process), gives identical bytes in every encoding.

## 9. Step 1: the hand-written upper bound, and its stop criterion

**What:** throwaway code on its own branch, never merged.
- Hero Defense's broadcast part (`HeroDefenseState`, `PlayerState`, `MonsterState`, `TurretState`, `BaseState`) stored in hand-written tables, with last-sent buffers updated in place (section 5).
- A hand-written dirty-row diff and encoder producing today's opcode MessagePack entries (path index, slots, field merge, positional atomics) from the columns, in the canonical order.
- Gate: its frames are byte-identical to step 0's encoder on the same run.

**Harness:** stage 0's `EncodingBenchmark` setup: release build, serial, 1 room, 2000 iterations, `--ticks-per-sync 2`, `messagepack-pathhash`, path index and field merge on.

**Cells:**
- **cap100:** 5 players, cap 100. It is the bar's cell.
- **joint:** 20 players, cap 20. Reported.
- **cap500-idle:** a monster cap of 500 with about 5 % of monsters active per tick. Reported.
  - This cell shows the gain from per-row dirty marks, which cap100 can't: there every monster moves every tick, so the whole map is dirty either way.
  - **Idle means unwritten, not just unmoved.** Hero Defense's tick reads, moves and assigns back every monster (`HeroDefenseLand.swift:98-106`), and today's setter marks without comparing. So the knob (an `Examples/` change in step 1) skips idle monsters' update and assignment entirely: no field of an idle monster is written in the tick.
  - The bound's compare-on-assign (section 4) would also keep a same-value write clean, but the cell shouldn't depend on it.
  - **Validity check:** the bound's dirty-row count per sync is 4–6 % of the monster rows. Otherwise the cell isn't reported as idle.
- vis isn't in step 1. Its cost is the `.perPlayer` projection, which keeps its whole-field contract (section 5).

### The stop criterion: one number, one bar

**The number:** sync time per sync on cap100, the hand-written bound against today's path (with step 0), as a saving X = 1 − bound / today.

**The comparison is bound against bound.** The alternatives' figure is a bound too: the share of their buckets in stage 0, assuming each change removes its bucket completely.
- The converter cache (#393) removes the cast chain and the `Mirror` fallback: 11–20 % of sync.
- Numbers instead of path strings on the tree path (#392) removes path splitting: 17–19 %.
- Together that is A ≈ 40 % at the top of the range.

**The same recovery applies to both.** A generic implementation of either keeps a fraction r of its hand-written bound. With the same r on both sides, it cancels: the storage change beats the alternatives when X > A.

**The margin.** The storage change costs much more than the alternatives:
- a new storage layer and its macros;
- a source change for helpers taking node maps (section 3);
- an SDK and wire change in step 3.

It has to win by a margin, not a tie. The bar asks for 25 % more saving than the alternatives: X ≥ 1.25 · A = 50 %.

**The bar:** proceed only if the bound cuts cap100's sync time by at least 50 %, that is bound ≤ 0.5 × today.
- Below the bar, stop: reopen #393, and do #392 on today's tree path.
- joint and cap500-idle are reported for the maintainer and don't change the bar. A cap500-idle result far above the bar can argue for proceeding anyway, as a maintainer decision.
- Mac numbers decide direction only. A result within 10 points of the bar is measured again on the measurement host before deciding.

**What's assumed, and what the maintainer sets (10.8):**
- **A is an estimate,** not a measurement. Hand-writing the alternatives' bound for the same Hero Defense types would replace it with a number. Decided (10.8): if X lands within 10 points of the bar (40–60 %), step 1 hand-writes it too: the tree path with element-level dirty marks and no flattening. If the two come out close, the cheaper change wins.
- **The margin of 1.25 is a judgment.** With an asymmetric recovery instead (the alternatives keep their whole bound, the storage change keeps r of its), the bar would be A / r: 67 % at r = 0.6, 57 % at r = 0.7, 50 % at r = 0.8.

**Tick time is reported next to sync time.** The bound's compare-on-assign (section 4) compares every column of every assigned row, every tick, and Hero Defense assigns every monster back; today's setter doesn't compare. So the bound moves some cost into the tick.
- On all three cells, tick time is reported for the bound and for today's path.
- **Tick regression limit:** the bound's tick time may rise by at most half the sync time it saves. Equivalently, iteration time (ticks plus sync) must still fall by at least half the sync saving's share of the iteration: about 17 % on cap100 at the bar.
- If the tick's extra cost cancels more than that, the bar fails too, and the note records that compare-on-assign is the reason.

For scale: sync is 67 % of iteration time on cap100 (1518 of 2259 µs) and 54 % on joint (818 of 1505 µs). So a 50 % sync cut is about 34 % of iteration time on cap100.

### Copy-on-write: what is measured, and what it decides

**On a server**, the legacy sync path copies the state at `beginSync` and clears the live state's dirty marks (`LandKeeper.swift:1164-1174`). The sync runs while the keeper takes its next turns, so the copy stays alive and the next tick's first write to each shared buffer copies it. That is a column for the bound, and a dictionary for today's path, which is copy-on-write too.

**`EncodingBenchmark` never shows this.** It is serial: it awaits `adapter.syncNow()` after the ticks (`Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkExecution.swift:287, 307`), so the copy is gone before the next tick.

**Measured with** a harness variant (an `Examples/` change in step 1, `--hold-sync-copy`):
- it keeps a copy of the state alive across the next sync interval's ticks;
- it runs on both sides, today's path and the bound, on all three cells;
- it reports tick time with and without the held copy.

**What each result decides:**
- **In-turn path (the default):** nothing holds a copy, and the bound's last-sent buffers are updated in place (section 5), so tick time must not move.
  - This is a blocking check before step 2: if it moves, a last-sent buffer shares storage with a live column, or something else holds a copy (the state hash recording is the next suspect), and that is fixed first.
  - It also settles in-place vs double-buffered last-sent buffers. In place is chosen; double-buffering is considered only if this check can't be made to pass with in-place updates.
- **Legacy path:** reported only, by choice.
  - It is off by default, and its removal is planned (layer 3's PR B removes the legacy sync path and the `IN_TURN_SYNC` switch, `2026-11-05-layer3-prs.md`).
  - Both sides pay it, so it isn't part of the bar.

## 10. Questions for the maintainer

### Decisions (2026-11-10)

| Question | Decision |
|---|---|
| 10.1 Macro mapping | Option 1, views over tables; land code keeps `state.monsters[id]!.hp`. Principle: users' convenience first; where views cost something (copies, write-back, `!` semantics), the design solves it and the syntax stays (section 3). |
| 10.2 Wire ID scope | Per land: one monotonic counter, never reused, with an overflow guard that refuses new rows and logs near the limit, never wraps (section 6). |
| 10.3 Deleting a row with children | Client cascade. |
| 10.4 Sync-stream hash | (a): string paths built only while recording; no format bump. |
| 10.5 Dirty tracking off | **Changed:** "off" stays permanently, as a package-level switch (not public API) for ablation, measurement and byte-identity checks. Only the automatic on/off switching is removed, in step 2. |
| 10.6 Step 0 | Its own PR. The canonical order is always on for MessagePack and JSON, with no switch; JSON's extra cost is accepted. The JSON re-baseline of `single-room-entity-scaling` and `snapshot-baseline` runs at step 0's commit. |
| 10.7 Per-player data | **Changed:** private data is split into separate objects with an owner and a visibility decided per row, rather than per-field filters inside one object (Unreal's actor ownership, Colyseus `StateView`, SpacetimeDB's row-level security). Stage 1 reserves a per-row visibility slot in the table layout (section 2), so no format change is needed later; today's `.perPlayer` fields work unchanged. Stage 2 designs an object-level permission API for convenience (for example `ownerOnly` on a node type), measured on the visibility topic's land, since Hero Defense doesn't exercise it. |
| 10.8 The stop bar | Option 1: X ≥ 50 % on cap100. Within 10 points (40–60 %), hand-write the alternatives' bound too (section 9); if close, the cheaper change wins. |

The questions below are kept as asked, with each one's options and costs.

[V] means verified in that system's docs or source (most are linked from #379's prior-art comment); [I] means inferred.

### 10.1 The macro mapping: views over tables, or ECS-style handles

**Options:**
1. **Views over tables.** The macro generates the column list, field numbers and accessors, and today's `state.monsters[42]!.hp` API stays.
2. **Handles and columns, ECS-style:** `monsters.hp[handle] -= 10`. No tree API, and the macros shrink to schema metadata.
3. **Runtime registration by KeyPath.** No macro, hand-written registration, slower access through KeyPaths.

**Comparable systems:**
- Colyseus keeps a tree API over its refId table through instrumented setters, with decorators at runtime [V].
- Bevy and EnTT are option 2: handles plus components [V].
- Unity Netcode for Entities is option 2 with source-generated serializers [V].
- Unreal Iris builds replication descriptors from reflection, which is closest to option 3 [V].
- The Truth exposes typed objects over an ID-indexed table, which is closest to option 1 [V].

**Cost:**
- Option 1 keeps land code that goes through the state source-compatible. Helpers that take a node map as `inout [K: V]` change to the view type (section 3): two functions in GameDemo. It needs the node-vs-value resolution from section 3, and its accessor code is per field, roughly the size of today's container helpers.
- Option 2 rewrites every land (GameDemo, Demo, the test lands) and drops the tree-shaped API that the docs and tutorials teach.
- Option 3 has no macro work but pays KeyPath access on every write.

**Recommendation: option 1.** The API is the product; the speed comes from the storage and the generic loop, not from exposing handles.

### 10.2 Wire IDs: one space per land, or per scope

**Options:**
- **Per land:** one counter, shared by every recipient.
- **Per scope:** broadcast plus one per player, as today's dynamic-key tables are.

**Comparable systems:**
- Colyseus refIds are per room and shared by all clients [V].
- Netcode for Entities `ghostId`s are per world, with a spawn tick to tell reuses apart [I].
- Iris `NetRefHandle`s are per object, shared by connections [I].

**Cost in bytes:**
- A reference costs 1 B below 128, 2 B below 256 and 3 B below 65 536. Today's slot references have the same widths, and slots are never freed either.
- So per land costs about what today's broadcast slots cost. The cap100 cell creates 413 monster keys over 200 syncs, so both reach 3-byte references.
- Per scope gives a per-player-only row a smaller number in that player's frames. It needs a table per player, and a row that is both broadcast and per-player-visible gets two numbers.

**Recommendation: per land.** The merged broadcast frame (opcode 107) is encoded once for every recipient, which needs one shared numbering.

### 10.3 Deleting a row with children: client cascade or explicit deletes

**Options:**
- **Client cascade:** the server sends one delete for the row, and the client removes its child rows through the parent links it learned at create.
- **Explicit:** the server sends a delete per child row.

**Comparable systems:**
- Colyseus counts references and collects child refs on the client when a parent goes [V, `Root.ts`].
- Bevy's relationships despawn children with the parent [V].
- Netcode for Entities despawns a ghost group with its root [I].

**Cost:**
- Explicit deletes add one entry per child row, about 3–4 B each.
- On Hero Defense this costs nothing either way: monsters, turrets and players have no child node rows, since positions are atomic values.
- Lands with nested node maps pay per child.

**Recommendation: client cascade.** It matches today's meaning, where a delete at `/monsters/42` removes the subtree. Child wire IDs retire with the parent and are never reused. The verify-views oracle already compares whole projections, so it checks the cascade.

### 10.4 The sync-stream hash: paths only while recording, or typed patches

Today the sync-stream digest hashes canonical logical patches with string paths (`CanonicalPatchList`, `TransportAdapter.swift:3553, 3568, 3664`) on every sync of a recorded land.

**Options:**
- **(a)** Keep the digest. While recording, build each patch's path from its row's parent links for the hash only.
- **(b)** Hash typed patches `(table, key chain, field number, value)`. That is a record format change (a minor bump), with the goldens and the verifier oracle re-pointed.

**Comparable systems:**
- Photon Quantum checksums the state per frame, not the patches [V].
- None of the others verify sync output [I].

**Cost:**
- (a) costs nothing unless recording is on; recording is off by default (GameServer's `ENABLE_REEVALUATION`). When it is on, it costs one path per patch: 91 / 149 / 3 patches per sync in stage 0's cells, against the 283 / 604 / 151 strings per sync built today.
- (b) costs a format bump and golden regeneration.

**Recommendation: (a)** in steps 2 and 3, measured with recording on. Move to (b) only if (a) shows in the numbers.

### 10.5 Does "dirty tracking off" survive?

Today dirty tracking can be off, extracting every field every sync, and auto dirty tracking switches modes on the change rate (#391 samples that switch). The switch exists because with whole-map re-diffing, extracting everything can be cheaper at high change rates.

**Options:**
- **Keep both modes and the auto switch.**
- **Keep "off" only as an ablation flag** that marks every row dirty, and remove the auto switch.

**Comparable systems:**
- Unreal's legacy replication compares every property every frame; its push model and Iris use marks, and both coexist as options [I].
- Netcode for Entities compares against a baseline per chunk, with change filtering as an optimization [I].

**Cost:** with per-row marks there is nothing to skip. The diff visits only dirty rows, so "off" is strictly more work. The auto switch's metric would read the tables' dirty-row counts.

**Recommendation:** keep "off" as an ablation flag, and remove the auto switch in step 2, once a measurement on the high-change cells confirms that marks never lose.

**Decided:** "off" stays permanently as a package-level switch; the auto switch goes in step 2 (Decisions above).

### 10.6 Does step 0 land on its own?

**Options:**
- **Land step 0 as its own PR now,** before step 1.
- **Fold it into step 2.**

**What it buys on its own:**
- byte-identical frames across processes, which the byte gate needs;
- measurement repeats that compare bytes, not only sizes;
- no change to sizes, goldens or fixtures (section 8);
- a sort cost per sync, measured in the PR. The JSON encodings also pay one path split per patch (section 8; roughly 150–250 µs per sync on Hero Defense); the shipped `messagepack` encoding already splits.

**Comparable systems:** Netcode for Entities and Quake-style protocols emit in slot order, which is deterministic [I].

**Sub-question: does step 0 sort the JSON encodings too?**
- **Yes:** byte-identical frames in every encoding, at +150–250 µs per sync for JSON (section 8), and the re-baseline of the JSON CPU tables.
- **No:** only the opcode encodings with path hashes are sorted, at a cost of a sort alone. JSON keeps today's order, and the step 2 byte gate covers opcode MessagePack only, with JSON checked by decoded views.
- **Recommendation:** yes. JSON is a debugging and compatibility encoding, and a canonical order makes its frames diffable.

**Recommendation: land it on its own,** after the maintainer's go, with the full suite and the step 0 numbers. Step 1's byte gate needs it, and it is useful even if stage 1 stops.

### 10.7 Row-level per-player policies

`.perPlayer` and `.custom` take the whole field value, so they keep whole-field evaluation (section 5), and the visibility cell's projection (bucket D, 29 %) gains little.

**Options:**
1. **Keep the contract.** No new API. vis gains only cheaper materialization.
2. **Add a row-level form** next to the old one, for example `.perPlayerRow { row, player in … }` on a node map: a filter or transform per row that depends on that row and the player only.
   - Rows are evaluated when dirty, or when the player's membership changes.
   - The old whole-field form stays on the materialized path.
   - A new public API.
3. **Change `.perPlayer`'s contract to per row.** That is source-incompatible, and it silently changes closures that look at other entries.

**Comparable systems:**
- Unreal's per-connection relevancy is per actor [V].
- Netcode for Entities' ghost relevancy is per ghost entity and connection [V].
- Colyseus' `@view` filters per instance and client [V].
- All of these are row-level.

**Cost:** option 2 saves a share of bucket D proportional to the dirty fraction. It is unmeasured until a land uses it, and the visibility test would be its first user.

**Recommendation:** option 1 in stage 1, and option 2 as its own decision once step 2's numbers are in.

**Decided:** object-level visibility per row instead of a per-field row filter: stage 1 reserves the slot, stage 2 designs the API (Decisions above).

### 10.8 The stop bar's assumptions

The bar (section 9) compares the hand-written bound with the alternatives' bound (A ≈ 40 %, estimated from stage 0's buckets). Generic recovery is the same on both sides, and the storage change must win by 1.25×. That gives 50 %.

**Options:**
1. **Symmetric recovery, 1.25× margin, A estimated:** a 50 % bar. Recommended.
2. **The same, but A measured:** hand-write the alternatives' bound in step 1 too (about a day). The bar is then 1.25 × the measured A.
3. **Asymmetric recovery** (the alternatives keep their whole bound, the storage change keeps r): the bar is A / r, which is 67 % at r = 0.6 and 57 % at r = 0.7.

**Comparable evidence:** none found that compares a generic implementation with its hand-tuned bound for state sync. In this repository, the path index and field merge kept their experiment branch's byte gains in the final code (#297, #301). Those are byte gains, not CPU gains, so they don't set r.

**Recommendation:** option 1, switching to option 2 when the bound lands within 10 points of the bar.

## 11. Gates

**Step 2, a no-regression cell:** the visibility test. `.perPlayer` keeps its whole-field contract (section 5).
- Today the closure receives the dictionary that already exists. With tables, a sync where any row of the field is dirty first assembles the map from the columns.
- That map is built once per sync and shared by every player's closure, never per player.
- **Gate:** vis sync time no more than 5 % above today's, measured with stage 0's harness.
- **Expected cost:** one map materialization per dirty per-player field per sync. That is about the cost of the native dictionary today's tick already maintains, set against removing bucket A for those fields. Expected to be at most even.

**Steps 0 and 2 (the wire is unchanged):**
- frames byte-identical to the canonical-order baseline, in every encoding (section 8's order, with sorted object keys in JSON and MessagePack);
- verify-views unchanged;
- E2E convergence;
- the replay state hash unchanged;
- the sync-output goldens, and their re-recorded record bytes, unchanged;
- the shape-matrix and field-merge byte fixtures unchanged.

**Step 3 (`rowAddressing`, a wire change):**
- byte fixtures for the new entries;
- the old forms' fixtures unchanged with the feature off;
- verify-views and E2E convergence in all three encodings;
- the sync-output goldens unchanged (records stay logical, 10.4 (a));
- the replay hash unchanged;
- bytes and CPU measured with stage 0's harness.

## 12. Order of work

0. **Canonical emit order** on today's path (section 8), as its own PR (10.6).
1. **The hand-written upper bound** for Hero Defense's broadcast part (section 9). Throwaway, measured against the stop criterion.
2. **Generic tables behind today's API** (option 1), with dirty rows and the generic diff and encoder. The wire is unchanged; the gates are in section 11.
3. **Row addressing on the wire** (#392), with the SDK.

Steps 2 and 3 get their own plans, written once step 1's numbers are in. Stage 2's object-level permission API (10.7) gets its own plan too.

## 13. Not in scope

- The wire for per-player visibility beyond today's projection, and the object-level permission API (stage 2, 10.7). Stage 1 only reserves the row's visibility slot.
- Baselines older than the last sent (Netcode for Entities' three acked baselines). SST diffs against the last-sent state.
- #391's sampling. It lands now on today's path and is replaced by dirty-row counts in step 2.
