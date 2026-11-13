# A patch's path built on demand from its split (#392, the remaining step)

**Status:** rev 3, for review. No code. Read at `main` 746fe207. Each fact is marked **checked** (read in the code) or **inferred** (reasoned, to be pinned by a test in the PR). Scope and gate: #392's comment of 2026-11-13 ("Next step (decided)").

- **Rev 3** answers review of rev 2 (d12abe7e):
  - a lossy literal keeps today's stored pair (string plus split), so row metadata and the wire stay (§2.1);
  - the lazy path reaches through `AtomicPositionalForm`'s recursion (§1.3, §2.5);
  - `mergePatches`' per-player duplicates (§1.3, §2.4);
  - the prefix cache's own counters instead of `--merge-stats`, and a 100-player cell (§4);
  - the rebuild counter is separate from DEBUG readers (§2.5, §4);
  - a lossy ancestor above a walk-off, and the templates' sharing and memory (§2.2);
  - the lossy example is the NFC/NFD case, not `a~1b` (§2.1, §4).
- **Rev 2** answered review of rev 1 (1854f58b):
  - every encoder call site that passes `patch.path` as an argument is a hot reader, and becomes lazy (§1.3, §2.5);
  - two identity contracts, kept apart: the frame cache's UTF-8 bytes, and the merge's and `==`'s `String` equality (§1.4, §2.3, §2.4);
  - reconstruction is defined as lossless only where the emit's literal bytes equal the template's, and is the string form otherwise (§2.1);
  - walk-off rebuilds from a node template (§2.2);
  - the retag at SyncTables :880 and the full-view and digest readers (§1.3, §2.5);
  - concrete A/B cells (§4);
  - more mutants (§4);
  - Q1–Q4 decided (§5);
  - the per-player follow-up is #547 (§3).

**Summary.** `StatePatch.path` is a stored string that every typed emit builds next to the split it already has. This change makes the split the stored form and builds `path` only when a reader asks. The wire doesn't change. The work saved:
- the per-level string building in the typed diff;
- on the opcode encodings, the path strings the encoders build or compare per patch per frame, now that those readers take the split.

## 1. What is there now

### 1.1 The patch and the split (checked)

- `StatePatch` (`Sources/SwiftStateTree/Sync/StatePatch.swift:71`): `public let path: String`, `operation`, and `package let split: PatchSplit?`. `==` and `Codable` use `path` and `operation` only.
- `PatchSplit` (`Core/PathHasher.swift:213`): `pathHash: UInt32`, `dynamicKeys: [String]`, `row: PatchRow?`, `owner: PathHasherIdentity`.
  - `pathHash` is the full pattern's hash, also for a row-tagged split: `asRow` keeps it and adds `PatchRow(table: pathHash, …)` (:227).
  - The keys are the path's own components as the emit spelled them, escaped (`Cursor.descending`, :270).
- `PathHasherIdentity` (:207) is an empty final class that every split references. `PathHasher` is a struct; `hashToPath: [UInt32: String]` is immutable after init (:25).
- Pattern hashes can't collide: `hashToPath` is built with `Dictionary(uniqueKeysWithValues:)` (:49), which traps on a duplicate. So `pathHash` names one pattern.
- The trie stores each literal label as the pattern spells it (`insert`, :61–:80), and `Cursor.descending` looks up the escaped component (:270–:279).
  - So a hand-written pattern label `a~1b` matches the path component `a~1b` today. Escaping the label again would give `a~01b`.
  - `children` is a `[String: …]` dictionary, so a component matches a canonically equivalent label whose bytes differ (NFC against NFD).
  - Macro-generated labels are Swift identifiers (`PathFlattener.swift:183`, `TypeToSchemaConverter.swift:206`), which contain neither `~` nor `/`. Not checked: raw (backticked) identifiers and hand-written `SyncTableField.make(name:)`.
- The only path-from-split code is `StateUpdateDecoder`'s private `reconstructPath(from:dynamicKeys:)` (`StateUpdateDecoder.swift:617`), on the client-decode side.

### 1.2 Who builds a path (checked)

