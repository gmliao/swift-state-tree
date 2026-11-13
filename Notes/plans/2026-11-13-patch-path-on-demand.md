# A patch's path built on demand from its split (#392, the remaining step)

**Status:** rev 1, for review. No code. Read at `main` 746fe207. Each fact is marked **checked** (read in the code) or **inferred** (reasoned, to be pinned by a test in the PR). Scope and gate: #392's comment of 2026-11-13 ("Next step (decided)").

**Summary.** `StatePatch.path` is a stored string that every typed emit builds next to the split it already has. This change makes the split the stored form and builds `path` only when a reader asks. The wire doesn't change. The work saved is the per-level string building in the typed diff, and, on the opcode encodings, the path work in the encoders, if they compare splits instead of strings. Two readers on the hot path would otherwise build the string per patch per recipient and erase the saving: the field-merge frame prefix cache (§2.3) and `mergePatches` (§2.4). The plan changes both.

## 1. What is there now

### 1.1 The patch and the split (checked)

- `StatePatch` (`Sources/SwiftStateTree/Sync/StatePatch.swift:71`): `public let path: String`, `operation`, and `package let split: PatchSplit?`. `==` and `Codable` use `path` and `operation` only.
- `PatchSplit` (`Core/PathHasher.swift:213`): `pathHash: UInt32`, `dynamicKeys: [String]`, `row: PatchRow?`, `owner: PathHasherIdentity`.
  - `pathHash` is the full pattern's hash, also for a row-tagged split: `asRow` keeps it and adds `PatchRow(table: pathHash, …)` (:227).
  - The keys are stored as the path spells them, escaped (`Cursor.descending`, :270).
- `PathHasherIdentity` (:207) is an empty final class that every split references. `PathHasher` is a struct; `hashToPath: [UInt32: String]` is immutable after init (:25).
- Pattern hashes can't collide: `hashToPath` is built with `Dictionary(uniqueKeysWithValues:)` (:49), which traps on a duplicate. So `pathHash` names one pattern.
- Patterns are dot-joined raw field names with `*` for a dynamic key (`PathFlattener.swift:183`). Nothing rejects `~` or `/` in a name; macro-generated names are Swift identifiers, which can't contain them, `.` or `*`. Not checked: raw (backticked) identifiers and hand-written `SyncTableField.make(name:)`.
- The only path-from-split code is `StateUpdateDecoder`'s private `reconstructPath(from:dynamicKeys:)` (`StateUpdateDecoder.swift:617`), on the client-decode side.

### 1.2 Who builds a path (checked)

- **With a split:** the typed diff in `SyncTables.swift`.
  - Every level gets `path: String` beside `cursor:` (`diff(_:_:path:cursor:…)`, :482 and the overrides).
  - The string is built at each level even when the cursor gives the split: rows `path + "/" + escaped` (:765, :840); fields `rowPath + component` (:654, :662); roots `"/" + escapedPathComponent(name)` (:1075).
  - Patches are made at :597, :771–:784, :846–:880, :1176–:1304.
- **Without a split** (unchanged by this plan):
  - `SyncEngine`'s snapshot diff (:315–:545), which also builds top-level paths unescaped (`"/\(key)"`);
  - the typed per-player diff of #536: `SyncTablePerPlayerDiff` gets no cursor (`SyncTables.swift:1792`; `TransportAdapter.swift:1368`); a test pins it (`SyncTablePerPlayerDiffTests.swift:385`);
  - SyncTables :1103 and :1411;
  - the decoders and `Codable`;
  - `CanonicalPatchList.jsonSafe` (:112).
- **Only the opcode encodings get splits.** The typed diff's root cursor is `hasher?.rootCursor` (`TransportAdapter.swift:1349`), and the hasher exists only for the opcode encoders (`splittingPathHasher`, `CanonicalFrameOrder.swift:73`). The json encoding (`jsonObject`) keeps building strings as now (inferred from those two facts, to pin by a test).

### 1.3 Who reads `path` (checked; "hot" = per patch per sync)

- **Opcode encoders**, which share one structure (`OpcodeJSON…:284`, `OpcodeMsgPack…:226`):
  - `RowEntryPlan` uses the split only.
  - `FieldMergePlan.splitsAndEntries` runs on every frame with a hasher, field merge on or off (`FieldMergePlan.swift:67`). Hot:
    - `commonPathPrefix` compares each leading patch's path with the previous frame's (:144);
    - `rawPaths = patches.map(\.path)` (:88);
    - `PatchShape` (:207, :222);
    - `FieldMergePlanner.add` → `cut(patch.path)`, a byte scan plus FNV hash (:322), when field merge applies.
  - The plain encode reads `path` only on an error or an unresolved atomic pattern (`encodePathID`, `wireValue`).
  - `split(of:)` re-splits the string only without a carried split, and always in DEBUG (:126–:138). Dead helpers that re-split are OpcodeJSON :574 and :633, and OpcodeMsgPack :497.
