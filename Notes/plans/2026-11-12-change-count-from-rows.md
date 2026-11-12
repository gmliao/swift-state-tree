# Change-object metrics on the sync tables without a broadcast snapshot

**Line numbers** are at `main` e4abe9ce.

**Status:** reviewed (one round and a delta check), GO. Not started.

**Goal:** with the sync tables in effect, the change-object metric (TransportAdapter.swift:4622–4638) stops extracting a broadcast snapshot of every root field each sampled sync. The auto dirty switch stays (its removal is step 2's PR 4). The switch must flip at exactly the syncs it flips at today, so the metric's two numbers, changed objects and estimated total, must stay equal on every sync.

**Why:** on Hero Defense cap100 with the tables (router, rows, messagepack, Mac profile at f9afa924), that extraction is 37 % of sync samples and the metric's key derivation another 11 %. `AUTO_DIRTY_SAMPLE_EVERY` defaults to 1, so this runs on every sync.

## 1. What the metric computes today

`DirtyTrackingMetrics.calculate` (DirtyTrackingMetrics.swift:76–121) takes the sync's updates and a broadcast snapshot:
- **Changed objects:** the distinct keys `objectKeyFromPatchPath(patch.path, snapshot)` (TransportAdapter.swift:5714) over every patch of every update: the merged broadcast update (:4537) and each recipient's pending update (:4623), first-sync views included.
- **Total:** `max(estimateTotalSyncObjects(snapshot), changed)` (:5697).
- **The snapshot** holds the root fields the sync's broadcast mode covers (every dirty field, or every field), and on the tables it's extracted for the metric alone (:4631), with last-sent standing in for a field that throws.

The two helpers depend on the snapshot's shape:
- `isLikelyCollectionObject(object)` (:5681): non-empty, and at least half its entries are `.object` or `.array`.
- **Total:** per root field in the snapshot, the entry count of a "collection" object, else 1.
- **Key** of a patch at `/top/second/…`: `/top` when `top` isn't in the snapshot; `/top/second` when the child is an object or array, or when the field is a collection; else `/top`.

## 2. The rule for a root map of nodes

A root map of nodes (`SyncNodeMapRootSlot`: Hero Defense's `players`, `monsters` and `turrets`) has a fixed shape. Every entry is a node, and a node's snapshot is always `.object`, even when empty or all server-only (`SnapshotValue.swift:236–243`). So for such a field `F`, today's two helpers depend only on whether `F` is in the metric snapshot and on its entry count `n`.

**The key.** It is the same string today's helper produces, from the same segmentation, inserted into the same `Set<String>` as every other key:
- **Segmentation:** `path.split(separator: "/", omittingEmptySubsequences: true)`, as `objectKeyFromPatchPath` does (TransportAdapter.swift:5716).
- **`F` absent from the snapshot:** `/F`.
- **`F` present with `n > 0`:** `/F/<second segment>` when there are at least two segments (an existing child is an object, a missing one falls to the collection test), else `/F`.
- **`F` present with `n == 0`:** `/F`.

It is never derived from the row slot. Today's quirks are then kept as they are:
- **An empty key:** row `""`'s `/F//hp` and `/F//pos` give `/F/hp` and `/F/pos`, and `/F/` gives `/F`. These can collide with a real row named `hp`.
- **Escaped keys** (`~0`, `~1`) stay escaped.
- **Two Unicode spellings of one key** fall into one `Set<String>` entry by `String`'s canonical equivalence.

A shortcut that skips the split is out of scope. The split is the per-patch cost left after this PR.

**Absent or present, and `n`.** The metric snapshot today is a whole-field extraction of `F` (:4631, `extractDroppingThrowingFields`, SyncEngine.swift:1422–1433). So the state is:
- **Absent:**
  - when the mode leaves `F` out;
  - when that extraction throws for `F` and the fallback, the table's `lastSentSnapshot(of: F)`, is nil. That happens when the slot is unseeded, or when `try? differ.convert(last.dictionary)` fails (SyncTables.swift, `SyncNodeMapRootSlot`). Today the field is then omitted: +0, key `/F`.
- **Present from last-sent:** when the extraction throws and last-sent converts. `n` is the number of entries of that converted object.
- **Present from the live state:** otherwise. `n` is the number of distinct key strings of the converted map.

**Making the trigger and `n` exact without converting:**
- **The trigger.** The extraction throws for `F` exactly when some entry of `read(state)` fails to convert. The table's diff converts only the rows it visits, so "the diff dropped `F`" is not the same trigger. Converting every entry to test it would be the very cost this PR removes, so the trigger comes from elsewhere:
  - **(a)** Use the diff's own `ExtractionDrops` entry for `F`, valid only when conversion is a pure function of the value. A row the diff didn't visit converted when it was last diffed, and an unchanged value converts the same way again. The tables already rest on this assumption: last-sent is the diff's baseline, and a row isn't converted again until it changes. Under it, a pure conversion can't throw on a row the diff doesn't revisit. Only an impure one can, for example one that throws from sync k on an unchanged value. There (a) and today really differ: today takes last-sent or absent, and (a) takes the live `n`. One test documents that divergence: it asserts the known difference and names the assumption. It is not an equality case.
  - **(b)** If that assumption is rejected in review, the fallback is to convert `F` whole on a sampled sync only. That keeps today's cost for `F` on those syncs.

  Chosen: (a).
- **`n` from the live state:**
  - `read(state)` is the policy-filtered value the extraction converts, never the raw stored map.
  - Its `count` equals the number of distinct key strings only when `K → key string` is injective, which is true for `Int`, `PlayerID` and `String`. It isn't guaranteed for every `K` (two `String` keys in two Unicode spellings are one `Swift` key already; a custom `K` could print alike).
  - So `n` is the count of the distinct key strings the slot's `keyString` gives. That is the same function the converted map's keys come from, and it allocates one `Set<String>` per field instead of a converted tree.
  - A debug assertion compares `n` with the snapshot's key count on a sampled sync.
- **`n` from last-sent:** the number of entries in `lastSentSnapshot(of: F)`. This conversion happens only on a sync whose extraction for `F` throws, as today.

The differential test (section 5) checks every case on every sync.

## 3. Every other root field: today's code on a smaller snapshot

Value fields, optional nodes, node fields, value maps and fallback fields keep today's helpers on a snapshot of just those fields. That's `extractBroadcastSnapshot(mode: .include(modeFields − rowFields), broadcastLastSent:)`, the call at :4631 with fewer fields. Their shape can depend on runtime values: an optional that is nil is `.null`, and the half-nested test counts that. So this PR doesn't reproduce their shape by type.

Hero Defense's other broadcast fields are `base` (a node) and `score` (an `Int`), and `nextMonsterID`/`nextTurretID` are server-only. So the extraction there shrinks to two small fields.

## 4. Per-player fields, first-sync views, sampling, the log line

- **The rule is chosen per patch, never per update.** A patch's root field (its first segment) picks the rule:
  - section 2 when that field is a root node map, present or absent as the actual broadcast mode and extraction say;
  - today's helper on section 3's snapshot otherwise.
  Every update goes through the same dispatch: the merged broadcast update, per-player updates, and the first-sync and resync full views appended at :4623, which carry broadcast `/F/k/…` paths. A first-sync view with two changed rows of `F` gives two keys when `F` is present with `n > 0`, and one (`/F`) when the mode leaves `F` out, as today.
- **Per-player fields** are never in the broadcast snapshot, since a field has one policy. So a per-player patch's key is `/top` by today's helper on section 3's snapshot, unchanged. A cheaper first-segment key is exact too, but it's left for later.
- **No root field outside the node maps in the mode:** the section 3 extraction call is skipped.
- **Sampling** (`AUTO_DIRTY_SAMPLE_EVERY`, default 1) is unchanged, as are `countsChangeMetricsSync` and the thresholds.
- **The log line** (`ENABLE_CHANGE_OBJECT_METRICS`) prints the same numbers.
- **Unchanged:** the metric still runs whenever `enableChangeObjectMetrics || enableAutoDirtyTracking`. #416's mode-dependent denominator is kept, because this PR keeps the switch's behavior. Fixing it is step 2's PR 4 or #379 stage 1.
- **Off the tables** nothing changes: the metric keeps the sync's own snapshot.

## 5. Gates

**Differential test (the equality proof).** For each sync of a random mutation sequence, compute `(changedObjects, estimatedTotalObjects)` twice:
- today's, from the full metric snapshot (:4631's extraction) and the sync's updates;
- the new one, from section 2 for the node map fields and section 3 for the rest.

They must be equal on every sync. Coverage:
- **States:** the step-2 differential's states: `HeroDefenseState`, `ShapeMatrixState`, `VisibilityTestState`, and the `NestedNodePolicyTests` and `FullStateHashTests` states.
- **Modes:** dirty tracking on and off.
- **Row cases:** removing every row of a map (`n` goes to 0), a row removed and another created in one sync, and keys in two Unicode spellings (as the step-2 differential does).
- **Drop cases:** a field whose conversion throws, and a row repair (`droppingRows`), which removes patches before the metric.

**Explicit cases**, beside the random sequences (which are evidence, not proof):
- **Empty key:**
  - row `""` created, a nested field of it changed, and the row deleted;
  - next to a row named after a node field (`hp`).
- **Escaped keys** (`~0`, `~1`) and **Unicode-equivalent spellings** of one key.
- **Emptying a map** (`n` goes to 0), and a row removed and another created in one sync.
- **Throws:**
  - before `F`'s first seed (absent, +0);
  - after it (present from last-sent);
  - the documented divergence (section 2, (a)): an impure conversion that throws from sync k on an unchanged row. The test asserts the known difference, not equality.
- **First-sync and resync views:** a view with two rows, with `F` in the mode and out of it.
- **Dirty mode transitions** (#416): on, off and on again within a sequence.

Both numbers are compared on every sampled sync, then the EMA and the switch syncs.

**The old computation stays as the oracle.** The full-snapshot metric stays reachable under a package switch, used by the differential test and the adapter test. It is not removed after: it's the only reference. Step 2's PR 4 removes both when the metric itself goes.

**Adapter test.** With the tables on and auto dirty tracking on, a run with the new metric and one with the oracle produce the same `changeRateEma` sequence and the same switch syncs. The full metric snapshot is never extracted for a node map field on the new path.

**Debug assertion.** Today `broadcastCacheRetired` (SyncEngine.swift:50–54, :98) asserts that nothing reads or writes `lastBroadcastSnapshot` on the tables. This PR adds that, on the tables, the metric's extraction covers no root node map field (an assert on the include set).

**Measurement.**
- **Mac:** a profile at the bar cell, for the split only: the metric's extraction gone from the node map fields.
- **Host:** an A/B against main, ABBA, with the auto switch on (the default), on cap100-rows and cap100-tables, mp and json.
  - **Judged on `syncMs`.** The metric is inside the sync.
  - **Regression bar:** head's `syncMs` median no more than max(2 %, base's spread) above base's, the spread measured as base's min..max over its runs. This is the same rule as the layout-node lookup plan.
  - **The same `AUTO_DIRTY_*` environment on both sides,** recorded in the brief and in each run's metadata, so the flip-sync logs compare.
  - Bytes identical; the switch's flip syncs logged and identical.

## 6. Scope and order

- **One core PR against main,** independent of #513. Sources and Tests only.
- **New lessons:** a solutions entry if the differential test finds a quirk.
- **Consulted:**
  - `Notes/solutions/2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md`: a replacement must match the old code on random sequences, not on hand cases.
  - `Notes/solutions/2026-11-10-a-rewritten-extraction-must-keep-the-empty-result-rule.md`: empty entry vs no entry. Here the analogue is an empty map, which counts 1 and is keyed `/F`, against a field the mode leaves out, which counts 0. The differential test covers both.

## 7. Choices named for the maintainer

1. **Exact (this plan) or rows-only.** Rows-only would count every root field by type, with no extraction at all. It differs from today on:
   - a node field at least half of whose fields are objects or arrays (counted as entries today, 1 by type);
   - optionals and value maps of objects (the half-nested test reads runtime nils);
   - the empty-map rule.
   So the switch could flip at different syncs. Frames don't depend on the mode (#415's test), so this would change CPU only, not output. Provisional choice: exact, so behavior doesn't change before PR 4 replaces the metric anyway.
2. **Per-player key shortcut:** left out (section 4).
