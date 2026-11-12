# Sync policy per type, not per wrapper (#520)

**Status:** open. The direction was decided on 2026-11-12. Implementation starts after #519 merges, since both change `Sources/SwiftStateTree/Sync/SyncPolicy.swift`.

**Decided (maintainer, 2026-11-12):**
- `Sync` stores only the value and the dirty flag.
- The policy moves to per-type static data that `@StateNodeBuilder` emits.
- The user-facing spelling `@Sync(.policy)` stays the same.
- Removing or changing the public `Sync.policy` is accepted: it has no external users.
- The reason given is a cleaner architecture, not only speed.

Line numbers are on `main` at `4bb0e456`. Each fact is marked **checked** (read in the code or run) or **inferred** (reasoned, to be pinned by a test in the PR).

## 1. Why

`Sync<Value>` holds `policy: SyncPolicy<Value>`, `_wrappedValue` and `_isDirty` (`SyncPolicy.swift:114-117`, checked). Every instance of a declaration carries the same policy, so it belongs to the declaration, not to the value.

`SyncPolicy` is an enum whose `.perPlayer`, `.masked` and `.custom` cases hold closures. So any node type with a `@Sync` field isn't trivially copyable, even when all its field values are. Copying or destroying it goes through value witnesses, which retain and release each field's policy, instead of a memcpy.

Hero Defense copies node values often: nearest-target scans, `guard var m = state.monsters[id]`, and the copy-on-write copy of a collection while a copy of the state is alive. A profile had `MonsterState`'s copy and destroy witnesses at about 12 % of cycles. #519 removes the whole-collection copies; the per-element cost remains.

## 2. Every reader of a wrapper's `policy`, and what replaces it

The macro emits all of them (`Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift`, checked):

| Line | Emitted code | Replacement |
|---|---|---|
| :328 | `snapshot(for:dirtyFields:)`: `self._x.policy.filteredValue(self._x.wrappedValue, for: playerID)` | `Self._syncPolicy_x.filteredValue(self._x.wrappedValue, for: playerID)` |
| :380 | `_syncTableFields()`: `read: { $0._x.policy.filteredValue($0._x.wrappedValue, for: nil) }` | `read: { Self._syncPolicy_x.filteredValue($0._x.wrappedValue, for: nil) }` |
| :388 | `_syncCheck_x(_syncFieldKind { (node: Self) in node._x.policy.filteredValue(…, for: nil) })` | the same through `Self._syncPolicy_x` |
| :611 | the per-player path of the broadcast/per-player split: `self._x.policy.filteredValue(…, for: playerID)` | the same through `Self._syncPolicy_x` |

**No reader outside the macro (checked):**
- `git grep '\.policy\b'` over `Sources`, `Tests`, `Examples` and `Tools` finds no other read of a wrapper's policy.
- The other `.policy` reads are a different type: `FieldMetadata.policy` / `SyncFieldInfo.policyType` / `SyncTableField.policy`, all of type `PolicyType?`. They come from the macro's parsed `LocalPolicyType`, not from the wrapper:
  - `ActionRecorder.swift:296`;
  - `TypeToSchemaConverter.swift:66/110/193/220/345/429`;
  - `SyncPolicyNesting.swift:99`;
  - `SyncTables.swift:226/251/270/316/404/1495`;
  - `SyncValueSemantics.swift:55`.
- The other matches are the expected expansions in `Tests/SwiftStateTreeMacrosTests`:
  - `StateNodeBuilderMacroTests.swift:52/59/153/164/171/243/272/318/325`;
  - `StateNodeBuilderSnapshotDecodeTests.swift:53/60/67/173/184/195/202/205`.
  They change with the macro.

**Reflection over the wrapper (checked):** these read the wrapper's storage by label (`_wrappedValue`, or `wrappedValue`), never by position, so dropping `policy` doesn't move what they find:
- `SyncPolicyNesting.syncFieldValues(of:)` (`SyncPolicyNesting.swift:67-77`), used by the nesting and value-semantics checks;
- `SyncEngine.extractBroadcastSnapshotMirrorVersion` (`SyncEngine.swift:1289-1330`). Its comment names `policy` as a child; that comment is updated.

**Docs (checked):** `git grep` over `docs/`, `README*` and `.agent/` finds no `._x.policy` or `Sync.policy`.

## 3. What the macro emits

One static member per `@Sync` field, emitted by `@StateNodeBuilder`:
- **Non-generic type:**
  ```swift
  private static let _syncPolicy_x: SyncPolicy<T> = <the attribute's argument, verbatim>
  ```
- **Generic type:**
  ```swift
  private static var _syncPolicy_x: SyncPolicy<T> { <the argument> }
  ```
  A generic type can't have a static stored property. The macro already makes this split for `_hasPlayerDependentSyncFields` (`StateNodeBuilderMacro.swift:78-92`, checked).
  - Generic state nodes exist only in tests (checked): `FullStateSnapshotExpansionTests.swift:53` `Box<T, Other>`, `SyncLeafWritableTests.swift:60` `LeafGenericBox<T>`, `SyncTableDiffTests.swift:79` `TableGenericBox<T>`.
  - The computed form re-evaluates the expression per read. For `.broadcast` that is an enum constant; for `.perPlayerSlice()` it is a call that returns a case with a thin closure (inferred: no allocation, since the closure captures nothing).

