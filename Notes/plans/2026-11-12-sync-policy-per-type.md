# Sync policy per type, not per wrapper (#520)

**Status:** open, rev 2 (2026-11-12): generic contexts (§3), the evaluation contract (§4), pins and coverage (§9). The direction and trade-offs T1–T4 were decided on 2026-11-12 (§10). Implemented in PR #527.

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
- **A type the macro can prove non-generic:**
  ```swift
  private static let _syncPolicy_x: SyncPolicy<T> = <the attribute's argument, verbatim>
  ```
- **Any other type:**
  ```swift
  private static var _syncPolicy_x: SyncPolicy<T> { <the argument> }
  ```
  A generic type can't have a static stored property. The macro already makes this split for `_hasPlayerDependentSyncFields` (`StateNodeBuilderMacro.swift:78-92`, checked), but it tests only the struct's own `genericParameterClause` (:82). A node nested in a generic type, or in an extension of one, gets a `static let` today and fails to compile. No such node exists in the repository (checked), so that's a latent gap, not a regression.

**The predicate, shared by both statics** (so this PR also fixes `_hasPlayerDependentSyncFields`): the macro walks `context.lexicalContext` (swift-syntax 600+; the package takes 602..<605) and emits a `static let` only when:
- the struct has no generic parameters, and
- every enclosing declaration is a `struct`, `class`, `enum` or `actor` without generic parameters.

Anything else takes the computed branch:
- an enclosing `extension`: its extended type's generic parameters aren't visible in the syntax, so `extension Outer { … }` can't be told apart from an extension of a generic `Outer`;
- an enclosing function, closure or other local context, which can be generic or capture a generic context.

The computed branch compiles in every context. The cost is that its argument is evaluated per read (§4).

- **Generic state nodes in the repository** exist only in tests (checked): `FullStateSnapshotExpansionTests.swift:53` `Box<T, Other>`, `SyncLeafWritableTests.swift:60` `LeafGenericBox<T>`, `SyncTableDiffTests.swift:79` `TableGenericBox<T>`. Function-local nodes exist in tests (e.g. `SyncEngineDirtyTrackingTests.swift`, `NestedNodePolicyTests.swift`, `FieldMetadataDefaultValueTests.swift`, `SchemaGenTests.swift`). Before #520 they got static stored properties, which a local type of a non-generic function may have. Now they take the computed branch and lose the macro's `hasPlayerDependentSyncFields` override, falling back to the protocol's cached default, which gives the same value. That's harmless, and it covers the computed branch.
- For `.broadcast` the per-read evaluation is an enum constant. For `.perPlayerSlice()` it is a call that returns a case with a thin closure (inferred: no allocation, since the closure captures nothing).
- **Pinned** by macro expansion tests (§8) and by compile fixtures in `SwiftStateTreeTests`: a node nested in a generic struct, one in an extension of a generic struct, and one declared inside a function.

**`T` is the field's declared type.** It is always written, because the macro already rejects a `@Sync` field without a type annotation (`StateNodeBuilderMacro.swift:248-252`, `missingTypeAnnotation`, checked). So the static has the same contextual type the attribute had: `.broadcast`, `.perPlayer { … }` and `.perPlayerSlice()` resolve the same way.

**`_syncPolicy_<name>` follows the macro's `_syncCheck_<name>` scheme.** `private` is enough: every reader is generated inside the type's body.

## 4. Non-literal policies and closures

The attribute's argument is copied as written into the static's initializer. That works for every form the attribute accepts, because:
- **An attribute argument can't reference `self`.** A property wrapper's attribute arguments are part of the backing storage's initializer, which Swift evaluates like a stored property's initial value, before `self` exists. An instance member there is rejected ("cannot use instance member … within property initializer"). So every expression that compiles in the attribute uses only:
  - globals;
  - static members, written with the type's name or `Self.`;
  - literals and closures that capture neither of the above in a way that needs `self`.

  All of these are valid in a static context too (inferred from the language rule; pinned by the compile of the cases below, including a compile fixture whose policy is a static constant referenced qualified, as `Self.x` and as `TypeName.x`).
- `SyncPolicy` is `Sendable` with `@Sendable` closures (`SyncPolicy.swift:13-39`, checked), so a `static let` of it is accepted under Swift 6. The generated member is in the same file as the attribute, so `private` and `fileprivate` globals stay reachable.
- **Forms in the repository (checked):**
  - implicit members: `.broadcast`, `.serverOnly`, `.perPlayerSlice()`;
  - a closure: `VisibilityTestLand.swift:203` `@Sync(.perPlayer({ (entities: [String: VisibleEntity], playerID: PlayerID) in … }))`;
  - a global: `NestedNodePolicyTests.swift:590/597` `@Sync(nestingUnknownIntPolicy)`.
  - `git grep -E '@Sync\(\.(perPlayer|masked|custom)'` counts 94 uses with a closure or a factory.

