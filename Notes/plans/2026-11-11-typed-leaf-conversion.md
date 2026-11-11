# Flat storage step 3, PR E: typed conversion of changed leaves

Status: reviewed, GO, 2026-11-11 (two rounds; section 10). Code after the benchmark's router path (#509) merges. PR E of `2026-11-10-row-addressing.md` (section 9), read at `main` `e9e95ed2` (#503 merged; PR C's three PRs, D's load-test client and the benchmark's router path in progress as #509).

## Decisions

| Date | Decision | By |
|---|---|---|
| 2026-11-11 | E goes before F (the default flip), with its own package-level switch, so its gain is measured on its own (E on against E off). Rows on against rows off is measured with the benchmark's router path, before E | maintainer, on #392 |
| 2026-11-11 | The writer is chosen at registration, for a field the macro registered with its standard conversion (section 2); the macro's only change is that marker, a public enum (section 9a) | review |
| 2026-11-11 | E part 1 and E part 2 are separate PRs; E part 2 only if E part 1's profile leaves the encoder's value step as a bucket worth removing (section 7) | review |

## 0. What E removes

On cap100 with the tables on, the ~201 µs conversion bucket (step 3 plan, section 0) is what one changed leaf costs before the encoder sees it. In `SyncEquatableDiffer.diff` (`SyncTables.swift`), once `==` says a field changed:

1. `convert(old)` and `convert(new)`: the macro's conversion. For a non-optional primitive the macro already emits a direct form (`.int(Int(x))`, `.double(Double(x))`, `.string(x.rawValue)`; `StateNodeBuilderMacro.swift`, `generateConversionCode`). For everything else, optionals included, it emits `SnapshotValue.make(from: Any)`: an existential box and a chain of `as?` casts; for `Position2`, its `@SnapshotConvertible(atomic: true)` object.
2. `SyncEngine.diffSnapshotValues(from:to:basePath:layout:)` on the two snapshots, which for a scalar or atomic leaf always yields one `.set` at the field's path.
3. A `StatePatch` with that split.

The encoder then turns that value into its wire form: `atomicLayout.positional(value, atPath:)` (an atomic object becomes an array of its leaves), then `encodeSnapshotValueToMessagePack` (or the JSON container), building a second tree.

Today's diff (`compareSnapshotValues`) first returns nothing when `SnapshotValue.sameValue(old, new)` (NaN equals NaN, -0.0 equals 0.0). After that, for a scalar it emits one set, and for an object it emits one set only where the layout says atomic at that path (`layout?.isAtomic == true`); otherwise it recurses into per-component patches. So for a leaf of the writer set at a path the diff treats as one value, step 2 is `[]` when the two values are the same value and `[.set(path, convert(new))]` otherwise. Steps 1 and 2 reduce to a same-value test and converting `new` once, without `Any`. That is E part 1. For a non-optional primitive, part 1 saves `convert(old)` and the snapshot diff only, since its conversion is already direct.