**`T` is the field's declared type.** It is always written, because the macro already rejects a `@Sync` field without a type annotation (`StateNodeBuilderMacro.swift:248-252`, `missingTypeAnnotation`, checked). So the static has the same contextual type the attribute had: `.broadcast`, `.perPlayer { … }` and `.perPlayerSlice()` resolve the same way.

**`_syncPolicy_<name>` follows the macro's `_syncCheck_<name>` scheme.** `private` is enough: every reader is generated inside the type's body.

## 4. Non-literal policies and closures

The attribute's argument is copied as written into the static's initializer. That works for every form the attribute accepts, because:
- **An attribute argument can't reference `self`.** A property wrapper's attribute arguments are part of the backing storage's initializer, which Swift evaluates like a stored property's initial value, before `self` exists. An instance member there is rejected ("cannot use instance member … within property initializer"). So every expression that compiles in the attribute uses only:
  - globals;
  - static members, written with the type's name or `Self.`;
  - literals and closures that capture neither of the above in a way that needs `self`.

  All of these are valid in a static context too (inferred from the language rule; pinned by the compile of the cases below).
- **Forms in the repository (checked):**
  - implicit members: `.broadcast`, `.serverOnly`, `.perPlayerSlice()`;
  - a closure: `VisibilityTestLand.swift:203` `@Sync(.perPlayer({ (entities: [String: VisibleEntity], playerID: PlayerID) in … }))`;
  - a global: `NestedNodePolicyTests.swift:590/597` `@Sync(nestingUnknownIntPolicy)`.
  - `git grep -E '@Sync\(\.(perPlayer|masked|custom)'` counts 94 uses with a closure or a factory.

**What changes:** the expression is evaluated once per type (lazily, on the first read), not once per instance.
- A pure expression, which every policy in the repository is, behaves the same.
- An expression with a side effect, or one that reads mutable global state when an instance is created, would now be read once. That's a semantic change only for code written that way. The plan documents it in `Sync`'s doc comment (trade-off T4).

**Classification is unchanged.** The macro's parse of the argument into `LocalPolicyType` (`StateNodeBuilderMacro.swift:202-228`) is kept as it is. A non-literal argument stays `.unknown` in `getSyncFields()` and `FieldMetadata`, as today.

## 5. `Sync` itself

```swift
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    private var _wrappedValue: Value
    private var _isDirty: Bool = false
    public var wrappedValue: Value { get … set … _modify … }   // as after #519
    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) { _wrappedValue = wrappedValue }
    // isDirty, clearDirty(), markDirty(), updateValueWithoutMarkingDirty(_:) unchanged
}
```

- **`init(wrappedValue:_:)` keeps its signature,** so `@Sync(.x) var f: T = v` compiles unchanged. The argument is accepted and not stored (T1).
- **Manual constructions (checked):** `git grep -E 'Sync\(wrappedValue|Sync<[^>]+>\('` over `Sources`, `Tests`, `Examples` and `Tools` finds none outside the attribute.
  - Two state nodes conform by hand (`SyncLeafWritableTests.swift:86`, `NIOAdminRoutesReplayStartTests.swift:495`). Neither reads a policy.
- **`Sync.policy`:** removed, or replaced by an `unavailable` stub whose message says where the policy now lives (T2). Either way, code that reads it fails to compile, and no code in the repository reads it.

**`@Sync` without `@StateNodeBuilder`:** today the wrapper alone already does nothing for sync. Only the macro's generated members read the policy. And a type has to conform to `StateNodeProtocol`, which requires `snapshot(for:dirtyFields:)` and the dirty methods. So a type with `@Sync` and no builder either:
- writes those by hand: then a hand-written read of `_x.policy` fails to compile, with T2's message if the stub is chosen;
- or doesn't read the policy at all: then nothing changes for it.

Neither a compile-time error nor a fallback is possible from the wrapper itself: it can't see whether the macro ran.

**Recommendation: no fallback.** A runtime fallback would need the policy stored again, which is what this removes.

**Uses in the repository (checked):** none in `Sources`, `Tests`, `Examples` or `Tools`. Every `@Sync` outside a builder type is one of:
- an expected expansion in a macro test (the attribute is gone after expansion);
- or a doc example, `Sources/SwiftStateTreeDeterministicMath/Docs/DeterminismRules.md:46/53/225/232`, which omits the attribute for brevity. It gets `@StateNodeBuilder` added in the same PR.

## 6. Layout before and after

**Before:** measured on #519's branch (Swift 6.4.2, macOS, checked).

**After:** inferred by Swift's struct layout rule, where each field sits at the next offset aligned for it.
- `Sync<Int>` would be size 9 and alignment 8.
- `Sync<Position2>` would be size 9 and alignment 4.
- `Sync<Angle>` and `Sync<Float>` would be size 5 and alignment 4.