- **With a split:** the typed diff in `SyncTables.swift`.
  - Every level gets `path: String` beside `cursor:` (`diff(_:_:path:cursor:…)`, :482 and the overrides).
  - The string is built at each level even when the cursor gives the split: rows `path + "/" + escaped` (:765, :840); fields `rowPath + component`, with the component cached per field (:654, :662); roots `"/" + escapedPathComponent(name)`, cached per root slot (:1075).
  - Patches are made at :597, :771–:784, :846–:880, :1176–:1304. :880 re-tags a create, `StatePatch(path: patch.path, …, split: …asRow(slot, generation:))`.
- **Without a split** (unchanged by this plan):
  - `SyncEngine`'s snapshot diff (:315–:545);
  - the typed per-player diff of #536, which has no cursor (`SyncTables.swift:1792`; `TransportAdapter.swift:1368`; pinned by `SyncTablePerPlayerDiffTests.swift:385`);
  - SyncTables :1103 and :1411;
  - the decoders and `Codable`;
  - `CanonicalPatchList.jsonSafe` (:112).
- **Only the opcode encodings get splits.** The typed diff's root cursor is `hasher?.rootCursor` (`TransportAdapter.swift:1349`), and the hasher exists only for the opcode encoders (`splittingPathHasher`, `CanonicalFrameOrder.swift:73`). The json encoding (`jsonObject`) keeps building strings as now (inferred from those two facts, pinned by a test, §4).

### 1.3 Who reads `path` (checked; "hot" = per patch per frame or per sync)

- **Opcode encoder call sites (hot).** Every one passes `patch.path` as a `String` argument, so the string is read, and with a computed `path` built, per patch per frame, even where the callee uses it only on an error or the atomic `.walkPath` branch:
  - MsgPack: `wireValue(…, path:)` (:306, :314, :322) and `pathID(…, path:)` (:429), called at :249, :258, :357, :366, :379, :391–:392, :397, :408, :414, :421;
  - opcode JSON: `wireValue` / `encodePathID` at :312, :320, :365, :379, :383, :392, :396, :404, :483, :488;
  - through to `AtomicPatternIndex.positional` / `node` (`Sources/SwiftStateTree/Sync/AtomicPatternIndex.swift:60–:72`), which needs it for `.walkPath` (:10–:13, :37–:45, :64), and passes it on to `AtomicLayoutTable.positional(_:at:path:)` (`AtomicPositionalForm.swift:42`).
  - `AtomicPositionalForm`'s recursion takes `path: String` and builds `path + "/" + key` and `path + "/\(index)"` for each nested value on the success path (:73, :81). The strings are used only by `AtomicPositionalFormError` (:66, `leaves`). So every atomic leaf on the opcode encodings forces the path, and builds one more string per nested level.
- **`RowEntryPlan`** uses the split only.
- **`FieldMergePlan.splitsAndEntries`** (hot). It runs on every frame with a hasher, field merge on or off (`FieldMergePlan.swift:67`):
  - `commonPathPrefix` compares each leading patch's path with the reference frame's (:144);
  - `rawPaths = patches.map(\.path)` (:88);
  - `PatchShape` (:207, :222);
  - `FieldMergePlanner.add` → `cut(patch.path)` and `PathKey` (:219–:235, :322), when field merge applies;
  - `split(of:)` re-splits the string only without a carried split, and always in DEBUG (:126–:138).
- **`SyncEngine.mergePatches`** (:657–:682), hot in the combined-frame encodings. Its `seenPaths` holds the broadcast paths and then the per-player paths as they're added: a broadcast duplicate is dropped (the first is kept), a per-player patch at a path already seen replaces the first patch at that path, broadcast or per-player (`firstIndex`), and a new one is appended. So two per-player patches at `/x` over an empty broadcast give one patch, the second, at the first's position. json and opcodeJsonArray send one combined state frame per recipient, which merges broadcast and per-player patches, per recipient per sync (`updateFromBroadcastDiff`, :1016, from `TransportAdapter.swift:5497`). messagepack sends the shared opcode 107 broadcast frame and doesn't merge (`TransportAdapter.swift:4415–:4421`, 4539–4578).
- **The json encoding:** `CanonicalPatchOrder.sorted` (:292) and `Codable` read the string. It has no splits (§1.2).
- **Per joiner or recording only:**
  - SyncTables :1287–:1304, the full view (`viewPatches`) and `liveDigestForm`;
  - SyncTables :1634–:1635, the digest's root grouping while the sync stream is recorded;
  - `replacingRows`, once per joiner's full view;
  - `CanonicalPatchList` and the sync-output verifier, only while the sync stream is recorded.
