# Flat storage step 3: row addressing on the wire (#392)

Status: reviewed, 2026-11-10 (two rounds; GO for PR A, with section 4's gate to be final before PR C). Step 3 of `2026-11-10-flat-state-storage.md` (section 12), built on step 2's sync-side tables (`2026-11-10-flat-storage-step2.md`, PR 2 = #465). Read at `exp/next` plus #465's head 8b1b77b5. No code before this plan is reviewed.

## Decisions

| Date | Decision | By |
|---|---|---|
| 2026-11-10 | The wire addresses a row by its table slot; slots are reused, with a generation. The emit order is (table, field, slot), from the dirty bitmap. Supersedes the parent plan's section 6 and decision 10.2 (monotonic wire IDs, never reused). Section 1 has the safety argument and what is given up | maintainer, on #392 |
| 2026-11-10 | The 50 % bar on cap100's sync time is judged at the end of this step, not at step 2's PR 2 | maintainer |
| 2026-11-10 | #446: map keys are NFC on the wire in every encoding, with an ASCII fast path. `PlayerID` is normalized to NFC once, at creation (section 8) | maintainer |
| 2026-11-10 | A synced value that is not `Equatable` gets a compile-time warning, not an error (section 11) | maintainer |
| 2026-11-10 | #87: option A (roll back a throwing input's writes) comes with this step (section 10) | maintainer, on #87 |
| 2026-11-10 | The column entry, with a 2 % byte gate and a compact slot list as the fallback (section 3) | review |
| 2026-11-10 | A join is held until the next broadcast plan, so the joiner's first view is all as of one sync; a join up to one sync interval slower is accepted (section 4) | maintainer |
| 2026-11-10 | `rowAddressing` takes effect only where every join completes in a turn (in-turn sync, a live keeper, joins through the router); the legacy paths get no hold (section 4) | review of the plan, with the maintainer informed |
| open | Typed conversion inside this step (section 9, PR E); the cost of #87 A on sync-side tables (section 10) | with the maintainer |

## 0. Where step 2 stands, and what is left to remove

Mac direction numbers for #465 (release `EncodingBenchmark`, Hero Defense, MessagePack with path hashes, ABAB; direction only, not a baseline):

- cap100: sync 1470 µs with the tables off, 914 µs with them on, a 37.8 % reduction;
- joint: 32.9 %;
- cap500-idle: 56.6 %.

A sampled profile of the 914 µs on cap100 (approximate, one machine):

| Bucket | µs | What it is |
|---|---|---|
| Table diff | ~246 | typed compare of every row of a dirty root field, staging |
| Conversion | ~201 | native value → `SnapshotValue` for each changed value |
| Encoder planning | ~198 | split reuse, field-merge grouping by parent hash and path prefix, frame order keys |
| Encoding | ~190 | MessagePack writing; ~84 of it is the atomic-layout lookup, which re-splits the path string per value |
| Path strings | ~45 | `path + "/" + component` per patch |
| Order | ~12 | grouping by table |

The bar needs 735 µs or less. Row addressing targets the last four rows where they concern map rows: ~327 µs at most, and not all of it goes (root fields and nested values keep today's entries, and the new entries have their own cost). So the format alone probably lands near the bar, not clearly under it. Section 9 therefore plans typed conversion as a PR inside this step, after the format PRs.

## 1. Slots on the wire (supersedes 10.2)

**The rule.** A slot-addressed table (section 2) numbers its rows with small integers:
- **Allocation:** a new row takes the lowest free slot. Rows created in one sync are numbered in canonical key order (the UTF-8 bytes of the key component), so only the new keys of that sync are sorted.
- **Freeing:** a deleted row's slot becomes free when the plan that deleted it commits. It can be taken from the next sync on, never in the same frame as its delete.
- **Generation:** each slot has a counter, bumped when the slot is taken again. It goes on the wire in the create entry only.
- **Staging:** allocation and freeing are staged with a broadcast plan, like the tables' writes, and committed with it. A failed plan discards them. Nothing allocates outside a broadcast plan (section 4): allocation belongs to the sync phase.
- **Seeding:** a table seeded whole (the first plan that sends it, with nothing committed) numbers its rows from 0 in canonical key order.

**What the numbering is a function of.** The committed table, the new keys, and therefore the sequence of syncs: which keys are new in which sync, and when a slot frees. The same sequence of syncs gives the same slots in every process, which the byte fixtures need. Two runs with different sync schedules can number differently: the replay land syncs every tick, so its slots can differ from the live run's. That is fine because nothing compares frames across schedules (section 6): records hold logical patches, not slots.

**Why reuse is safe: three rules, none of which is loss detection.**

1. **The transport delivers a frame in order or ends the connection.** The WebSocket transport does. The sync sequence cannot stand in for this: it is per land and advances on every plan, other players' firstSyncs included, and a recipient with no change gets no frame, so gaps are normal. `rowAddressing` requires `syncSequence` only because a resync needs it.
2. **The server never commits a row change that a holder of the table was not sent.** Today content can be lost on the server after the plan is made:
   - `encodeDroppingUnencodablePatches` drops single patches and still sends the frame. A dropped create would leave a committed slot the client never bound.
   - With combined frames (JSON and opcode JSON), a recipient whose frame did not encode gets nothing, while the shared cache advances for the others (the limit documented where the frame is dropped).

   With `rowAddressing`:
   - **Row entries are encoded once per plan, before any frame or view is built;** they are the same bytes for every recipient.
   - **A value that does not encode drops its row from the plan, not its table.** A create that fails is left out with its staged allocation, so the row stays absent from the table. A column value that fails takes its row out of every column of this plan, and the row's staged write is discarded, so last-sent stays where the clients are. A delete carries no value and cannot fail. Every other row of the table proceeds. The dropped row is diffed again by each later plan, as a value that fails is retried today.
   - **Why not the whole root field:** one row that never encodes (a non-finite `Float` in opcode JSON) would stall every create, column and delete of its table for good. Resyncs would send the committed table, which encodes, so no 4012 would end it.
   - **A plan that dropped a row schedules a retry** on a land without periodic sync, with the delayed follow-up sync that failed plans use and under its limit. A plan that only dropped rows otherwise counts as a success and nothing else would run again.
   - **The order inside a plan:** encode the row entries, settle the drops (staged table final), then build every full view and frame. A staged-table view built before a drop would send a binding the plan then discards; combined mode builds its views before encoding today, so that order changes.
   - **A recipient that does not get a frame carrying committed row entries is resynced by the next plan** (the resync of #332, which rebuilds its row tables), and closed with 4012 if its view cannot be encoded, as #344 does.
3. **The decoders are strict.** A column or delete on an unbound slot, and a create on a bound slot, are protocol errors. Today a dynamic-key slot used before its definition drops the frame and decoding goes on; for row entries the SDK does not go on: it closes the connection, and the application rejoins. The Swift decoder throws. A client-requested resync does not exist and is not added here.

**The generation.**
- The client drops a slot's binding on delete, so a create on a bound slot is an error without any generation.
- The client keeps each slot's last generation after a delete. A create must carry a greater one. That catches a create replayed or misrouted onto a slot that was freed, which the binding check alone accepts.
- A recipient that never saw a slot's earlier rows (a late joiner, and per-recipient visibility later) has no stored generation, and accepts any.
- A resync and a joiner's first frame clear bindings and generations.
- The oracle (section 7) compares slot, key and generation with the server's table.

**Numbers stay small.** A slot reference is 1 byte below 128. The cap100 cell holds about 100 monsters at a time and created 413 keys over 200 syncs: a monotonic counter leaves 1-byte references after 128 creations, and slots stay within them.

**What is given up.** 10.2 protected a client that loses a frame without the connection ending: with never-reused IDs it meets an unknown ID, and with reuse it can write into the wrong row until a strict check fires. The three rules cover every way a frame or an entry is lost today. They do not cover a transport that drops silently. Detecting that would need a per-recipient frame counter (the per-land sequence cannot do it); that is not in this step, and a transport without ordered delivery must not enable the feature.

**Row visibility (parent plan 10.7, stage 2).** Slots are per land and per table, shared by every recipient. A row hidden from a recipient is never created for it: its frame carries the create when the row becomes visible and a delete when it stops being visible, with the slot everyone else uses. Such a recipient can see a slot bound again without having seen the earlier row; it has no binding and no stored generation for it, so the create is accepted. Nothing in this step implements it; the format leaves room.

## 2. Which tables are slot-addressed

**In this step: a root field that is a node map on the typed path** (`SyncTableFieldKind.nodeMap`, a broadcast field). That is every hot table in Hero Defense (monsters, turrets, players).

**Kept on today's entries** (path id plus dynamic keys), in the same frame:
- root values, root nodes and optional nodes: they have no dynamic key, so their path id is already a number;
- value maps and arrays, wherever they are: their keys stay in the dynamic key table;
- a node map nested inside a row. Its patches keep both of their dynamic keys, including the parent row's key, in the dynamic key table. It is correct and costs what it costs today. The create form reserves a parent slot for a later step (section 3);
- fallback fields;
- per-player fields (section 5).

A decoder tells the forms apart by the entry's op, so one frame can hold both.

**Storage.** The last-sent store of such a field changes from a native `[K: N]` to a slotted table:
- `rows: ContiguousArray<N?>`, `keys: [K]` and `generations: [UInt32]`, indexed by slot;
- `index: [K: Int32]`, with `String` equality as today, so an NFC and an NFD spelling are one row;
- a free list ordered lowest first;
- per leaf (section 3), a dirty bitmap over slots, cleared at commit.

The step 2 addendum for PR 1 left row identity to this step ("no row indices, free list or seen-epoch"); this adds the first two. The live state stays native structs.

**The diff.** The row walk is the one PR 2 has: for each live row, find its slot through the index and compare it with `rows[slot]` field by field. What changes is the output:
- a changed leaf sets the row's bit in that leaf's bitmap, instead of appending a patch;
- a new key is collected for allocation, and a missing one for deletion;
- the emit then walks the tables in order, the leaves in the path table's order and each bitmap in slot order. With the feature on, nothing is sorted except the new keys.

## 3. The entries

Behind a new state-update feature `rowAddressing`, with the opcode encodings only, negotiated at join like `pathIndex`. It requires `pathIndex` and `syncSequence`. A client without it gets today's entries.

| Entry | Form | Notes |
|---|---|---|
| create | `[tableId, slot, 6, generation, parentSlot, key, value]` | `value` is the whole row, as today's set at the row's path sends it. `parentSlot` is `nil` for a root table |
| delete | `[tableId, slot, 7]` | the client removes the row and its subtree, as a remove at the row's path does today |
| column set | `[leafPathId, [slot, …], 8, [value, …]]` | one entry per (table, leaf) with a set bit; slots ascending, values in the same order |
| column clear | `[leafPathId, [slot, …], 9]` | the leaf is removed in those rows: today's `.delete` at the leaf's path (an optional going nil) |

- **`tableId`** is the path id of the row pattern (`monsters.*`), and **`leafPathId`** the path id of a pattern below it with no further dynamic key (`monsters.*.health`, `monsters.*.position`). Both are in the path table already, as indices under `pathIndex`. No new schema content, so `schemaHash` does not move.
- **The entry's shape is today's** (`[pathId, keys, op, value?]`), with new ops 6 to 9. A decoder reads the op before it interprets the second element.
- **Order in a frame:** today's entries first, in their canonical order; then per table, in `tableId` order: creates by slot, column sets and clears by leaf (the path table's order) then slot, deletes by slot.
- **The key** in a create is the map key's string, written once. `""` is a valid key (#205, section 8).
- **A node type with more than 32 synced fields** is no special case: a column is per leaf, not a mask.
- **Add versus set:** a leaf entry inside a live row is always a set. A row's first appearance is the create.

**What inside a row is a column, and what is not.** A leaf is whatever today's diff emits one patch for, at a path with the row's key as its only dynamic key:

| Inside a row | Today's patch | With `rowAddressing` |
|---|---|---|
| a primitive or atomic value (`health`, `position`) | set at the field's path | column set |
| an optional value going nil, or coming back | delete, or set | column clear, or column set |
| a nested node held directly | a patch per changed field of it | each of its fields is a leaf of the row: a column |
| an optional nested node going nil, or coming back | delete, or set of the whole node | column clear, or column set at the node's path |
| an array, or a non-atomic struct, replaced whole | set at the field's path | column set |
| a value map: one entry changed | a patch at `row/field/key` | today's entry, unchanged: two dynamic keys, the row's key and the entry's, both from the dynamic key table |
| a nested node map | patches below `row/field/key` | today's entries, unchanged |

So a row that holds a value map or a nested node map keeps its key in the dynamic key table as well as its slot, and pays the key's definition there once, as today. That cost is counted in the byte report.

**Hero Defense's row types** (broadcast fields; all are columns):

| Type | Fields | Form |
|---|---|---|
| `MonsterState` | `id`, `health`, `maxHealth`, `reward` (Int); `pathProgress` (Float); `position`, `spawnPosition` (`Position2`); `rotation` (`Angle`) | column set |
| `PlayerState` | `health`, `maxHealth`, `weaponLevel`, `resources` (Int); `lastFireTick` (Int64); `position`; `rotation` | column set |
| `PlayerState` | `targetPosition` (`Position2?`) | column set, or clear when it goes nil |
| `TurretState` | `id`, `level` (Int); `lastFireTick` (Int64); `position`; `rotation` | column set |
| `TurretState` | `ownerID` (`PlayerID?`) | column set, or clear |

None holds a value map or a nested node map, so no Hero Defense row needs the dynamic key table. The shape matrix and the visibility lands cover the rows that do.

**Bytes.** Field merge sends one entry per changed row (`[parentId, key, op, mask, values…]`); a column sends one entry per changed leaf with a slot list. For rows that change one or two fields each, the column form drops the per-row path id, op and mask and repeats the slot per leaf. Which is smaller depends on the cell, so PR C (section 9) reports bytes per sync on the three cells against field merge. Gate: no cell more than 2 % above today's bytes; otherwise the slot list gets a compact form (a range, or a bitmap when most rows are in it). **The slot list's form is settled before PR C's fixtures are frozen,** from the byte report on PR C's first working build, so the fixtures are generated once.

**`jsonObject`** keeps path strings and today's canonical order. Its patches are built from the row patches on demand (the key from the table, one sort per frame), as the recording digest's are.

## 4. Full views: late join, resync, key resets

**Decided (2026-11-10): a join's first view comes from a broadcast plan.** The join is held until the next one, so the joiner's first view is consistent, all as of one sync, and equal to what every other client holds after that sync. A join up to one sync interval slower is accepted.

**Today's code, as the design must read it.**
- A full view (a joiner's firstSync, a resync, an unsynced recipient's view) is a diff from empty of a snapshot extracted from the **live** state. The tables' last-sent value is only the fallback for a field whose extraction throws.
- **With in-turn sync (the default), a join already waits for a committed sync phase (#69).** The join is a turn input. Once its `OnJoin` is consumed it is ready, and the next full sync phase flips it: the plan carries its join response and its firstSync, built from the turn's end state, after everyone else's frames. A flipping joiner is not a recipient of that plan's shared broadcast frame.
- **With in-turn sync off (the legacy path),** the joiner's firstSync is its own plan between broadcast cycles (`planFirstSync`, run with `isSyncCycle: false`, reached through `syncStateForNewPlayer`). It commits no broadcast diff: live rows created since the last broadcast plan have no slot, and rows deleted since are still in the committed table.
- In a broadcast plan with the merged frame (opcode 107), an unsynced or resynced recipient gets **both** the shared broadcast frame and its own full view. A resync's snapshot is moved ahead of the shared frame, and the client then skips the shared frame's patches at that sequence; an unsynced recipient's view is not moved.

Path patches survive all of this because they are idempotent: a view built from live state can be followed by a diff from an older state. Row entries are exact, so the rule has to be exact too.

**The invariant.** A recipient's row tables equal the server's table as of the last plan whose shared row entries it has applied. A full view sends a slot-addressed table as create entries (one per row, in slot order; an empty map is still today's set of an empty object):

| Recipient | Gets this plan's shared row entries | Its view of a slot-addressed table |
|---|---|---|
| a joiner flipped by a broadcast plan (#69); a full view in combined mode | no | **the staged table:** committed, plus this plan's allocations, minus its frees, with the live rows. All of the view is as of this sync |
| merged mode: an unsynced or a resynced recipient of a broadcast plan | yes | **the committed table.** Its full view is ordered before the shared frame (an unsynced recipient's too, as resync snapshots are today), and the shared frame brings it to live |
| a table with nothing committed | either | the plan seeds it from the live state and numbers it from 0, as the tables' seeding does today |

- **A resynced client skips the shared frame's patches at the resync's sequence. Everything at or below a slot-addressed root field is exempt,** whatever its entry form. The snapshot holds the committed table with each row whole, its value maps and nested node maps included, so every change below that root in the shared frame is new to the client: row entries, and also today's-form entries for a value-map entry or a nested map inside a row. The exemption is decided by the root field a patch falls under, not by its op. Example: committed `rows/a/items/x = 1`, live `2`; the shared frame's entry for `rows/a/items/x` must apply, or the client stays at 1 while the server commits 2.
- **A row dropped from a plan** (section 1, rule 2) is not in the staged table, and views are built after the drops are settled, so no view binds it.

**No firstSync outside a broadcast plan: `rowAddressing` takes effect only where every join completes in a turn.** "In-turn sync on" is necessary and not sufficient. A join completes in a turn when both hold:
- the keeper admits it in its join: `usesInTurnSync`, which is a `.live` keeper whose transport runs the sync phase in turn;
- the caller passes a join response, which the router does. With no shared transport the adapter is the transport's delegate itself, and its own join (`finalizeJoinRequest` → `performJoin` → `completeJoinSuccess`) sends a standalone firstSync even with in-turn sync on. Hosted NIO always joins through the router.

So:
- The effective config has the feature only when the keeper is `.live`, in-turn sync is on, and joins come through the router. Otherwise the adapter runs without it (as the opcode encoders already fall back without path hashes), logs that once at startup, and does not announce the feature at join.
- **The replay land's keeper is `.reevaluation`,** so it never admits a join in its turn: its adapter runs without the feature, and replay clients get today's entries (section 6).
- A standalone firstSync plan on an adapter where the feature is in effect is a programming error: it asserts in debug builds and refuses the join otherwise.
- The legacy paths are not taught to hold joins: they are what the turn rule is retiring. `syncStateForNewPlayer` keeps today's entries for the same reason.
- `docs/transport` (both languages) and the env table say "requires in-turn sync (the default) and joins through the router" on the `ROW_ADDRESSING` row.
- Tests prove that no entry with op 6 to 9 reaches a client, with the feature requested, through a join, creates, deletes and a resync: with in-turn sync off; through the delegate join with in-turn sync on; and on the replay land.

**What the hold is, in the default path.** Nothing new is suspended: the hold is #69's.
- **Reentrancy.** The flip is a turn input. The session's ticket is captured at admission and checked in the commit's synchronous segment, with its membership re-read there; a session that left meanwhile is not flipped. The plan, the row allocation and the commit are one segment with no `await`, and no suspended function resumes to mutate keeper or table state.
- **Periodic lands.** A ready join flips at the next cadence sync, or earlier in a sync-only turn for joins when one is allowed (not when a sync is already due with the next tick, by the coincident-sync rule). The wait is at most one sync interval, plus any back-pressure deferral, which ends when a sync commits.
- **Tickless lands.** A join that becomes ready outside a turn requests a join sync turn (`requestJoinSyncTurn`), which runs a full sync phase at once; a burst of joins shares the first one's turn, up to the flip budget (`JOIN_FLIP_BUDGET`, 64 per phase). The next turn takes the rest.
- **The bound.** The join's budget (`JOIN_TIMEOUT_MS`): the flip waits for what is left of it, and a join still held when it runs out fails with a timeout and gets no state.
- **Freeze.** A frozen land defers its syncs, so a held join stays joining; its budget keeps running. On resume the deferred cycle runs without joiners, and a join sync turn then flips the joins that became ready during the freeze.
- **Land close.** The drain fails every waiting join with `landClosed`. A held join has no row tables on any side, so nothing is left to undo.

**Key-scope reset** (a firstSync frame that carries a diff, #219): the client clears its dynamic key maps and keeps its row tables, since no row is created again. Row tables are cleared only by a resync, by a joiner's first frame, and when the connection opens or closes.

**Tests for the hold:**
- a joiner's first view, decoded, equals the state every other client holds after that sync, slot tables included, in merged and in combined mode, on a periodic and on a tickless land;
- rows created and deleted between the last broadcast plan and the join: the joiner's creates use the staged slots, and the next sync's column entries apply to it and to an older client alike;
- a join held across a land close fails with `landClosed`, gets no frame, and leaves the tables as they were;
- a join held across a freeze flips after the resume, or fails by its budget;
- a join whose session leaves while held is not flipped (the ticket);
- the three no-row-entry cases above (in-turn sync off, the delegate join, the replay land).

**Cost.** With the feature on, a full view's patches for a slot-addressed table differ from the feature-off form: creates in place of one set, and, for the merged-mode recipients above, last-sent rows in place of live ones. Section 6 says what the record digests.

## 5. Per-player fields

Step 2's PR 3 (per-player policies on the tables) has not started. Until it does, per-player fields stay on today's snapshot path, and here they stay on today's entries.

When they move to tables, a per-player node map gets its own slot space per (player, table), carried in that player's frames. A field is either broadcast or per-player, so the `tableId` says which space a slot belongs to. That is noted here so the format does not close it off; it is not part of this step's PRs.

## 6. Records and replay

**No record format change.** Records hold inputs, state hashes and digests over canonical patches with string paths; they never hold frames or slots. The parent plan's 10.4 (a) stands: while recording, each row patch gets its path built from the table's key, for the digest only.

- **Broadcast and per-player digests** hash the same logical patches with the feature on or off: a create is the set at the row's path, a column set or clear is the set or delete at the leaf's path.
- **Seed digests** (a full view's patches) are where the feature can change the logical content: for merged-mode unsynced and resynced recipients, the committed table in place of live rows (section 4). A flipped joiner's seed is the live view either way. Two options:
  1. while recording, digest the feature-off form of the seed (the live view), built for the digest only. Records, goldens and the verifier's shadow are untouched. The cost is one more extraction of the recipient's view per such full view, and it runs only with a recorder attached; What the digest then checks for a seed is the logical view, and the row form actually sent is checked by the oracle (section 7), not by replay;
  2. digest what was sent, and teach the shadow the committed-table rule. That is a record version bump, regenerated goldens, and a shadow that tracks last-sent tables.

  Recommendation: 1 in this step. `SyncOutputGoldenTests` already requires the `pathIndex` and `fieldMerge` variants to record byte-identical logs, and `rowAddressing` joins that list.
- **The replay land** runs without the feature: its keeper is `.reevaluation`, so its joins do not complete in a turn (section 4), and replay clients get today's entries. If it later joins in a turn, its tables' slots follow keys (the index), so a state assigned whole every tick would not churn creates and deletes; its numbering could differ from the live run's (section 1), and nothing compares the two.
- **Reevaluation across the change:** a record made before this step replays after it with the same state hashes and sync digests, given option 1.

## 7. The equivalence oracle once bytes differ

With the feature off, frames stay byte-identical to today's, and every byte gate of step 2 keeps running. With it on, the bytes differ by design, so the check becomes decode and compare:

- **Swift, per sync and per recipient:** run the same script with the feature off and on. Decode each recipient's frames with `StateUpdateDecoder`.
  - **The decoded patch list of each sync,** canonically sorted, equals the feature-off run's. This is the main check: it catches a redundant entry, a missing one and a different granularity (a whole row in place of two leaves), which is what client callbacks see.
  - **The client state** after each sync is equal too.
  - **The slot tables** match the server's (slot, key, generation).
  - **Full views** are compared as states, not as patch lists, where section 4 makes their patches differ on purpose (the committed table); the next sync's state must then be equal.
- **Order inside a frame** is checked separately, by the byte fixtures and by a test of the emit order (section 3's order) on the decoded entries before sorting.
- **TypeScript:** the SDK decodes the Swift fixtures for the new entries and reaches the fixture's expected state; verify-views runs on a capture with the feature on.
- **Cases:** the shape matrix, Hero Defense (default and cap 100), both visibility lands; a join held until a broadcast plan, with rows created and deleted since the last one; a resync, a failed firstSync and a flipping joiner in the middle of a script, in merged and in combined mode; a failed plan that deletes one key and creates another; a value that does not encode (its row is dropped from the plan, the rest of the table proceeds, and the row is retried), and one that never encodes (the table keeps moving; a land without periodic sync gets its retry); a resync while a value map inside a row has changed since the committed table (the shared frame's entry below the slot-addressed root is applied, not skipped); a recipient whose frame is not sent (resynced by the next plan); a slot freed and taken again (generation); a column clear; a `""` key; an NFC and NFD pair of one key.
- **Strictness:** a column on an unbound slot, a delete on an unbound slot and a create on a bound slot each fail in both decoders.

**What decode-and-compare still cannot catch that the byte check could:**
- a larger encoding of the same value (an integer width, a positional versus keyed atomic value);
- anything in a frame the decoders ignore.

**What covers those:** byte fixtures for the new entries (golden frames checked in, decoded by both decoders), and bytes per sync reported per PR.

## 8. Wire bugs folded in

- **#205, the empty-string key.** The drop itself was fixed by #294 (the split keeps empty components). What is left: a create entry round-trips `""` in the Swift and TypeScript decoders (tests in both), the stale comment in `view-pointer-escaping.test.ts` is corrected, and the issue is closed with a pointer to #294.
- **#446, NFC keys on the wire (decided 2026-11-10).** Map keys are normalized to NFC when they are converted for the wire, with an ASCII fast path, in every encoding. Its own PR, first, since it changes today's entries too.
  - **Sites:** `makeKeyString` is one of about a dozen. `SnapshotValue.make` has seven typed fast paths and a `Mirror` path; `makeFull` has three; the tables have `syncTableKeyString`. One internal helper serves all of them.
  - Swift's `String ==` already treats the two spellings as one key, so the server holds one entry today; only the spelling on the wire changes.
  - **Who can see it:** a client that compares key bytes, and replay hashes of runs with non-NFC keys.
  - **A hand-written `toSnapshotValue()`** that builds its own object from a dictionary does not pass the helper. It is documented: such a type writes NFC keys. No per-key check in the encoders.
  - It removes step 2's one byte-identity exception (a respelled value-map key), and the tables' respelling code with it.
  - **Fixtures:** only `ShapeMatrix/shape-matrix.json` holds an NFD key (text and two base64 frames). No sync-output golden, record, field-merge fixture, load-test capture or CLI scenario does, so no replay hash in the repository changes (the goldens' version string does; see the record version below). Its consumers change in the same commit: `ShapeMatrixRoundTripTests`, `SyncTablesLandCellTests`, the SDK's `view-shape-matrix.test.ts` and the CLI's schema conformance script.
  - **Tests:** every site with an NFD key; a respelled key (NFC removed, NFD inserted, with a value change) gives one patch under the NFC path and one key on the client, in both diffs and all three encodings; ASCII frames and goldens unchanged.
- **The record version goes to 3.3 with PR A** (a minor bump, as earlier shape-limited changes got: 2.3 for #175, 2.6 for #179).
  - Modeled on 2.3: a record older than 3.3 that holds a non-NFC key or ID is reported as not comparable, not as a mismatch. The reader checks for one while reading.
  - Costs: a reader refuses a newer minor, so a 3.3 record does not load in an older build; and every record's version string changes, so the sync-output goldens (`.sstr`, `.reeval.json`) are regenerated in PR A, with their consumers, though no hash in them changes.
- **`PlayerID` is NFC from creation (decided 2026-11-10).** Without it, a non-NFC ID would be NFC as a map key and unchanged as a value, and a JavaScript client's `players[event.playerID]` would miss.
  - **Where a `PlayerID` is created:** the type has three initializers, and every one of the roughly 25 creation sites in `Sources` goes through them: `init(_:)` (the join path's `PlayerID(session.playerID)`, the admin route's query parameter, the recorder's targets, tests and benchmarks), `init(from:)` (every `Codable` decode: payloads, records, the replay land's state) and `init?(codingKey:)` (dictionary keys, which calls `init(_:)`). Normalizing in the first two, with the ASCII fast path, covers all of them in one file.
  - **A stored ID can then differ in bytes from the spelling the client sent.** The join response carries the player ID, and the SDK already replaces its own with the server's ("may differ from initial playerID"), so the client gets the normalized one. The PR checks that the response is built from the stored ID.
  - **`playerSlot` moves only for a non-NFC ID** (never for an ASCII one): the slot is an FNV hash of the ID's raw UTF-8 bytes (`allocatePlayerSlot`), so a normalized ID can get another slot. The slot test gets a non-ASCII ID. A scan of the tracked fixtures, scenarios, goldens and result files finds non-NFC text only in the shape-matrix fixture's key, so no measured or recorded scenario in the repository has such an ID (binary record files were scanned for the NFD bytes only).
  - **Cost:** the ASCII check in `init(from:)` runs on every decoded payload that holds a `PlayerID`; PR A reports it.
  - **Records:** a record made earlier with a non-NFC ID decodes to the NFC one, so only such a record's hashes change.
  - **Tests:** an NFD ID through join (the response returns NFC), as a map key and as a value in state, in an event payload and a targeted event, in the log metadata and in a record round trip; two sessions joining with the NFC and the NFD spelling are one player.
  - If the creation sites turn out to need more than the initializers, it becomes a sibling PR of A.

## 9. PR split

Each PR targets `exp/next`. Numbers are Mac direction numbers per PR; the bar is judged on the measurement host at the end.

| PR | Content | Wire | Buckets it removes |
|---|---|---|---|
| A | #446: NFC keys, and `PlayerID` NFC at creation | changes non-NFC keys and IDs only | none (removes the respelling path) |
| B | Slotted last-sent tables, staged allocation, and each emitted patch tagged with its leaf and slot (no bitmaps, see the amendment in section 14); the emit still produces today's patches, in today's order | byte-identical | none. After a slot is reused, slot order is not key order, so the key sort stays while the feature is off |
| C (three PRs, see section 15) | `rowAddressing` (default off): the four entries, both Swift encoders, the Swift decoder, the TypeScript SDK, full views by section 4's rule, the drop and resync rules of section 1, fixtures, the oracle, #205's tests | new entries behind the feature | path strings (~45), encoder planning for rows (most of ~198), the atomic-layout path lookup (~84; the layout is looked up once per field) |
| D | The other decoders and tools: ws-loadtest's key tracker, verify-views' capture header, the benchmark's feature flag; E2E in all three encodings with the feature on | none | none |
| E | Typed conversion: a column's values are written from the native values by a per-field writer, without a `SnapshotValue` | byte-identical to C | conversion (~201) for column values |
| F | The default flips on | default changes | none |

- **B before C** keeps the allocation rule reviewable on its own, under the byte gates that exist. B reports its number with the tables on and the feature off against #465's (gate: no more than 2 % above it), since it adds the index and the bitmaps and removes nothing yet.
- **Typed conversion (E) is in this step** because the format alone may not clear the bar (section 0), and a column of one field type is where a typed writer is simplest. If C's number already clears 50 % with margin, E moves after the bar is judged.
- **The old forms stay** until a later removal, as for `pathIndex`.

**Docs with this step** (both languages):
- `docs/core/sync`: map keys and `PlayerID` are NFC; a hand-written `toSnapshotValue()` writes NFC keys (PR A);
- `docs/transport`: the `ROW_ADDRESSING` row with its requirement (section 4), the new entries, and the strict decoder rule (PR C);
- `docs/transport`, on encodings: `json` mode emits sorted keys and costs more CPU than MessagePack; use MessagePack in production. Decided 2026-11-10 with the canonical order's measurement: the `json` cost is accepted and `.sortedKeys` stays.

**Gates** (parent plan section 11, step 3): byte fixtures for the new entries; the old forms' fixtures unchanged with the feature off; the oracle (section 7); verify-views and E2E convergence in all three encodings; the sync-output goldens and the replay hash unchanged; bytes and CPU per PR.

## 10. Follow-up: rolling back a throwing input (#87, option A)

After the format PRs. The decision: roll back a throwing input's writes with an undo log of old field values on the tables' change tracking, not a whole-state savepoint.

**What the tables track.** The tables are on the sync side (step 2, section 1), so the live state's change tracking is `@Sync`'s dirty flag per root field. The log hangs there:
- While an input that can throw is running (an action, a client event, a lifecycle handler), the first write to a root field in that input records the field's old value and its old dirty flag.
- On a throw, each recorded field is put back, value and flag. A rolled-back field is clean unless something before this input wrote it.
- Ticks and other non-throwing turns never arm the log.

**Cost with no throw:**
- unarmed (ticks): one branch per write;
- armed: per first write of a field, one retain of the old value. For a collection, the write that follows copies its buffer once, because the log holds the other reference. That is one copy of the written collection per throwing-capable input that writes it, not of the whole state.

**This is the point to confirm.** The decision on #87 rejected a whole-state savepoint because of "a collection copy on each input's first write". Under copy-on-write a whole-state savepoint also copies only the buffers written after it. So the per-field log pays the same collection copy the savepoint would; what it saves is the retain and the restore of the fields the input does not touch. A row-level log would need the live state to be tables (the parent plan's option that step 2 set aside), since a write through `state.monsters[id]` reaches `@Sync` as a write of the whole dictionary.

- An earlier plan (`2026-11-05-layer3-prs.md`) records that copy-on-write savepoints cost about nothing "because of #94". The follow-up PR checks whether that still holds now that the tables keep their own last-sent copies (the live buffers are then uniquely referenced between syncs, so a savepoint's reference is what makes the first write copy).
- **The follow-up PR measures both in one place:** the per-field log and a whole-state savepoint, armed and unarmed, on Hero Defense's actions and on a land with a large map written by an action.
- If the copy shows, the choice between accepting it, a savepoint, and keeping (B) goes back to the maintainer. This is one of the two open items in the decisions table.

**The value-semantics contract.** A class instance inside a `@Sync` field is shared by the log's copy, so its mutations are not undone. #464 refuses classes in synced state at registration; once it lands, that case is refused. Until then it is documented as not rolled back. If the PR touches the `Mirror` paths #464 changes, it merges `exp/next` after #464.

**`@Internal` fields.** `@Internal` is a wrapper with a plain stored value and no dirty flag. Options:
1. the same log on its setter (one branch per write when unarmed; the same copy rule when armed);
2. documented as kept.

Recommendation: 1. A handler that updates a counter in `@Internal` and a row in `@Sync` should not end half applied. Its cost is measured with the rest.

**The recorder** must not record a rolled-back input as applied (#87).

## 11. Follow-up: a compile-time warning for a synced value that is not `Equatable`

Today such a field silently takes the fallback (the tree diff). The maintainer's decision: a warning, not an error.

**Mechanism to prototype first.** `@StateNodeBuilder` already emits one `SyncTableField.make` call per `@Sync` field, and that overload set picks the field's shape at compile time. The preferred form splits its value overload in two:
- `make<V: Equatable>`: the typed path, with the conformance known statically;
- `make<V>`, marked `@available(*, deprecated, message: "this @Sync value is not Equatable, so it is diffed by the slower tree diff")`: the fallback.

No new public name. The message is fixed text, which is acceptable if the warning lands on the user's field line. The fallback form, if it does not or if an ambiguity cannot be solved: per-field private check functions emitted by the macro, with the field and its type in the message. A `.serverOnly` field never warns.

**The prototype answers:**
- ambiguity for a type that is both a node and `Equatable` (a combined overload);
- optionals, dictionaries and arrays of such types;
- that `@Internal` and `.serverOnly` fields are not checked;
- where the warning lands (the field's line or the macro's), and what it says for a generic field type;
- the build under warnings-as-errors: source-compatible, but such a build fails until the type conforms.

**Also considered:** a reason string per fallback field in a debug log, once per field at land registration. `SyncTableField.fallbackReason` already holds it; it is cheap and independent, and can land with the warning.

**Recommendation on turning it into an error:** not in this step. The fallback is correct, only slower, and an error would break lands that sync a non-`Equatable` type they do not own.

## 12. Public API

All additive:
- `StateUpdateFeature.rowAddressing`, added to `StateUpdateFeature.supported`; `TransportEncodingConfig.rowAddressing` (default off until PR F), reported by `stateUpdateFeatures`;
- the env key `ROW_ADDRESSING`, read through the env helpers; it takes effect only where every join completes in a turn (section 4);
- the Swift decoders read the new entries; no signature changes;
- TypeScript: `SUPPORTED_STATE_UPDATE_FEATURES` gains `rowAddressing`. `StateTreeView`'s API and the generated client code do not change: the decoder turns row entries into the path patches the view applies today;
- section 11's warning: a second `SyncTableField.make` overload for `Equatable` values (the existing unconstrained one becomes deprecated); no new name.

Behaviour changes, each decided separately: #446 and `PlayerID` normalized at creation (section 8), and #87 A (section 10).

## 13. Not in this step

- Slots for nested node maps, value maps and per-player tables (sections 2 and 5).
- Row visibility per recipient (section 1).
- Applying row entries in the SDK without building paths. The decoder builds one path per changed value, as today; a direct apply is a client-side optimization, to be weighed with `time-decode`.
- Removing today's entry forms or the dynamic key table.
- Live table storage.

## 14. Amendment (2026-11-10, before PR B)

Settled while preparing PR B. None of it changes the wire, the public API or a measured path's design.

1. **No bitmaps in PR B.** Section 2 says a changed leaf sets the row's bit in a per-leaf bitmap, and the emit walks the bitmaps. PR B's output is still today's patches in today's order, which is row by row (a row's patches together, rows by key bytes); a bitmap walk is leaf by leaf. Bitmaps in B would be filled and read by nothing.
   - **In B:** each patch the typed diff emits inside a slot-addressed row is tagged with its leaf (the path id of its pattern, when the encoder has a path table) and its slot. Section 2's storage list is the same without its last item.
   - **In C:** the column entries are built from the tagged list, or from bitmaps filled from it, whichever the PR's numbers favour. C states the choice.
   - A patch that is not a leaf (below a value map or a nested node map inside a row, or from a fallback field) has no tag and stays today's entry, as section 3's table says.
2. **A create never takes a slot its own plan frees.** Section 1 already says a freed slot can be taken "from the next sync on, never in the same frame as its delete"; this states the reason and the commit order. A frame's order per table is creates, columns, deletes (section 3), and a delete carries no generation, so a create in a slot the same frame deletes would be created and then deleted by a client applying the frame in order.
   - The commit applies creates first (lowest slot among those free before the plan, in key-byte order), then updates, then deletes, whose slots are free from the next plan on.
   - The cost: one more slot of high-water mark when a row is replaced under another key in one sync.
   - A key on both sides of a diff is a matched row and keeps its slot; it never reaches allocation.
3. **Allocation is a pure function** of the committed table and a plan's staged creates and deletes. PR C writes slot numbers on the wire before the commit, so the plan computes them without changing the table.
   - **The commit applies the planned assignment, it does not allocate again.** Section 1's per-row drop can remove a create after its slot was written into the frame. Allocating again without it would shift the creates after it: with slots 3 and 5 free and new keys a and b, the frame says a at 3 and b at 5; if a's create is dropped, a second allocation would put b at 3, while every client holds b at 5.
   - So the commit takes each kept create's planned slot. A dropped create's slot stays free, and its row is created by a later plan.
   - In debug builds the commit asserts that its slots equal the function's when nothing was dropped.
   - PR B ships the function and tests: the commit lands on the planned slots; a failed plan leaves slots, generations and the free list untouched; a dropped create between two kept creates leaves the kept ones where the frame put them.
4. **A seed sorts its keys once** (section 1, seeding): the one sort PR B adds over step 2. It runs when a table is seeded whole, not per sync.
5. **No compaction.** A table keeps its high-water mark of slots after it shrinks (`rows` holds an optional per slot). Sessions run for tens of minutes, so this step does not compact; a later step can, with a wire form for moving a row.
6. **Only a root field's last-sent store changes.** A node map nested inside a row keeps its native map and today's diff (section 2), so the row walk serves both stores.

## 15. Amendment (2026-11-10, before PR C)

Settled while preparing PR C, from a reading of the encoders, the decoders, the SDK and the join negotiation.

1. **PR C is three PRs.**

   | PR | Content | Reachable from a server |
   |---|---|---|
   | C1 | The four entries in both opcode encoders; the Swift decoder (ops 6 to 9, the strict rules, a MessagePack front); the config flag; golden frames; the byte report on the three cells, which settles the slot list's form (section 3) | no: nothing puts the flag in effect |
   | C2 | The adapter: the effective feature (point 4), staged row plans with per-row drops, the order inside a plan, full views (section 4), the resync rules, the retry; the Swift oracle (section 7) | yes, default off |
   | C3 | The SDK: the entries, row tables, the strict close, the resync skip per patch, the fixtures, verify-views | the client side |

   C3 needs only C1's fixtures and can follow it directly. The gates of section 9 apply to the three together; each PR reports what it can measure.

2. **The generation travels on the patch's split.** PR B's tags give the encoder the slot (`rowSlot`) and, through the pattern hash, the table or leaf id. The create entry also needs the slot's generation, which is the table's. The split gets it for creates only, set where the diff plans the create's slot. The encoder is not handed the table.
   - **How the encoder tells the forms apart, with no list of a row's patterns:** a tagged patch with one dynamic key at the row's own pattern is a create (a set that carries a generation) or a delete; a tagged patch below it with one dynamic key is a column set or clear; a patch with two or more dynamic keys, or with no tag, is today's entry.
   - **The generation is what marks a create.** Today's differs compare a matched row field by field, so a set at a row's own pattern is only ever a new row. A set there without a generation (a later differ that replaces a matched row whole) is not read as a create on a bound slot: it stays today's entry.
   - **This corrects point 1 of section 14,** which says a fallback field's patches have no tag. As built, PR B tags every patch at or below a row that has a split, whichever differ made it, and a fallback field's patches get their splits from the same cursor. So a fallback field's patch inside a row is a column when its path has the row's key as its only dynamic key and its pattern is in the schema (it then has a path id), and today's entry otherwise (no split, or a second dynamic key). Section 3's table already lists an array or a struct replaced whole as a column set. C1's golden frames hold one row with a fallback field.
   - Section 14's point 3 says the commit asserts equality with the function when nothing was dropped. As built, a plan records how many creates its slots were planned for, and the commit asserts that its slots are an in-order part of what the table plans for that many: equal when nothing was dropped, and still checked when rows were.

3. **The Swift decoder gets a MessagePack front, in C1.** Today it reads the opcode JSON array only, keeps one dynamic key table for every scope and never clears it. The oracle decodes each recipient's frames, and the merged mode's are MessagePack with the broadcast frame inside opcode 107. So the decoder gains:
   - a MessagePack input that feeds the same entry reader, with the 107 frame;
   - a key table per scope (broadcast and per player), cleared by a firstSync and by a resync, as the SDK does;
   - row tables (slot to key, and the last generation per slot), with section 1's strict rules.

   Package-level, for tests and tools. No public API.
   - **Both decoders read the op before the second element.** Today both read the second element as dynamic keys, and apply its key definitions, before they look at the op. In a row entry that element is a slot or a slot list.
   - **The SDK refuses a row entry when the feature was not negotiated** (it knows the join response). The Swift decoder does not check: it is a test tool with no join.

4. **The router announces the feature the adapter has in effect.** Today the feature list is computed from the configuration and the path hashes alone, in the land manager, the adapter, the router and the NIO server, and the router's join check and join response use its own copy.
   - Section 4 makes `rowAddressing` depend on more: a `.live` keeper, in-turn sync, and joins through the router. Only the adapter knows the first two.
   - So the adapter computes its effective list at registration (the configuration's, minus `rowAddressing` when a condition does not hold) and logs it once. The router's check before a land exists uses the configuration's list without `rowAddressing`: a client is never required to declare it. The join response carries the adapter's effective list, read in the join's turn.
   - **Open, to settle before C2: a client that does not declare `rowAddressing`.** Section 3 says it "gets today's entries". Section 1 says row entries are encoded once per plan, the same bytes for every recipient. Both cannot hold on one land.
     - **(a) The feature is required where it is in effect,** as `pathIndex` and `fieldMerge` are: the land's own join check refuses a client without it (the router's early check cannot know). One encoding per plan. An older SDK cannot join such a land, so the default (PR F) flips only after the SDK with C3 is out. Recommended.
     - **(b) Both forms per plan,** one for each kind of recipient: two encodings of the broadcast diff, and two sets of key tables, on every plan with mixed clients.
     - With (a), section 3's sentence becomes "a land without the feature in effect sends today's entries".
     - **Why (a) is more than a preference:** a decoder that does not know row entries reads their second element as dynamic key definitions before it looks at the op. A client that did not declare the feature would not skip a row entry: it would write a slot or a slot list into its key table and resolve every later entry wrong, with no error. So a land with the feature in effect must not send to such a client. Downgrading the land when one joins would change the encoding in the middle of a session and resync everyone; it is not an option.
     - **With (a), the refusal:** in the land's join check, before admission, so no player, slot or session state is created; with the error a `pathIndex` or `fieldMerge` mismatch gives (`joinStateUpdateFeatureMissing`, with the required and missing lists); a land created on demand for the refused join is left to its destroy-when-empty.
     - **Test:** a client without the feature is refused by a land that has it in effect and accepted by one that does not (the replay land).
   - **How the adapter knows that joins come through the router:** the land manager creates the adapter, per land, and knows whether it was given a shared transport. With one, the router owns the transport's delegate and every join; without one, the adapter is the delegate and runs its own join. The manager passes that to the adapter when it creates it, and the adapter computes its effective list then, once.
   - `rowAddressing` requires `pathIndex` and `syncSequence`: without either, the effective list drops it. This is the first requirement between features; it lives in one function, with a test.
   - **Every client that must declare the feature under (a),** or a land with it in effect refuses its join:
     - the SDK's list (`SUPPORTED_STATE_UPDATE_FEATURES`), from which the CLI's client and the example web clients take theirs: C3;
     - the load-test client, which builds its own join with a fixed list and reads the join response's features in its capture, reconstruction, decode-timing and view-verification tools: PR D, on the C3 SDK. **No measurement round runs with the feature on before D.**

5. **A row that does not encode, in opcode JSON.** A value fails there only inside the JSON encoder (a non-finite number). The success path does not trial-encode each row: when a frame's encoding fails, the failing rows are found, dropped from the plan (section 1, rule 2), and the row entries are built again without them, once, before any view or frame. Frames are enqueued at commit, so nothing has been sent.
   - **If the rebuilt entries fail again,** or the value that failed is not in a slot-addressed row (a non-finite number in a root value field), that is today's failure for that frame, handled and counted as it is today.
   - **A dropped column value leaves the row's last-sent where the clients are,** so each later plan diffs the row again and sends it once it encodes. That is the retry; the table's other rows are never held back.
   - **The retry count** on a land without periodic sync is the failed plans' (`syncFailedPlanFollowUpLimit`). A plan that only dropped rows counts as a success for everything else, and does not reset that count: a row that never encodes stops being retried at the limit, until the next input.