- **`SyncEngine.mergePatches`** (:657): hot. It runs per recipient per sync (`updateFromBroadcastDiff`, :1016, from `TransportAdapter.swift:5497`) and inserts every broadcast patch's path into a `Set<String>`.
- **The json encoding:** `CanonicalPatchOrder.sorted` (:292) and `Codable` read the string. It has no splits (§1.2).
- **Rare:**
  - `SyncRowRef.init`, after an encode failure;
  - `covers` and the dedup Set, on failure paths;
  - `replacingRows`, once per joiner's full view;
  - the first-component filter, `.empty` baseline only;
  - `CanonicalPatchList` and the sync-output verifier, only while the sync stream is recorded;
  - the SyncTables snapshot fallback (:489, :501), whose patches have string paths;
  - debug checks.

## 2. The change

### 2.1 The stored form

- `StatePatch` stores either a split or a string, never both. A sketch: a private `enum Location { case split(PatchSplit), path(String) }`, with `public var path: String` computed and `package var split: PatchSplit?`. `public init(path:operation:)` keeps the string form; `package init(split:operation:)` replaces `init(path:operation:split:)`.
- `PathHasherIdentity` gains the pattern templates. It is already a class that every split references, so `PatchSplit`'s layout doesn't change.
  - A template per pattern hash: the components in order, each a literal (stored escaped with `escapedPathComponent`) or a key slot. Built in `PathHasher.init` from `pathHashes`.
  - Escaping the literal at build time makes the computed path equal the emit's `"/" + escapedPathComponent(name)` by construction, also for a name that contains `~` or `/`.
- `split.path` (or `PatchSplit.joinedPath`) is `"/" + components.joined("/")`, with the keys inserted as stored (already escaped): one allocation per call.
- `==` stays "same path and same operation". When both patches carry splits of one owner, it compares `pathHash` and `dynamicKeys`, which is equivalent because both mappings are deterministic for one hasher. Otherwise it compares the computed strings. Q3 asks whether to keep the fast path.
- `Codable` encodes the computed string; the decoded patch has the string form, as today.

### 2.2 The typed diff stops building strings

- The level argument becomes a position: the cursor when there is one, the string otherwise. A sketch: `enum DiffPosition { case cursor(PathHasher.Cursor), path(String) }`, with `descending(_ escaped:)` on both.
  - With a cursor, no string is built at any level, and a patch is made with `init(split:operation:)`.
  - Without one (no hasher: the json encoding, or the per-player diff), the strings are built as now.
- Where the cursor walks off the trie (`descending` returns nil) or a position has no hash, the emit needs the string. Today these use the hasher's fallback split (`split` is nil, §1.1). The position then turns into the string form, which needs the parent's path once: computed from the cursor that last matched, plus the components after it.
- The DEBUG shadow check at SyncTables :605 changes to: build the old string in DEBUG beside every split-made patch and assert that `patch.path` equals it. Every debug test run then checks the computed path. Q2 asks whether to keep this.

### 2.3 Field merge compares splits

`FieldMergePlan` is the per-frame reader on the default encodings, and the frame prefix cache compares each recipient's frame with the previous recipient's (§1.3). With a computed `path`, each comparison builds a string, so this reader moves to a path identity:

- **A `PatchPathIdentity`** is `(pathHash, dynamicKeys)` for a patch with a split of the frame's hasher, and the string otherwise.
  - Two identities of the split kind are equal when their fields are. Two string identities compare bytes.
  - A split against a string compares the computed string. This doesn't happen within one hasher's frame unless a frame mixes forms.
- **`FramePrefixCache.Reference`** stores identities instead of `rawPaths`. `commonPathPrefix` and `PatchShape` compare identities.
- **`FieldMergePlanner.add`'s `cut(patch.path)`**, which cuts at the merge prefix and hashes it, is the open point (Q1):
  - (a) compute the path in `add` only, once per planned patch (resumed patches skip it), and measure;
  - (b) key the cut by the split: the prefix's pattern hash and the keys it covers.

  The PR starts with (a). (b) follows only if the A/B fails because of it.

### 2.4 `mergePatches` builds the broadcast set once per sync

- Today the set of broadcast paths is built per recipient. The change builds it, or an identity set as in §2.3, once per sync from the broadcast patches, and each recipient's per-player patches look themselves up in it.
- Per-player typed patches have string paths (§1.2) and broadcast ones have splits, so a lookup can mix forms. For typed lands, broadcast and per-player fields are different top-level fields, so no path is in both (inferred). The set keeps string equality across forms: a split identity is matched against a string by computing that one string.
- Behavior is unchanged: the first broadcast patch at a path is kept, and a per-player patch at the same path replaces it.