- **Rare:**
  - `SyncRowRef.init`, `covers` and the dedup Set, on failure paths;
  - the first-component filter, `.empty` baseline only;
  - the SyncTables snapshot fallback (:489, :501), whose patches have string paths;
  - debug checks.
- **Dead:** the re-split helpers at OpcodeJSON :574 and :633, and OpcodeMsgPack :497.

### 1.4 Two identity contracts (checked)

- **The frame cache compares UTF-8 bytes.** `commonPathPrefix` (:144), `PatchShape.matches` (:222, "the same bytes, not just canonically equivalent") and the planner's `PathKey` (:219–:235) all compare `utf8`. A resumed plan reuses the reference frame's splits, dynamic keys included. `FieldMergeTests` :354–:379 pins it: an NFD frame after an NFC one plans in full.
- **The merge and `StatePatch.==` use `String ==`**, which is canonical equivalence: `mergePatches`' `Set<String>` and `firstIndex(where: { $0.path == patch.path })`.

## 2. The change

### 2.1 The stored form, and when a split rebuilds its path

- `StatePatch` stores one of three forms. A sketch: a private `enum Location { case split(PatchSplit), path(String), pathAndSplit(String, PatchSplit) }`, with `public var path: String` (computed for `.split`) and `package var split: PatchSplit?` (nil for `.path`).
  - `.split`: lossless (below); the path is rebuilt on demand.
  - `.pathAndSplit`: today's stored pair, for a split whose literals aren't byte-identical to the trie's labels. The split keeps its hash, row slot and generation, so `RowEntryPlan` (:58–:66) and the pattern IDs see what they see today, and `path` returns the stored string.
  - `.path`: no split (the json encoding, the snapshot diff, decoded patches).
  - `public init(path:operation:)` keeps the string form.
  - `package init(split:operation:)` makes the split form; `init(path:operation:split:)` stays for the stored pair.
  - `package func retagged(_ split: PatchSplit) -> StatePatch` serves :880's row-generation re-tag without reading `path`.
- **Templates.** `PathHasherIdentity` gains a template per pattern hash and per trie node (§2.2). It is already a class that every split references, so `PatchSplit`'s layout doesn't change.
  - A template is the components in order, each a literal label exactly as stored in the trie, or a key slot. Built in `PathHasher.init`.
  - Rebuilding is `"/" + components.joined("/")`, with the keys inserted as stored: one allocation, and no escaping, since both labels and keys are already spelled as the path spells them.
- **Lossless, by definition.** A split rebuilds its emit's path byte for byte only when each literal the emit wrote has the same UTF-8 bytes as the trie label it matched. The keys are the emit's own bytes.
  - The typed diff checks this once per root slot and per field, when it builds its cached components (SyncTables :654, :1075): it compares the cached escaped component's bytes with the label the cursor matched.
  - Where they're byte-identical (every macro-generated name), the emit makes the split form. Elsewhere it builds the string and makes the stored pair, as today. The trie's `children` is String-keyed, so the lossy case is a name canonically equal to the label but with other bytes (an NFD field name against an NFC label). A label like `a~1b` isn't one: a field named `a/b` emits `a~1b`, the same bytes, so it is split-form, correctly.
  - So no patch is ever split-form with a path that could differ from the emit's, and no patch loses a split it carries today.
- **`==`** stays "same path and same operation" under `String` equality:
  - Two `.split` patches of one owner (lossless by the rule above) compare `pathHash`, and each dynamic key with `String ==`. That is exactly `String ==` of the rebuilt paths: the literals are the same, and `/` is a separator in both.
  - Any other pair compares the computed strings.
- `Codable` encodes the computed string; the decoded patch has the string form, as today.

### 2.2 The typed diff stops building strings

- The level argument becomes a position: the cursor when there is one, the string otherwise. A sketch: `enum DiffPosition { case cursor(PathHasher.Cursor), path(String) }`, with `descending(_ escaped:)` on both.
  - With a cursor, no string is built at any level, and a patch is made with `init(split:operation:)`.
  - Without one (no hasher: the json encoding, or the per-player diff), the strings are built as now.