**What part 1 can recover.** The ~201 µs is the whole cap100 sync's conversion bucket (of ~914 µs), not the cost of one leaf, and part 1 keeps one `convert(new)` per changed leaf, so not all of it is recoverable. By class:
- **non-optional primitives** (most of Hero Defense's `Int` and `Int64` fields): `convert(old)` (already direct, so cheap) and the snapshot diff. Small per leaf;
- **optionals and atomics** (`Position2`, `Position2?`, `PlayerID?`, `Angle`): both `make(from: Any)` converts and their `as?` chain go; `convert(new)` becomes the typed witness. This is where part 1's gain is, and `position` changes on every moving row every tick.

The profile has no split of the bucket by class. Part 1's first working build takes one, and the PR states the expected share before the A/B. The bar is the cap100 rows-on cell (section 6), and "within noise, not merged" may well apply to part 1 on its own. E part 2 then skips the `SnapshotValue` itself for the opcode encoders.

## 1. Which fields get a writer

A field gets a leaf writer when **all** of these hold. Every other field keeps today's path, per field, as a non-`Equatable` field takes the fallback in step 2:

- **Its kind is `.value`** (step 2's registration): `Equatable`, holding no node and no reference.
- **Its type is in the writer set:**
  - `Bool`;
  - `Int`, `Int8`, `Int16`, `Int32`, `Int64`, `UInt8`, `UInt16`, `UInt32`;
  - `UInt` and `UInt64`, through the same `unsigned` helper `make` uses;
  - `Float` (written as `Double(value)`, as `make` does), `Double`;
  - `String`, `PlayerID`, `ClientID`, `SessionID`, `LandID`;
  - the atomic types of `SwiftStateTreeDeterministicMath` (`IVec2`, `IVec3`, `Position2`, `Velocity2`, `Angle`, and whichever others have an atomic layout). Each conformance returns exactly its own conversion: `IVec2`'s hand-written `toSnapshotValue()`, and the `@SnapshotConvertible(atomic: true)` form for `Position2` (its `v` object);
  - `Optional` of any of these: nil writes `null`, as `make` does.
- **The macro registered it with its standard conversion** (section 2): a `convert` the macro emitted for the declared type, not a hand-written registration.
- **Its change test matches today's `sameValue`:** a leaf writer emits a set only when the two values are not `sameValue` as snapshots. **The rule for every type: same on the converted form**, not the type's own `==`. Each writer type defines `syncLeafSame(_:_:)` to compute that without converting:
  - `Float` and `Double` (and their optionals): `a == b || (a.isNaN && b.isNaN)`, so an unchanged NaN sends nothing, as today. `==` alone would send a set every sync;
  - the integer types, `Bool`, `String`, and the single-field IDs `PlayerID`, `ClientID`, `SessionID`: `==`, which compares the one field the snapshot holds;
  - `LandID`: `rawValue` (`"landType:instanceId"`), not its synthesized `==`. `("a", "b:c")` and `("a:b", "c")` are `!=` but convert to the same string, so today they send nothing;
  - atomic types: component-wise on their integer leaves (`sameFields` on the converted object).
  - The `SyncEquatableDiffer` keeps `==` as its first test; on `!=` a leaf field then asks `syncLeafSame` before writing, so a NaN that `==` calls changed is still no patch.
- **The diff treats it as one value at its path:** a scalar always; an atomic type only where the field's layout node `isAtomic` (checked per diff call, from the `layout` the differ already receives). With no layout node (a generic node's `T == Position2` outside the layout), today's diff recurses into components, so the field takes today's path.

Not in the writer set, so on today's path:
- arrays and non-atomic structs. Today's diff replaces an array whole, so the single-set rule does hold for arrays; they are left out only to keep E's writer set and its differential corpus small (no element-type matrix). They can join later with their own corpus;
- value maps (their entries aren't columns: two dynamic keys);
- enums;
- custom `SnapshotValueConvertible` types, the user's own atomic types included;
- anything inside a generic parameter the runtime check can't see as one of the above.

Any of these can join later with its own differential test.

**Which Hero Defense row fields get one:** every column field in the step 3 plan's table, `targetPosition: Position2?` and `ownerID: PlayerID?` included. Root scalar fields (`score`, tick counters) take the writer too: it is per field, not per table.

## 2. Where the writer comes from: registration, not the macro

**The proposal: a registration check, plus one marker from the macro.** `SyncTableField.make<V>` already resolves `V` at registration:
- `syncTableEquality(of:)` opens `V` as `Equatable`;
- `syncTableKeyString` picks a key writer with an `unsafeBitCast` once `K == String` is checked.

E adds one more check of the same kind:

```swift
/// A value the typed diff writes without `SnapshotValue.make(from: Any)`.
package protocol SyncLeafWritable {
    /// Exactly the macro's standard conversion of this type; never throws.
    var syncLeafSnapshot: SnapshotValue { get }   // E part 1
    /// `SnapshotValue.sameValue` of the two converted values, without converting.
    static func syncLeafSame(_ lhs: Self, _ rhs: Self) -> Bool
    /// The wire leaves: a scalar, or an atomic type's leaves in `atomicLeafPaths` order.
    var syncLeaf: SyncLeafValue { get }           // E part 2
}
```

Registration does `V.self as? SyncLeafWritable.Type`, then opens the metatype with a generic helper (`func open<W: SyncLeafWritable>(_: W.Type) -> SyncLeafAccess<V>`), as `syncTableEquality(of:)` opens `Equatable`. Inside it, `V == W` is established by the cast, and the closures convert a `V` to `W` with `unsafeBitCast` on the value's static type, never on an existential box (`any SyncLeafWritable`); a value is never boxed on the hot path. `SyncEquatableDiffer` gets the result as an optional `leaf` (`same` and `snapshot` closures). When it is set and the layout check of section 1 passes, a value that `==` and `same` both call changed appends one `StatePatch(path:, operation: .set(leaf.snapshot(new)), split:)`. The split comes from the cursor, as `super.diff` computes it (`cursor?.split(of:under:)`). It skips `convert(old)` and the snapshot diff.

**Only the macro's registrations qualify.** `SyncTableField.make(…, convert:)` is public and takes any closure: a hand registration could convert an `Int` to a string, and a writer would silently change its type. So the writer is taken only when the registration says its `convert` is the macro's standard conversion for the declared type. The macro passes that as one more argument, `conversion: .standard`, to the existing `make` overloads. The parameter is new public API: `conversion: SyncTableConversion = .custom`, an additive, defaulted parameter with a public enum of two cases. Every hand registration keeps today's path. The differential test (section 4) compares each writer type against the conversion the macro emits for that type, not against `make(from:)`.

**Why the macro passes a marker and not a writer, and why no new `make` overload:**
- **A `make` overload constrained on the protocol** must be public, since the macro's expansion in the user's module calls it. That would make `SyncLeafWritable` public API. A `package` protocol with a runtime check keeps the protocol and every conformance out of public API (the DeterministicMath conformances are `package`, in the same package); the only public addition is the marker parameter below.
- **Overload resolution picks the unconstrained `make` for a generic node's `T`** (`Notes/solutions/2026-11-06-protocol-extension-default-wins-overload-resolution.md`). The runtime check sees the real type at registration, so a `Box<Int>` field gets its writer.
- **A macro-generated writer per field** would emit one more closure per `@Sync` field in every user type: more expansion and more type checking. The marker is one enum literal per field, and the runtime check runs once per type.

**Per shape:**

| Shape | E's handling |
|---|---|
| Optional of a writer type | `Optional: SyncLeafWritable where Wrapped: SyncLeafWritable`; nil is `.null` |
| Nested node held directly in a row | its fields are leaves of the row, each registered from that node type's own `_syncTableFields()`, so each gets or doesn't get a writer on its own. No new code |
| Optional nested node going nil or coming back | a set of the whole node or of `null`: today's path (rare: a spawn-like change) |
| `@Internal` field | not synced, so no `SyncTableField`; untouched |
| Value map in a row | today's entries and today's path (two dynamic keys, not a column) |
| Array or non-atomic struct replaced whole | today's path (section 1) |
| Node map (the row table itself) | the creates' whole-row value stays on today's path; only column values and root leaves get the writer |

**A release guard on the marker.** `.standard` is a trust contract: a hand registration can pass it with any `convert`. So on each leaf field's first decision (once per differ, per process), the differ compares `leaf.snapshot(new)` with `convert(new)` by `sameValue`. On a mismatch it reports through `SyncTableContract`'s release path (a log line) and drops that field's writer for good; the field takes today's path from then on. The cost is one extra convert per field per process. Test: a mislabelled hand registration (`.standard` with an `Int` converted to a string) ends on today's bytes.

**A conformance that lies** (a `syncLeafSnapshot` that isn't the macro's conversion, or a `syncLeafSame` that isn't `sameValue`) is the failure E adds. The differential test (section 4) runs every conformance against `make`. Debug builds also check every leaf write (section 4, fourth gate).

## 3. The switch

- **`TYPED_LEAF_VALUES`** (Bool, default off): read once per process through `EnvHelpers.getEnvBool` with a `TransportEnvKeys` constant.
- **A `package var typedLeafValues`** on `TransportEnvConfig`, next to `useSyncTables`, with an `@_spi(Diagnostics)` accessor like `syncTablesEnabled`, so a benchmark or an equivalence test can pin one side in one process.
- **It takes effect only with `useSyncTables`.** The adapter passes it to `SyncTableBroadcastDiff` at construction, which passes it on to registration. With the tables off it is ignored, and the env table says so.
- **Default:** off in E. Whether it flips in F's PR, after F, or not at all is the maintainer's call from E's A/B (section 6). There are no users yet, so there is no compatibility reason to wait.
- **Docs:** a row in `TransportEnvConfig`'s env table and in `docs/transport`'s env list (both languages), marked experimental like `USE_SYNC_TABLES`.

## 4. Gates: bytes, the differential test, the oracle

**Byte identity, by construction and checked:**
- **E part 1:** the patch carries the same `SnapshotValue` as today, so all three encodings are unchanged by construction.
- **E part 2:** the opcode encoders write a leaf from `SyncLeafValue` through the same scalar writer `encodeSnapshotValueToMessagePack` uses (MessagePack's int width choice, `Double` as float64). The opcode JSON encoder writes it through the same container calls. `jsonObject`, the recorder's digest, the late-join and resync views, and field merge's value list read `operation`, which materializes the `SnapshotValue` on access (section 5): same value, same bytes.
- **Atomic leaves (E part 2):** the positional form follows the layout's ordered leaf paths and refuses a missing one (`AtomicPositionalForm`), and an encoder can carry its own layout. So each atomic writer type has its leaf paths as a static list, and the leaf form is used only where the encoder's own layout node at that path has `leafPaths` equal to that list, in order. The comparison is precomputed once per (layout node, type). Anywhere else (another order, a missing path, keyed mode with `atomicValues == .keyed`, no layout node) the encoder materializes the `SnapshotValue` and takes today's path, so the positional choice and its refusals stay the encoder's.

**The checks:**
1. **The differential test against `SnapshotValue`** (new suite, `SyncLeafWritableTests`), for every type in the writer set, over a fixed-seed corpus plus edge values:
   - integers: `.min`, `.max`, 0, -1, and `UInt64` above `Int.max`;
   - floats: NaN, ±0.0, ±infinity, subnormals, `Float.greatestFiniteMagnitude`;
   - strings: empty, non-ASCII, non-NFC, and a 1 KB string;
   - `nil` for each optional.

   It asserts, for every value and every pair:
   - `syncLeafSnapshot` equals **both** standard forms the macro emits for that type: the direct form for the plain spelling (`.int(Int(value))`), and `make(from: value)` / `make(from: value as Any)` for every other spelling (`Swift.Int`, a typealias, a generic `T == Int`, every optional; `generateConversionCode`'s default branch). Both are registered `.standard`. Each is compared with `sameValue` and with the encoded bytes (`SnapshotValue`'s synthesized `==` is false for NaN, so it can't be the comparison);
   - `syncLeafSame(a, b) == sameValue(convert(a), convert(b))`, over every pair: NaN pairs, and `LandID("a", "b:c")` against `LandID("a:b", "c")` (and their optionals). This check catches the whole class of a `==` finer than the converted form;
   - `diffSnapshotValues(convert(a), convert(b), layout)` is `[.set(path, convert(b))]` when not `syncLeafSame(a, b)`, and empty otherwise, with the atomic layout node present; with it absent, an atomic type's field is shown to take today's path. This is the single-set rule part 1 relies on;
   - E part 2: for each opcode encoding, in positional and in keyed mode, the bytes of a column entry written from `syncLeaf` equal those written from the `SnapshotValue`.
2. **Byte identity on real frames:**
   - the Transport suite under `USE_SYNC_TABLES=true TYPED_LEAF_VALUES=true`, which covers the byte fixtures, the sync-output goldens and the replay hash;
   - EncodingBenchmark bytes per sync, E on against E off: 3 formats × rows on/off on the router path, and the default path's 3 formats;
   - E2E in all three encodings with E on.

   CI's `USE_SYNC_TABLES` job gains a run with both switches on.
3. **The state-equivalence oracle** (step 3 plan, section 7), with E on: the shape matrix and the visibility lands, rows on and off. The decoded client state equals the server's.
4. **A debug shadow check:** in debug builds, every leaf decision (write or no write) also runs today's conversion and diff and reports through `SyncTableContract` if the patches differ, compared with `sameValue` on the values. Every debug test run with the switch on is then a differential run on real states.
5. **Mutants** (each must fail a test):
   - `Float` written without the `Double` widening;
   - `Optional.none` writing nothing instead of `null`;
   - an atomic type writing its leaves out of order (part 2);
   - `Double`'s `syncLeafSame` as `==` (an unchanged NaN field sends a set);
   - the layout check dropped (a generic node's `T == Position2` without a layout node);
   - the registration marker ignored (a hand registration converting an `Int` to a string takes the writer).

## 5. E part 2's patch storage

To let the opcode encoders skip `SnapshotValue`, a leaf patch has to carry the typed leaf and build the `SnapshotValue` only when something reads it. `StatePatch.operation` is `public let`. E part 2 makes it a `public var { get }` over a package storage enum:
- `.operation(PatchOperation)`;
- `.leafSet(SyncLeafValue)`, which reads as `.set(…)`.

**No cache:** a struct can't cache in a non-mutating getter, so a `.leafSet` patch rebuilds its `SnapshotValue` on every read of `operation`. That is cheap for a scalar and an object build for an atomic value. So the hot-path readers don't read `operation` for a leaf patch. They get two package accessors that never build a value:
- `opKind` (set, delete or add);
- `leafValue: SyncLeafValue?`.

`==` and `Codable` stay on the built value. The hand-written `init(path:operation:)` is unchanged and stores `.operation`, so the change is source-compatible for every reader. Building never throws: leaf types don't, and atomic leaves carry their static leaf path names.

**The readers of `operation`, and what each reads after part 2** (lines at `e9e95ed2`):

| Reader | Today | After part 2 |
|---|---|---|
| `RowEntryPlan.plan` (`RowEntryPlan.swift:66`) | the op, to classify | `opKind` |
| `FieldMergePlan` (`FieldMergePlan.swift:206–222`, `:320–327`) | the op, then the value of each merged field | `opKind`; the value as `leafValue` when present, else `operation` |
| MessagePack opcode encoder (`:230–232`, `:346–349`) | the op and the value | `opKind`; `leafValue` written directly when present and the layout check passes, else `operation` |
| JSON opcode encoder (`:276–278`, `:332–335`) | the op and the value | the same |
| `jsonObject` encoder, the recorder's digest, the late-join and resync views, `==`, `Codable`, tests | the patch as a value | `operation`, rebuilt per read (off the opcode hot path) |

Part 2's implementation checks the full list with the LSP's references to `operation` and keeps this table current in the PR body.

**Its risk is every reader of `operation`**, which is why it is its own PR:
- the cost of the getter on paths that never see a leaf patch (one enum check);
- `StatePatch`'s size.

E part 2's A/B has an E-off cell for exactly that (section 6). `SyncLeafValue` holds scalars inline and an atomic value's leaves inline up to four, so a leaf patch allocates nothing for Hero Defense's types.

## 6. The A/B

On the measurement machine, release, pinned container, with the benchmark's router path (#509) and `USE_SYNC_TABLES=true`.

**Same-binary cells** (E on against E off, with the env set per run, so there is no build noise):

| Cell | Flags | Formats |
|---|---|---|
| cap100, active | `--join-through-router on --row-addressing on` | messagepack-pathhash, opcode-json-pathhash |
| cap100, active | `--join-through-router on --row-addressing off` | the same |
| joint, and cap500-idle | the parent plan's cells, rows on | messagepack-pathhash |

**Base against head with E off:** E part 1's and E part 2's head against their base, at the default path's matrix (as #509's brief), to show the off path didn't move. This is where E part 2's `StatePatch` change would show.

**Order and repeats:** ABAB interleaved, at least 5 repeats per side. Every run's bytes are checked against the cell's expected value.

**Bars:**
- **The off path:** head's median inside base-against-base noise, in every cell.
- **E's gain, per PR:** E on is no slower than E off in any cell. On the cap100 rows-on cell, the expected direction is a drop toward the conversion bucket (up to ~200 µs of sync time on the Mac profile; less for E part 1).
  - If a PR's gain is within noise in that cell, it isn't merged. The finding and the profile go to the maintainer as a trade-off.
- **The step's 50 % bar** is judged at the end, as decided, not by E alone.

**Attribution:** against the router path's numbers from #509's measurement:

| Measurement | Source |
|---|---|
| tables off, sync time | #509's run |
| tables on, rows off | #509's run |
| tables on, rows on | #509's run |
| tables on, rows on, E on | this A/B |

- Each step's share is its difference over the tables-off time.
- A sampled profile of cap100 rows-on with E on must show the conversion bucket shrinking (and, for E part 2, the encoder's value step).
- If a gain shows up somewhere else, the A/B says so; it isn't counted as E's.

## 7. PR split

| PR | Content | Wire | Gates |
|---|---|---|---|
| E part 1 | `SyncLeafWritable` with `syncLeafSnapshot` and its conformances (core, DeterministicMath); registration's check; `SyncEquatableDiffer`'s leaf path; the switch, env row and docs; the debug shadow check; the differential test's `SnapshotValue` and diff-shape parts; mutants | byte-identical (same `SnapshotValue`) | section 4, checks 1 (no byte part), 2, 3, 4, 5; A/B |
| E part 2 | `SyncLeafValue` and `syncLeaf`; `StatePatch`'s storage; the leaf path in both opcode encoders; the differential test's byte part | byte-identical | section 4 in full; A/B with the off-path cell |

- **Sources and Examples** go in separate commits.
- **EncodingBenchmark** records `TYPED_LEAF_VALUES` in its metadata env allowlist. That is an Examples commit in E part 1; default output only gains the key.
- **E part 2 is conditional:** it goes ahead only if E part 1's profile shows the encoder's value step (positional transform plus `MessagePackValue` building for leaves) as a bucket worth its risk. The numbers go to the maintainer with E part 1's A/B.

## 8. Macro tests and compile-time cost

- **One expansion change:** each `SyncTableField<Self>.make(` call gains `conversion: .standard,`. The expansion snapshot tests change by exactly that line per field, and part 1's body says so; any other expansion difference is a must-fix.
- **New registration tests** (in `SyncTablesTests`, step 2's per-shape suite) check per shape whether the writer was taken:
  - each writer type and its optional;
  - a generic node's `T == Int` (taken) and `T == [Int]` (not taken);
  - a nested node's leaves;
  - a custom `SnapshotValueConvertible` (not taken);
  - a hand registration of a writer type without the marker (not taken);
  - a typealiased field (`typealias Score = Int`) and a `Swift.Int` field: taken, with the `make(from:)` form;
  - a generic node's `T == Position2` with no atomic layout node (not taken at diff time);
  - an enum (not taken).
- **Compile time:** one enum-literal argument per `@Sync` field in user modules; the added code is otherwise the conformances and one cast per field at registration.
  - E part 1 reports clean release build time of `Examples/GameDemo` (3 runs per side, same machine) and registration time per type.
  - Bar: build time within run-to-run noise.

## 9. Not in E

- The creates' whole-row values, the late-join and resync views, firstSync: still `SnapshotValue`, built from the tables as today.
- Per-player fields and fallback fields.
- Arrays, non-atomic structs and user atomic types in the writer set.
- Removing the old path: it stays as `pathIndex`'s did, until a later removal.

## 9a. Public API

- `SyncTableConversion` (a public enum, `.standard` and `.custom`, undecorated, under `SyncTables.swift`'s "Registration (called by the macro)" mark) and a defaulted `conversion: SyncTableConversion = .custom` parameter on the four `SyncTableField.make` overloads (part 1). Only `make<V>` uses it; the node overloads accept and ignore it, so the macro emits one form for every field. Additive, approved 2026-11-11. Call sites are unchanged; a function reference to the old four-argument `make` would break. `.standard`'s doc: the conversion `@StateNodeBuilder` emits for the declared type; hand registrations leave the default. It can't be an SPI: the expansion compiles in the user's module.
- Part 2: `StatePatch.operation` from `public let` to a get-only `public var`. Source-compatible for reads, pattern matching and key paths.

## 10. Review rounds

**Round 1 (2026-11-11):**
- **must-fix 1, NaN:** fixed by `syncLeafSame`, which matches `sameValue` (section 1). The differential test and the shadow check compare with `sameValue`.
- **must-fix 2, a registration's own `convert`:** fixed by taking the writer only for the macro's standard conversion, marked at registration (section 2). That reverses "no macro change": the macro passes one argument, and the expansion snapshot tests change by that argument per field (section 8).
- **must-fix 3, positional by count:** fixed by comparing the full ordered leaf paths, precomputed per layout node (section 4).
- **should 1:** the atomic writer only where the layout node is atomic, with a test of a field without one (section 1).
- **should 2:** no cache, rebuilt per read; `opKind` and `leafValue` for the hot-path readers; the reader table (section 5).
- **nits:** `init(path:operation:)` is hand-written; the array exclusion's reason is corrected.

**Round 2 (2026-11-11): GO after one must-fix.**
- **must-fix, `LandID`:** same on the converted form for every type; `LandID` compares `rawValue`; the colliding pair is in the corpus (section 1, section 4).
- **should 1:** the release guard on `.standard`, with its test (section 2).
- **should 2:** both standard forms in the differential test; the typealias registration test (sections 4, 8).
- **should 3:** part 1's expected gain by class, and the bucket's scope corrected (section 0).
- **nits:** "call sites unchanged"; only `make<V>` uses the marker (section 9a).

## Solutions consulted

- `2026-11-06-protocol-extension-default-wins-overload-resolution.md`: why the writer is a registration check, not an overload.
- `2026-11-07-encoded-bytes-vary-with-per-process-hash-order.md`: object values keep going through the existing encoder, so map key order is unchanged; leaf values are scalars or positional arrays.
- `2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing.md`: the unsigned writers reuse the `SnapshotValue.unsigned` helper the macro emits, rather than converting on their own.