### 2.5 Other readers

- The json encoding, the patch applier, `CanonicalPatchList`, `CanonicalPatchOrder` (string form only, §1.2), the verifier and the rare readers in §1.3 call `path`.
- Readers that read it more than once per patch take it once into a local: `SyncRowRef`, `replacingRows`, dedup.
- The dead re-split helpers (OpcodeJSON :574 and :633, OpcodeMsgPack :497) are removed.

## 3. Out of scope

- **Splits for the typed per-player diff (#536).** It has no cursor, so its emits keep building strings, and the opcode encoders re-split them. Giving it a cursor is a separate change with its own byte-identity check: a per-player row would carry a row split and could take the row-entry form. A follow-up issue, to be opened when this is decided.
- The snapshot diff (`SyncEngine`) and its unescaped top-level paths.
- The client side (`StateUpdateDecoder.reconstructPath`).

## 4. Gate

1. **Wire bytes and digests identical in every encoding** (json, opcodeJsonArray, messagepack), row addressing on and off:
   - the existing pins: `SyncOutputGoldenTests` (including `escaped-keys-json`), RowEntry and FieldMerge fixture frames, `ShapeMatrixRoundTripTests` (keys `a/b`, `t~x`, `a[0]`, a decomposed accent), `AtomicArrayShapesTests`, `CanonicalMessagePackTests`, `SyncTablesByteIdentityTests`, `DirtyTrackingByteIdentityTests`, `ReevaluationMonitorFrameIdentityTests`, `SyncStrategyEquivalenceTests`;
   - E2E on all three encodings, and the replay goldens through the router;
   - EncodingBenchmark's bytes per cell, equal between base and head in the A/B (item 3).
2. **The computed path equals the old string for every patch, escaping included:**
   - the DEBUG assertion of §2.2, on every split-made patch in every debug test;
   - a differential test: the typed diff and the snapshot diff of the same changes give the same path strings in the same canonical order. Fixtures include keys with `~`, `/`, `~1`, empty (`/m/`, `/m//v`), NFD/NFC, and a row create and delete. It builds on `CarriedPatchSplitTests` and `EmptyMapKeyTests`;
   - a template test: for every pattern of the test schemas, `joinedPath` of a split equals `hasher`'s round-trip (`split(path).joinedPath == path`).
3. **A/B with window instructions inside or better; time reported.**
   - The rule is #517's (`Notes/plans/2026-11-13-off-path-instruction-gate.md`): mean `instructions:u` per cell, REGRESSION above base by more than max(0.5 %, 3 × base's spread), GAIN below base's min.
   - The window is `ENCODING_BENCHMARK_PERF_WINDOW=iteration`, which covers `syncNow()`: this change is on the sync path, and `nonsync` would leave it out.
   - Cells: the 100-player cell through the router (the one #533 measured), Hero Defense, opcodeJsonArray and messagepack, row addressing on (the default). Json as a control: it should not move (§1.2).
   - Release builds, both sides in one container from the pinned image. Run by the measurement host through a brief.
4. **Mutants:**
   - the template's literal not escaped;
   - keys inserted in the wrong order;
   - the prefix-cache identity comparing hashes only;
   - `mergePatches` matching a split identity to a string by hash.

## 5. Questions for review

- **Q1.** Field merge's `cut` (§2.3): (a) compute the path in `add`, then measure, or (b) key it by the split now? Recommended: (a), with (b) only if the A/B fails because of it.
- **Q2.** Keep the DEBUG assertion that builds the old string beside every split-made patch (§2.2)? It costs debug test time only. Recommended: yes.
- **Q3.** `==` fast path on two splits of one owner (§2.1)? Recommended: yes. Equality is used by tests and dedup, and the fast path is exact for one hasher.
- **Q4.** The PR's shape: one core PR as the issue says, or the `StatePatch` form plus the readers (§2.1, §2.3–§2.5) first and the typed diff's positions (§2.2) second, each with the gate? Recommended: one PR; the A/B only means something with both halves.

## Solutions consulted

- `2026-11-07-a-wire-form-keyed-by-schema-patterns-misses-undefined-shapes.md`: the walk-off and no-hash positions in §2.2.
- `2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`: byte identity is compared per run on fixed inputs.
- `2026-11-10-a-diff-replacement-must-match-the-old-diffs-quirks.md`: the differential test in §4.
- `2026-11-12-a-whole-capture-hash-depends-on-send-order-across-sessions.md`: digests are compared per frame, not per capture.
- `2026-11-12-a-closure-in-every-wrapper-makes-every-node-non-trivial.md`: the templates live in the shared identity, not in each split.
- `2026-11-13-an-input-applied-in-a-later-phase-measured-without-it.md`: the A/B's window must contain the changed work (`iteration`).