- **Walk-off.** Where the cursor walks off the trie (`descending` returns nil), or a position has no hash, the emit needs the string, as today's fallback does.
  - The cursor may sit on an unhashed intermediate node (`a.b` in `a.b.c`), which no pattern hash names. So the templates are per trie node, not only per pattern: each node keeps its template from the root.
  - The position turns into the string form by rebuilding the node's template with the cursor's keys, then appending the components after it. Lossless by the same rule.
  - **A lossy ancestor.** A position goes to the string form at the first component whose literal isn't byte-identical to its label (§2.1), and its descendants carry that string (with the cursor beside it, for their splits' stored pairs). So a walk-off below a lossy ancestor already has the emit's own spelling, and a rebuild from a template happens only under an all-lossless chain.
- **Templates: shared, no cycle, linear memory.** They live in `PathHasherIdentity`, one per hasher, shared by every split of it, built once in `PathHasher.init` and immutable after.
  - Per trie node, an entry `(parent index, label or key slot)` in a flat array; a pattern hash maps to its node's index. A rebuild walks the parent chain. Memory is one entry per trie node, independent of depth; a rebuild costs the node's depth.
  - The entries are values in arrays the identity owns. Nothing in them references the identity or a cursor, so there is no retain cycle.
- **The DEBUG oracle (Q2):** every split-made emit in a DEBUG build also builds the old string independently (today's concatenation) and asserts that `patch.path.utf8.elementsEqual(old.utf8)`. Every debug test run checks every split-made patch. It replaces the shadow check at SyncTables :605.

### 2.3 Field merge compares splits, byte for byte

The frame cache's contract is UTF-8 bytes (§1.4), so the identity it uses is too.
- **`PatchPathIdentity`** is `(owner, pathHash, dynamicKeys)` for a split-form patch of the frame's hasher, and the string otherwise.
  - Two split identities are equal when the owners and `pathHash` are the same and each dynamic key's `utf8` bytes are equal (not `String ==`).
  - Two string identities compare bytes.
  - A split against a string compares the split's rebuilt bytes, which only happens when a frame mixes forms.
- **`FramePrefixCache.Reference`** stores identities instead of `rawPaths`. `commonPathPrefix` and `PatchShape` compare them.
- **`FieldMergePlanner.add`'s `cut(patch.path)` (Q1 (a)):** it computes the path once per planned patch; resumed patches skip it. This stays hot work while field merge applies. The A/B reports the prefix cache's hits with the cache on, from the counters it already keeps (`FramePrefixCache.resumes` and `reusedSplits`, `FieldMergePlan.swift:190`), and runs rows off, where more patches are planned. `--merge-stats` can't serve: it skips the cache (:85) and counts no hits.

### 2.4 `mergePatches`: a String-keyed broadcast index, once per sync

- Today a `Set<String>` of the broadcast paths is built per recipient. Instead:
  - **once per sync,** the broadcast list deduplicated (the first patch at a path kept) and a String-keyed index, path → position in that list, from the broadcast patches' computed paths;
  - **per recipient,** a copy of the deduplicated list and a String-keyed index of the per-player paths added so far, path → position. Each per-player patch looks itself up in the broadcast index, then in the per-recipient index: found, it replaces the patch at that position; not found, it is appended and recorded.
- That is today's result in every case, with `String` semantics (canonical equivalence) on both indexes: broadcast duplicates keep the first, a per-player patch replaces a broadcast one or an earlier per-player one at its position, and new paths keep their order.
- The cost is one rebuilt path per broadcast patch per sync, in the combined-frame encodings only (§1.3), plus per recipient one path and up to two lookups per per-player patch, instead of today's per-recipient set of every broadcast path and the linear `firstIndex`.

### 2.5 The other readers, converted

- **Encoder call sites (§1.3):** `wireValue`, `encodePathID` / `pathID` and `AtomicPatternIndex.positional` / `node` take the patch (or its split) and build the path only in their error branch and the `.walkPath` branch. Where a signature can't change cheaply, the parameter becomes `@autoclosure () -> String`. No call site evaluates `patch.path` on the success path.
- **`AtomicPositionalForm`:** `positional(_:at:path:)`, its recursion and `leaves` take `path: () -> String`, non-escaping, never stored. The recursion passes `{ path() + "/" + key }` and `{ path() + "/\(index)" }`, also non-escaping, so a nested value's path is built only when an `AtomicPositionalFormError` is thrown. The public `positional(_:atPath:)` and `keyed(_:atPath:)` keep their `String` parameter and pass `{ path }`.
- **`FieldMergePlan`:** §2.3. `split(of:)` returns the carried split without reading `path` in release; its DEBUG re-split stays.
- **SyncTables :880:** `retagged(_:)` (§2.1).
- **SyncTables :1287–:1304** (full view, live digest) and **:1634–:1635** (digest roots, recording only) call `path` once per patch into a local.
- **The json encoding, the patch applier, `CanonicalPatchList`, `CanonicalPatchOrder`** (string form only, §1.2), the verifier and the rare readers call `path`. A reader that needs it more than once per patch takes it once into a local: `SyncRowRef`, `replacingRows`, dedup.
- The dead re-split helpers are removed.
- **The rebuild counter** (§4.4), DEBUG only, counts rebuilds through `path`'s public getter on `.split` patches. The DEBUG readers (the oracle of §2.2 and `split(of:)`'s re-split check) read through a package `debugRebuiltPath` that doesn't count, so the counter sees production readers only.

