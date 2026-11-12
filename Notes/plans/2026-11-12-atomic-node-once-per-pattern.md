# Resolve the atomic layout node once per pattern in the opcode encoders

Status: open. Base: main e4abe9ce. Issue: none; found in a sync profile.

## Problem

With atomic values sent positionally, every set or add value goes through the same chain in both opcode encoders:

- `wireValue(value, path:)`
- → `AtomicLayoutTable.positional(_:atPath:)`
- → `node(atPath:)`, which splits the path string (`PathHasher.components`) and does one `String`-keyed dictionary lookup per component.

Most patches (hp, counters) end at "no atomic node", and they still pay for the whole walk. The encoder already holds the patch's split (pattern hash, dynamic keys, in-schema flag) for every patch, so the walk's answer can be looked up once per pattern instead.

A profile at f9afa924 (Mac, release, with `TYPED_LEAF_VALUES=true`, which isn't on main) shows `node(atPath:)` at 443 of 5069 sync samples on the messagepack router cell with rows and tables (8.7 %), and 1157 of 6814 on opcode JSON (17.0 %).

## Design

### Where it lives

- `AtomicPatternIndex` (package), in `Sources/SwiftStateTree/Sync/AtomicPositionalForm.swift`:
  - Built from (`AtomicLayoutTable`, `PathHasher`).
  - It holds `[UInt32: Resolution]`, one entry for every pattern in `hasher.pathHashes`, built with `uniqueKeysWithValues`. A duplicate hash can't reach it, because `PathHasher.init` already traps on one (`hashToPath`, PathHasher.swift:50), so there is no conflict branch.
  - `enum Resolution { case node(Node?); case walkPath }`.
  - `func node(pathHash: UInt32, inSchema: Bool, path: String) -> Node?` returns:
    - for `inSchema` and `.node(n)`: `n`;
    - otherwise (`inSchema == false`, `.walkPath`, or a hash it doesn't have): `table.node(atPath: path)`, which is today's string walk.
  - It never reads the dynamic keys, so it takes only (pathHash, inSchema).
- `AtomicLayoutTable` gets `package func positional(_ value:, at node: Node?, path:)`. `positional(_:atPath:)` calls it. `keyed(_:atPath:)` and the decoders are unchanged.
- `OpcodeMessagePackStateUpdateEncoder` builds the index in its init when both `pathHasher` and `atomicLayout` are set, and stores it as `let atomicPatterns`. Otherwise it is nil: the legacy and keyed paths don't change.
- `OpcodeJSONStateUpdateEncoder` builds it in the same place, in the outer encoder's init. It hands the index to `OpcodePayloadArray`, which is built per encode call (OpcodeJSONStateUpdateEncoder.swift:180–195, init :446), so the payload never builds one.
- `wireValue(value, path:, split:)` takes the split each call site already has:
  - plain entry: `split` (already a parameter);
  - merged member: `splits[member.index]`;
  - row entry: `(patches[index].split!.pathHash, true)`. `RowEntryPlan` (RowEntryPlan.swift:58) only takes patches whose split belongs to this hasher, so there is no ownership check of its own;
  - JSON `encodeOperation` (:432): the split is threaded through to it;
  - legacy: no hasher, no index, so the code is as today.
- No public API change.

### Key and invalidation

- The key is the pattern hash of the frame's split. `FieldMergePlan.split` gives every patch one, carried from the sync tables or computed by the hasher. So patches without a carried split (the default path, tables off) use the index too, whenever the hasher matched them (`inSchema`).
- `inSchema == false` means the fallback heuristic's hash, which may equal a schema hash. Such a patch always takes the string walk.
- Nothing is invalidated:
  - `AtomicLayoutTable` is immutable and cached per state type;
  - `PathHasher` is immutable;
  - both are `let` on the encoder, and the `with…` copies (row addressing, canonical order) don't touch them.
- The index is built eagerly, once per encoder (one per `TransportAdapter`): patterns × depth lookups, and no per-frame work.

### The collision: a dynamic key equal to a property name

- An in-schema split is the trie's walk:
  - a literal step consumed a component equal to its pattern label;
  - a `*` step consumed the next dynamic key.
  So (pattern, dynamic keys) rebuilds the path's components exactly.
- The string walk does `node = node.children[c] ?? node.wildcard` at each step. The index resolves a pattern by walking its labels from the root with the same rule:
  - **Literal step `c`.** `current = current.children[c] ?? current.wildcard`. Here `c` is the label itself, so the result is known per pattern, including the fallback to the wildcard.
  - **`*` step.** The result depends on the key exactly when the node the step **leaves** has named children, because then `children[key]` could win for some key. So if `current.children` is non-empty, the entry is `.walkPath`. Otherwise `current = current.wildcard`.
  - A step that finds nothing ends the walk with `.node(nil)`, as the string walk returns nil.
- Counterexample (why it is the node left, not the node landed on): root has `children {position: A}` and a childless wildcard `W`. A path with key "position" goes to `A` in the string walk. Checking the node landed on (`W`, childless) would cache `W`. Checking the node left (the root, which has children) gives `.walkPath`.
- So the index returns the string walk's node by construction, with no assumption about schemas. In practice `TypeToSchemaConverter` never gives one schema both `properties` and `additionalProperties`/`items`. A map key equal to a property name ("/units/position/position", a key "units") passes a wildcard-only node, where both walks agree.

## Tests (Swift Testing; nothing waits on a clock)

- **(a) Node-level differential on real states**:
  - states: the `AtomicPositionalEncodingTests` state and every `AtomicArrayShapesTests` shape, recursive included;
  - for every schema pattern, concrete paths with dynamic keys that include property names at the same and other levels, plus `*` and `""`;
  - check `index.node(pathHash:inSchema:path:) === table.node(atPath:)` for the hasher's own split of each path;
  - also deeper recursion paths and paths outside the schema.
- **(b) Collision, hand-built**:
  - Table: root `children {position: A (atomic)}` plus a childless wildcard `W`. The hasher has the patterns `*` and `*.…` but no literal `position`, so "/position" splits as `*` with the key "position" and the collision is exercised.
  - Check: the entry is `.walkPath`; "/position" resolves to `A` and "/k" to `W`, as the string walk does.
  - A literal step whose label is missing from `children` falls to the wildcard, as the string walk does.
  - Converse: a wildcard-only source node whose wildcard is a struct node resolves to `.node(struct node)`, not `.walkPath`.
- **(c) `inSchema == false` with a schema hash**: (hash of an atomic pattern, false) for a non-atomic path gives the string walk's nil, not the pattern's node.
- **(d) Byte identity of encoded frames**:
  - Two independently initialized encoders with identical histories, one with the index and one without (a package init flag; not a `with…` copy, which would share the dynamic-key store and `FramePrefixCache`).
  - Both opcode encodings: positional, plus keyed (atomicLayout nil), which is unchanged.
  - Frames:
    - from a real diff with carried splits (sync tables) and from the plain diff and hand patches (no carried split);
    - firstSync with nested atomic values; sets and adds at atomic paths; a map key equal to a property name; null at an atomic path;
    - field merge on, with a merged group holding an atomic member and a scalar member, given in an order different from the sorted order;
    - row addressing on (row create, column set);
    - consecutive frames that hit the split-prefix reuse (FieldMergePlan.swift:76–78) and the canonical reorder.
- **(e) `IN_TURN_SYNC=false`**:
  - There, row addressing is off (TransportAdapter.swift:1288), so there are no row entries. Carried splits come only from the sync tables, and splits are made only in SyncTables.swift, never on the adapter's sync path. (d) covers that combination: tables-diff patches and plain-diff patches, rows off.
  - In addition, an adapter-level test with `inTurnSync: false` × tables on/off, both formats, decodes the frames and checks that the positional atomic values round-trip to the state.
- **Mutants** (each killed by an assertion):
  - M1: the `*` step checks the node it lands on instead of the node it leaves. Killed by (b), the counterexample.
  - M2: a `*` step ignores `children` (always the wildcard, never `.walkPath`). Killed by (b).
  - M3: a literal step without the wildcard fallback. Killed by (b).
  - M4: `inSchema` is ignored. Killed by (c).
  - M5: a merged member's value resolves with another member's split (the group's first). Killed by (d), the merged group with an atomic member and a scalar member.
- **Existing suites**: AtomicPositionalEncodingTests, AtomicArrayShapesTests, ShapeMatrixRoundTripTests, FieldMergeTests, the row-entry tests; the full run on CI.

## Measurement

### Expected change

- The number of lookups depends on the patch count, not on typed leaf values. So the absolute saving per sync on main should be close to f9afa924's. On main, sync is costlier without typed leaf values, so the relative share is smaller.
- Expected on main (e4abe9ce): syncMs about −4 to −8 % on the messagepack cells and −8 to −15 % on the opcode JSON cells. The default and router cells are in the same range: same patches, and splits come from `FieldMergePlan` instead of being carried.
- A Mac profile of A (diagnosis only) is taken first, before the host run, to check `node(atPath:)`'s share on main. If it differs, this expectation is restated.

### Host A/B (the number)

- On the measurement host, base and head are built and run in one container from the pinned image, release.
  - A = e4abe9ce (pinned).
  - B = the PR head.
- The environment is cleared of the switches the cells don't set (`env -u` for each).
- Common flags:
  ```
  EncodingBenchmark --game-type hero-defense --rooms 1 --players-per-room 5 --monster-cap 100 --ticks-per-sync 2 \
    --parallel false --iterations 4000 --output json
  ```
  `--iterations` is set so that one run takes at least 20 s on the host, and is the same for A and B.
- Cells:

  | Cell | Env | Flags |
  |---|---|---|
  | default-mp (cap100-default: the default config) | `USE_SYNC_TABLES`, `TYPED_LEAF_VALUES` unset | `--format messagepack-pathhash` (router join off) |
  | default-json | same | `--format opcode-json-pathhash` (router join off) |
  | router-mp | same | `--format messagepack-pathhash --join-through-router on --row-addressing off` |
  | router-json | same | `--format opcode-json-pathhash --join-through-router on --row-addressing off` |
  | rows-mp (profiled e-mp, without typed leaf values) | `USE_SYNC_TABLES=true`, `TYPED_LEAF_VALUES` unset | `--format messagepack-pathhash --join-through-router on --row-addressing on` |
  | rows-json (profiled e-json, without typed leaf values) | same | `--format opcode-json-pathhash --join-through-router on --row-addressing on` |

  The default cells keep the router join off, because the default path and its numbers must not move. The router cells are a separate pair and don't stand in for them.
  `FIELD_MERGE`, `PATH_INDEX`, `DYNAMIC_KEY_COMPRESSION` and `IN_TURN_SYNC` are unset, so they take their defaults.
- Order: ABABABABAB per cell (5 runs each), with complete command lines recorded next to the results.
- Judged on the run-average `syncMs` (mean of the 5 runs per side). Reported per cell:
  - A and B means, with min–max;
  - Δ %;
  - the base-vs-base spread, (max − min) / mean of A's 5 runs.
- `timeMs − syncMs` is reported separately. A shift there isn't attributed to this PR without a sync-side cause (#513's off-path set showed +3.5 % outside sync from code layout alone).
- **Regression bar**: on any cell, B's mean syncMs above A's by more than max(2 %, that cell's base-vs-base spread) stops the PR.
- **Correctness by frame digests**:
  - One capture pass per side per cell, outside the timed runs: the same command with `--iterations 300 --capture-views <dir> --capture-rooms 1`.
  - The digest is `tail -n +2 <dir>/<run>/room-0.ndjson | shasum -a 256`. The header line is skipped because it records the commit; the rest holds every frame (base64) and every projection per sync.
  - A-vs-A first, to show the capture is deterministic, then A vs B. Each cell's digests must be equal.
  - Bytes per sync aren't the check: they are integer-divided, so equal counts don't mean equal bytes.

### Mac (diagnosis only)

- `sample` of A and B per cell with the profile script's recipe (15 s, 1 ms, `--parallel false`), giving `node(atPath:)`'s share of sync and of the encode frame.
- No numbers from the Mac go into the result.

### Merge rule

- No cell regresses beyond the bar.
- Digests are identical on every cell.
- A gain inside the base-vs-base noise still merges, provided the B profile shows `node(atPath:)` gone from the encode frame. Its saving then isn't claimed as a number.

## Out of scope

- `positional` still builds `path + "/" + key` strings while it recurses into a nested value (firstSync, a whole entity set), and it needs them only for error messages. The same profile reports their share; a lazy path is a possible follow-up.

## Lessons

- Notes/solutions/2026-11-07-a-wire-form-keyed-by-schema-patterns-misses-undefined-shapes.md: a transform keyed by schema patterns fails open. This is why (a) covers every shape, and why the index falls back to the string walk wherever it can't prove the pattern's answer.