**What changes: when and where the expression is evaluated.**
- **When:**
  - In a node the macro proves non-generic (§3), the policy that filters is evaluated once per type, at the static's first read.
  - In any other node it is evaluated per read: two snapshots of one instance can filter with different policies if the expression isn't pure.
  - In both cases the attribute's argument is still evaluated at each init that initializes the field through the attribute (an initial value, or `self.x = …` in an init), since the init keeps its parameter (T1), and that value is discarded. For a field declared without an initial value, an init that builds the wrapper by hand doesn't evaluate it.
- **Where:** the first read, or every read for the computed branch, runs on whatever executor syncs the land: the keeper's, or the adapter's with in-turn sync off. It no longer runs where the instance is created.
  - A policy that is a global-actor-isolated static, read from the nonisolated generated readers, is a compile error under Swift 6. That's the wanted outcome.
- **The contract** (documented with T4): a policy expression must be pure, callable from any context, and depend on nothing that changes after the land starts. Every policy in the repository is a pure expression, so they behave the same.
- **What breaks:** an expression that depends on mutable global state when it is evaluated, e.g. a factory that captures a counter or a config value.
  - In a non-generic node, every instance now filters with the value from the first read.
  - In a generic node, each read filters with the value at that read.
  - That's a semantic change only for code written that way. It is documented (T4, §10) and pinned by tests (§9).

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

- **`init(wrappedValue:_:)` keeps its signature,** so `@Sync(.x) var f: T = v` compiles unchanged. The argument is accepted and not stored (T1, decided).
- **Manual constructions (checked):** `git grep -E 'Sync\(wrappedValue|Sync<[^>]+>\('` over `Sources`, `Tests`, `Examples` and `Tools` finds none outside the attribute.
  - Two state nodes conform by hand (`SyncLeafWritableTests.swift:86`, `NIOAdminRoutesReplayStartTests.swift:495`). Neither reads a policy.
- **`Sync.policy`:** replaced by an `unavailable` stub whose message says where the policy now lives (T2, decided). Code that reads it fails to compile with that message, and no code in the repository reads it.

**`@Sync` without `@StateNodeBuilder`:** today the wrapper alone already does nothing for sync. Only the macro's generated members read the policy. And a type has to conform to `StateNodeProtocol`, which requires `snapshot(for:dirtyFields:)` and the dirty methods. So a type with `@Sync` and no builder either:
- writes those by hand: then a hand-written read of `_x.policy` fails to compile, with T2's message;
- or doesn't read the policy at all: then nothing changes for it.

Neither a compile-time error nor a fallback is possible from the wrapper itself: it can't see whether the macro ran.

**Recommendation: no fallback.** A runtime fallback would need the policy stored again, which is what this removes.

**A `Sync` inside a plain (non-node) struct:**
- `SnapshotValue.make` reflects every child of a plain struct (`SnapshotValue.swift:431-440`, checked).
- Such a wrapper today would reach its `policy` child, and after this change it would serialize `_wrappedValue` and `_isDirty`.
- No such holder exists, and `@Sync` outside a builder does nothing for sync, so this is named here and not changed.
- Refusing it at registration (`SyncValueSemantics`) would be a behavior change of its own, left as a follow-up if wanted.

The unavailable `policy` stub (T2) is a computed property, and `Mirror` lists only stored ones, so it doesn't add a child.

**Uses in the repository (checked):** none in `Sources`, `Tests`, `Examples` or `Tools`. Every `@Sync` outside a builder type is one of:
- an expected expansion in a macro test (the attribute is gone after expansion);
- or a doc example, `Sources/SwiftStateTreeDeterministicMath/Docs/DeterminismRules.md:46/53/225/232`, which omits the attribute for brevity. It gets `@StateNodeBuilder` added in the same PR.

## 6. Layout before and after

**Before:** measured on #519's branch (Swift 6.4.2, macOS, checked).

**After:** inferred by Swift's struct layout rule, where each field sits at the next offset aligned for it. A second, independent computation gave the same offsets.
- `Sync<Int>` would be size 9 and alignment 8.
- `Sync<Position2>` would be size 9 and alignment 4.
- `Sync<Angle>` and `Sync<Float>` would be size 5 and alignment 4.

| Type | Before: size / stride / `_isPOD` | After (inferred): size / stride / `_isPOD` | Note |
|---|---|---|---|
| `MonsterState` (8 fields, values 56 B) | 281 / 288 / false | 89 / 96 / true | |
| `PlayerState` (8 fields) | — / 296 / false | 105 / 112 / true | |
| `TurretState` (6 fields) | — / 232 / false | 81 / 88 / false | `PlayerID.rawValue` is a `String`, so the type stays non-POD; its copies retain one reference instead of six policies |

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
   - macro expansion tests for:
     - a non-generic node;
     - a generic node;
     - a node nested in a generic type, in an extension, and in a function (each taking the computed branch);
     - a closure policy;
     - a global policy (`@Sync(nestingUnknownIntPolicy)`);
     each asserting the emitted `_syncPolicy_` static and the readers;
   - the compile fixtures of §3 and §4;
   - the reader × policy matrix (§9);
   - the two evaluation pins (§9).