## 3. Out of scope

- **Splits for the typed per-player diff: #547.** It has no cursor, so its patches keep their strings, and the pin `SyncTablePerPlayerDiffTests` :385–:386 stays.
  - The cost that remains: each per-player patch's path is built per player per sync, and in each recipient frame the opcode encoders re-split it (`FieldMergePlan.split(of:)` without a carried split), read it at the call sites of §2.5 as a stored string, and include it in the frame identity as a string.
- The snapshot diff (`SyncEngine`) and its unescaped top-level paths.
- The client side (`StateUpdateDecoder.reconstructPath`).

## 4. Gate

1. **Wire bytes and digests identical in every encoding** (json, opcodeJsonArray, messagepack), row addressing on and off:
   - the existing pins: `SyncOutputGoldenTests` (including `escaped-keys-json`), RowEntry and FieldMerge fixture frames, `FieldMergeTests` :354–:379 (NFD after NFC), `ShapeMatrixRoundTripTests` (keys `a/b`, `t~x`, `a[0]`, a decomposed accent), `AtomicArrayShapesTests`, `CanonicalMessagePackTests`, `SyncTablesByteIdentityTests`, `DirtyTrackingByteIdentityTests`, `ReevaluationMonitorFrameIdentityTests`, `SyncStrategyEquivalenceTests`;
   - E2E on all three encodings, and the replay goldens through the router;
   - EncodingBenchmark's bytes per cell, equal between base and head (item 3).
2. **The computed path equals the old string, UTF-8 byte for byte, for every patch:**
   - the DEBUG oracle of §2.2, on every split-made emit in every debug test;
   - a differential test: the typed diff and the snapshot diff of the same changes give the same path bytes in the same canonical order. Fixtures include keys with `~`, `/`, `~1`, empty (`/m/`, `/m//v`), NFD and NFC, a row create, retag and delete, a walk-off after several unhashed nodes, and a walk-off under a wildcard. It builds on `CarriedPatchSplitTests` and `EmptyMapKeyTests`;
   - a lossless-rule test: a field named with NFD bytes against its NFC label emits the stored pair, with the path byte-identical to today's and the split, row slot and generation carried; a field named `a/b` (emitting `a~1b`) emits the split form;
   - wire bytes of a row create, update and delete under that NFD name, in opcodeJsonArray and messagepack with rows on, equal to today's (row entries, not plain patches);
   - a template test: for every pattern and trie node of the test schemas, `rebuilt(split(path)).utf8 == path.utf8`;
   - a json pin: a json-encoded land's patches are all string-form.