| Type | Before: size / stride / `_isPOD` | After (inferred): size / stride / `_isPOD` | Note |
|---|---|---|---|
| `MonsterState` (8 fields, values 56 B) | 281 / 288 / false | 89 / 96 / true | |
| `PlayerState` (8 fields) | — / 296 / false | 105 / 112 / true | |
| `TurretState` (6 fields) | — / 232 / false | 81 / 88 / false | `ownerID: PlayerID?` holds a `String`, so the type stays non-POD; its copies retain one reference instead of six policies |

- **Pinned by a test** in `Examples/GameDemo/Tests/GameContentTests`: `MemoryLayout<…>.size`, `.stride` and `_isPOD` for the three types.
- The PR records the "before" values from main in its body, and the test asserts the "after" values.
- **A core test pins the rule itself on a test node** in `SwiftStateTreeTests`: a node of `@Sync` `Int` fields is POD. So a later change that puts a reference back into `Sync` fails in core, not only in the demo.

## 7. Element dirty flags: kept

**Checked:**
- The sync engines read only the root node's flags, through `getDirtyFields()`/`isDirty()` on the state:
  - `SyncEngine.swift:868/1085`;
  - `TransportAdapter.swift:3889/4086/4091`.
- The generated `clearDirty()` recurses into a nested single node (`StateNodeBuilderMacro.swift:769`) but skips collections (:814).
- So the flags of a node inside a collection are set and never read, and a nested single node's flags are cleared and never read by the framework.

**They stay.**
- `isDirty()` and `getDirtyFields()` are public protocol API, and a game can call them on a nested node.
- The same node type can be a land's root in one place and an element in another. The macro sees one declaration, so it can't drop the flag for the element case only.

Dropping them would take `MonsterState` from 96 to 64 bytes (inferred). That is a separate trade-off, not part of this plan (T3).

## 8. Steps (one PR, after #519 merges)

1. **Tests first** (red where they can be):
   - the layout pins of §6;
   - macro expansion tests for a non-generic node, a generic node, a closure policy and a global policy (`@Sync(nestingUnknownIntPolicy)`), each asserting the emitted `_syncPolicy_` static and the readers;
   - a compile-and-run test that a closure policy and a global policy still filter per player as before.
2. **The macro:**
   - emit the statics;
   - switch the four readers (§2);
   - update the expected expansions in the macro tests.
3. **`Sync`:**
   - drop the stored `policy`;
   - the init ignores the argument (T1);
   - `policy` removed or the stub (T2);
   - doc comment on evaluation timing (T4);
   - the `SyncEngine.swift` reflection comment.
4. **The doc example** in `DeterminismRules.md`.
5. **Solutions:** an entry if a reusable lesson comes out (e.g. that a per-instance closure-holding wrapper makes every node type non-POD).

## 9. Verification

- `swift build`, and the touched suites in debug and release:
  - `SwiftStateTreeMacrosTests`;
  - `SwiftStateTreeTests` and `SwiftStateTreeTransportTests`, with `IN_TURN_SYNC=true` and `=false`;
  - `GameContentTests` (it holds `HeroDefenseWireBytesTests` and `HeroDefenseStateHashPinTests`).
- Mutants:
  - the macro emitting `.broadcast` for every static (the per-player filtering tests must fail);
  - a static evaluated per instance (no test can see that unless T4's doc example is pinned, so this one is listed as equivalent);
  - `policy` stored again (the POD pin fails).
- Full `swift test` and E2E on CI, all three encodings.
- **Bytes and frames:** EncodingBenchmark captures, base (main with #519) against head. Bytes and per-session digests must be identical for the four #519 cells (`cap100-local`, `cap100-router`, `cap500-idle`, `vis-tick`), with the committed `capture-digest.py`.
- **Host A/B after #519's:**
  - base = main with #519, head = this PR, the same cells and procedure as #519's brief;
  - judged on time outside sync (timeMs − syncMs, tickMs), with `syncMs` reported;
  - plus `perf stat` instructions/cycles on `cap100-local`, if approved as for #519.
  - Expected: instructions and non-sync time fall where nodes are copied (the scans and the `guard var` copies). `syncMs` may fall too, because the encoders copy node values. The A/B reports that, but it isn't judged.

## 10. Trade-offs

Each one is decided separately; the recommendation comes first.

- **T1, the init's policy argument:**
  - Recommended: keep `_ policy: SyncPolicy<Value>` and ignore it. The evaluation per instance stays, which is cheap for every form in the repository.
  - Alternative: `@autoclosure` it, which is source compatible and skips the evaluation, but changes the init's type.
- **T2, `Sync.policy`:**
  - Recommended: an `@available(*, unavailable, message: "The policy is per declaration now; @StateNodeBuilder reads it from the attribute")` computed stub, so a hand-written read gets a message that says what to change.
  - Alternative: remove it outright.
- **T3, element dirty flags:** recommended to keep them (§7). Removing them is its own decision with its own A/B.
- **T4, evaluation timing:** recommended to accept once-per-type evaluation and document it on `Sync`.