2. **The macro:**
   - emit the statics;
   - switch the four readers (§2);
   - update the expected expansions in the macro tests.
3. **`Sync`:**
   - drop the stored `policy`;
   - the init ignores the argument (T1);
   - the `policy` stub (T2);
   - doc comment on evaluation timing (T4), and `docs/core/sync.md` with its zh-TW companion;
   - the `SyncEngine.swift` reflection comment.
4. **The doc example** in `DeterminismRules.md`.
5. **Solutions:** an entry if a reusable lesson comes out (e.g. that a per-instance closure-holding wrapper makes every node type non-POD).

## 9. Verification

- `swift build`, and the touched suites in debug and release:
  - `SwiftStateTreeMacrosTests`;
  - `SwiftStateTreeTests` and `SwiftStateTreeTransportTests`, with `IN_TURN_SYNC=true` and `=false`;
  - `GameContentTests` (it holds `HeroDefenseWireBytesTests` and `HeroDefenseStateHashPinTests`).
- **Evaluation pins:** each uses a fixture type that no other test reads, so no parallel test reads its static first, and a counter in synchronized storage (a lock-protected `final class`, since a mutable global is an error under Swift 6). The policy is a factory that captures the counter's value when it is evaluated: `let c = counter.value; return .masked { _ in c }`.
  - **Non-generic** (T4):
    1. Init A at c = 1.
    2. Init B at c = 2.
    3. Set c = 3.
    4. The first filtered read gives 3.
    5. Set c = 4.
    6. Later reads on A and on B still give 3.

    Nothing else is called on the type before the first read.
  - **Generic** (§3): the same sequence on a generic fixture. The first read gives 3, and after c = 4 the reads on A and B give 4: per read.
- **Reader × policy matrix**, written first and green on base and head:
  - One fixture node has a field for each of `.broadcast`, `.serverOnly`, `.perPlayer`, `.perPlayerSlice()`, `.masked`, `.custom`, and a global policy (classified `.unknown`).
  - It also has an optional field to cover hide vs null: a filter that returns nil hides the field, while a nil value is sent as null.
  - Each field is asserted through each reader: `snapshot(for:dirtyFields:)` (:328), the per-player split (:611), and the sync tables' `read` (:380), with sync tables on and off.
  - The sync check (:388) is compile-only: its body compiles for every field.
- **Mutants:**
  - The macro emits `.broadcast` for every static: the matrix fails.
  - The filter reads a per-instance policy instead of the static: the non-generic pin fails at step 4 or 6.
  - The predicate always takes `static let`: the compile fixtures of §3 fail to build.
  - `policy` is stored again: the POD pin fails.
- Full `swift test` and E2E on CI, all three encodings.
- **Bytes and frames:** EncodingBenchmark captures, base (main with #519) against head. Bytes and per-session digests must be identical for the four #519 cells (`cap100-local`, `cap100-router`, `cap500-idle`, `vis-tick`), with the committed `capture-digest.py`.
- **Schema:** each example's `SchemaGen` output (`Examples/Demo`, `Examples/GameDemo`) must be byte-identical base against head, with its sha256 recorded. Reevaluation records carry the schema's hash, so a change there would also show as a record mismatch.
- **Host A/B after #519's:**
  - base = main with #519, head = this PR, the same cells and procedure as #519's brief;
  - judged on time outside sync (timeMs − syncMs, tickMs), with `syncMs` reported;
  - plus `perf stat` instructions/cycles on `cap100-local`, if approved as for #519.
  - Expected: instructions and non-sync time fall where nodes are copied (the scans and the `guard var` copies). `syncMs` may fall too, because the encoders copy node values. The A/B reports that, but it isn't judged.

## 10. Trade-offs (decided 2026-11-12, within the maintainer's direction)

- **T1, the init's policy argument: keep `_ policy: SyncPolicy<Value>` and ignore it.**
  - The signature stays identical.
  - An init that initializes the field through the attribute still evaluates the expression. For every form in the repository that is an enum constant or a non-capturing closure, and it happens at init, not per copy.
  - Not taken: `@autoclosure`, which is source compatible but changes the init's type.
- **T2, `Sync.policy`: an unavailable stub.**
  ```swift
  @available(*, unavailable, message: "The policy is per declaration now; @StateNodeBuilder reads it from the @Sync attribute")
  public var policy: SyncPolicy<Value> { fatalError() }
  ```
  A hand-written read fails to compile with a message that says what to change. Not taken: removing it outright.
- **T3, element dirty flags: kept** (§7). 64 against 96 bytes for `MonsterState` isn't worth a semantic change to public API now.
- **T4, evaluation timing: accepted and documented.** The wording is "once per type for non-generic node types, per read for generic ones (and for node types nested in an extension or a function)". It goes in:
  - this plan (§4);
  - the DocC of `Sync`;
  - `docs/core/sync.md` § "What a Filter Sees", with `docs/core/sync.zh-TW.md` in the same commit.

  That docs section already asks a filter to be a pure function of its arguments. It gains the timing above and §4's contract: a policy expression must be pure and callable from any context.