3. **A/B with window instructions inside or better; time reported.**
   - The rule is #517's (`Notes/plans/2026-11-13-off-path-instruction-gate.md`): mean `instructions:u` per cell, REGRESSION above base by more than max(0.5 %, 3 × base's spread), GAIN below base's min.
   - The window is `ENCODING_BENCHMARK_PERF_WINDOW=iteration`, which covers `syncNow()`: this change is on the sync path, and `nonsync` would leave it out. Each result's `perfWindow.mode` must be `iteration`, with `toggles == 2 × iterations` (one room).
   - Common flags, as #521's and the atomic-node plan's A/Bs; `--iterations` is set so that a run takes at least 20 s, the same on both sides:
     ```
     EncodingBenchmark --game-type hero-defense --rooms 1 --players-per-room 5 --monster-cap 100 \
       --ticks-per-sync 2 --parallel false --iterations <n> --output json
     ```
     The rows-json-100 cell sets `--players-per-room 100`, as #392's own measurement cell; it has its own `<n>`.
   - Cells, with `USE_SYNC_TABLES=true` (the typed diff) and the other switches unset:

     | Cell | Flags | Why |
     |---|---|---|
     | rows-json | `--format opcode-json-pathhash --join-through-router on --row-addressing on` | combined frames: `mergePatches` runs |
     | rows-mp | `--format messagepack-pathhash --join-through-router on --row-addressing on` | the shared broadcast frame |
     | router-json | `--format opcode-json-pathhash --join-through-router on --row-addressing off` | rows off: every patch through field merge |
     | router-mp | `--format messagepack-pathhash --join-through-router on --row-addressing off` | the same, messagepack |
     | rows-json-100 | rows-json `--players-per-room 100` | combined frames at many recipients: the readers that scale with recipients |
     | json-control | `--format json-object` (router join off) | string-form only: must not move |

   - Checked per result:
     - the resolved metadata: `routerJoin` with rows as asked, the encoding, `USE_SYNC_TABLES`;
     - split-backed paths exercised: the run's patch counts, plus the DEBUG oracle's coverage in the test suite;
     - for rows-json, router-json and rows-json-100, the prefix cache's `resumes` and `reusedSplits` with the cache on, from an untimed run of the same cell (reported, not judged);
     - bytes equal to the other side's;
     - the pinned image digest on both sides, recorded beside `swift --version`.
   - Release builds, both sides in one container from the pinned image. ABAB, at least 5 runs per side. Run by the measurement host through a brief.
4. **Mutants:**
   - the template's literal escaped again (`a~1b` → `a~01b`), killed by the template test and the `a/b` field;
   - keys inserted in the wrong order;
   - the frame identity comparing keys with `String ==` instead of bytes (killed by `FieldMergeTests` :354–:379);
   - the frame identity comparing hashes only;
   - the lossless check skipped, so the NFD name emits the split form and rebuilds the NFC label's bytes;
   - the stored pair dropping its split (string form for a lossy literal), killed by the NFD row wire test;
   - `mergePatches` without the per-recipient index (a second per-player patch at a path appended), killed by a test of duplicates on both sides, canonically equal paths and the output order;
   - `mergePatches` keying split and string forms by different hashes;
   - a call site evaluating `patch.path` eagerly, and `AtomicPositionalForm` building a nested path eagerly, killed by unit tests with the rebuild counter (§2.5): encoding, with field merge off, a frame of `.split` patches with an atomic leaf, a nested atomic value and a row entry rebuilds no path (only `cut`, §2.3, and the error and `.walkPath` branches may rebuild).

## 5. Decisions (review of rev 1, accepted 2026-11-13)

- **Q1: (a),** after the call sites are converted (§2.5). `cut` computes the path per planned patch, and the A/B reports it as hot work, with the prefix cache's hits and a rows-off cell.
- **Q2: yes,** byte for byte, with an independent old-string oracle on every split emit (§2.2).
- **Q3: yes,** for in-schema `.split` patches, which are lossless by §2.1's rule, with `String ==` on keys. Any other pair compares the computed strings.
- **Q4: one PR,** with internal commits:
  1. `StatePatch`'s form, templates and the lossless rule;
  2. the readers;
  3. the typed diff's positions;
  4. tests and the oracle.

## Solutions consulted

- `2026-11-07-a-wire-form-keyed-by-schema-patterns-misses-undefined-shapes.md`: the walk-off and no-hash positions in §2.2.
- `2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`: byte identity is compared per run on fixed inputs.
- `2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md`: the differential test in §4.
- `2026-11-12-a-whole-capture-hash-depends-on-send-order-across-sessions.md`: digests are compared per frame, not per capture.
- `2026-11-12-a-closure-in-every-wrapper-makes-every-node-non-trivial.md`: the templates live in the shared identity, not in each split.
- `2026-11-13-an-input-applied-in-a-later-phase-measured-without-it.md`: the A/B's window must contain the changed work (`iteration`).
