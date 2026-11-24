# PlainData P4: land State is PlainData

**Status:** rev 2, plan only, no code. Rev 1 was NOT GO from Review (2 must-fix, 3 should, 2 nit); rev 2 answers each (below). P4-Q1–Q3 decided by the maintainer as recommended (2026-11-24, §9); P4-Q4 is reopened. Slice P4 of `2026-11-22-plaindata-all-the-way.md` (rev 2, in PR #772), which sets the rule (§3.3, first row) and the maintainer's decisions Q1–Q6. This plan is how P4 does it. It builds on Code-1's P3/4-0 PR (the shared field walk, the Q2/Q3 diagnostics, `@PlainData` on the DeterministicMath types), which isn't up yet. §2 lists what P4 takes from it; anything that PR doesn't do moves into P4.

Code pointers are at #772's head 06ce5f99 (P1 + P2 on main 8a3f3e15). The compile probe in §3.2 ran on Swift 6.4.2 (macOS). P4 re-runs it on 6.2.4 before relying on it. P3/4-0's plan is `2026-11-24-plaindata-p34-0-shared-walk.md` on `feat/plaindata-p34-0-shared-walk` (2af72dd2).

**Rev 2** (Review on rev 1):
- **MF1, §2: name visibility.** The emitted `PlainDataCheck.field(…)`, the inherited `PlainData` requirement and a hand-written `@PlainData` all name SwiftStateTurns' declarations from a user file that imports only SwiftStateTree. P4 takes that as an input (§2): a re-export of SwiftStateTurns from SwiftStateTree (a) or narrow typealiases (b), with the maintainer (Review recommends (a)).
- **MF2, §3.6: the boundary of the compile check.** It holds in this repository, where the lint refuses a hand-written `_plainDataCheck`. Outside, `extension MyClass: PlainData { static func _plainDataCheck() {} }` compiles and no lint runs. §3.6 states that, and P4-Q4 (retirement) is reopened with the maintainer with three options (§9).
- **Should, §3.3: an `@Internal` field without a type annotation.** Nothing is emitted for it. `Internal`'s own constraint checks the inferred type, and a snippet pins that.
- **Should, §3.3: access.** The member is emitted as `public static func _plainDataCheck()` in every type. A `public` member compiles in an internal type; rev 1's trap claim was wrong, since P1's trap was the extension form.
- **Should, §3.3: `@StateNodeBuilder` with `@PlainData` on one type** would write two witnesses. `@StateNodeBuilder` refuses it with a pinned diagnostic, and a macro test covers it.
- **Nits:** §2 names `PlainDataMacroSupport`. §5 says which message each snippet's `expect-error` pins after P3/4-0's unavailable overload.
- **Also (from reading P3/4-0's plan):** the emitted line checks the field's value type with its name, `field((T).self, "name")`, not `field(Sync<T>.self)`. Then P3/4-0's Q3 message names the field. With `Sync<T>` the wrapper's constraint fails first and that message never shows. The wrapper's own storage is checked by `@PlainData` on the wrapper, pinned by a compile test (§3.2, M4).

## 1. Goal and scope

Every land `State` is `PlainData`, and the compiler checks it. After P4, #700 K1's `KeeperModel` can hold `State` with no exception, and the runtime value-semantics check from #464 retires because the compiler covers the same fields.

In scope:
- `StateNodeProtocol` refines `PlainData`, and `@StateNodeBuilder` emits `_plainDataCheck`;
- `@Sync` and `@Internal` become `@PlainData`; `Sync`'s value must be `PlainData`;
- the library's own types that sit in state;
- #464's runtime check and the registration rows the compile check makes unreachable retire;
- the tests, Examples and docs that depend on any of these.

Not in scope:
- payloads, server inputs and resolver outputs (P3);
- the keeper's queued items and the recorded raw bytes (P5, which merges into #700 K1);
- `SnapshotValue`'s runtime class refusal. It still guards event payloads converted from `AnyCodable` (§3.6), so it stays until P3/P5 type those.

## 2. What P4 takes from the base

| From | What | P4 uses it for |
|---|---|---|
| #772 (P1) | `PlainData` with its requirement `_plainDataCheck`; `PlainDataCheck.field`; the witness takes the type's access level | the conformance `StateNodeProtocol` inherits, and the emitted member's access |
| #772 (P2) | `Internal<Value: PlainData & Sendable>` | `@Internal` is already checked; P4 makes `Sync` match |
| P3/4-0 | the shared field walk in the new regular target `PlainDataMacroSupport`, which both macro targets depend on: one field type in, its check lines out, or nil after a diagnostic (Q2 Foundation types, closures, tuples, existentials). It also holds the member walk with `#if` clauses, and the refusal classifier that replaces `RefusedFieldTypes.swift` | `@StateNodeBuilder`'s per-field diagnostics and `#if` members (§3.3) |
| P3/4-0 | the Q3 diagnostic: `PlainDataCheck.field(_:_:)` with a field name, and an unavailable unconstrained overload whose message is the error for a type that isn't `PlainData` | the message for a nested user type in a state field, naming the field (§3.3, §3.4) |
| maintainer, with P3/4-0 (Review MF1 on P3/4-0) | **name visibility**: a user file that imports only SwiftStateTree must see `PlainData`, `PlainDataCheck` and the `@PlainData` macro. (a) SwiftStateTree re-exports SwiftStateTurns; (b) SwiftStateTree declares narrow typealiases and re-declares the macro. Review recommends (a) | every expansion of `@StateNodeBuilder` and `@SnapshotConvertible` in a user module, `StateNodeProtocol`'s inherited requirement, and `@PlainData` on a user's nested type. Under (b) the emitted lines name the aliases, and §3.3's member uses whatever (b) declares. P4-1 doesn't start before this is decided |
| P3/4-0 | `@PlainData` on `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle` and the rest of DeterministicMath | Demo, GameDemo and tests keep these in state |

P3/4-0 keeps `@StateNodeBuilder`'s behavior and `diagnoseRefusedFieldTypes`' scope unchanged (an adapter over the classifier). P4 changes that adapter's scope (§3.3).

Also assumed: `AnyCodable` and `AnyHashable` stay non-`PlainData`. If P3 made `AnyCodable` `PlainData`, §3.6's retirement of the `existentialField` row wouldn't hold.

## 3. Design

### 3.1 `StateNodeProtocol` refines `PlainData`

`public protocol StateNodeProtocol: PlainData, Sendable, SchemaMetadataProvider` (StateNodeProtocol.swift:36). A state node then needs a `_plainDataCheck`:
- `@StateNodeBuilder` writes it (§3.3);
- a hand-written conformance writes it with `@PlainData`.

`@PlainData` works on a type that already conforms through `StateNodeProtocol`. The compiler passes it an empty `conformingTo`, so the macro emits the extension with the witness and without a conformance clause (PlainDataMacro.swift, `protocols.isEmpty`). A macro test pins that case.

The lint already allows a protocol to refine `PlainData` (P1). Nothing new is allowed by hand: a hand-written `_plainDataCheck` outside SwiftStateTurns is still refused.

### 3.2 The wrappers

| Wrapper | Today | After P4 |
|---|---|---|
| `Sync` (SyncPolicy.swift:146) | `Sync<Value: Sendable>`, stores the value and a dirty flag (#520 moved the policy out) | `Sync<Value: PlainData & Sendable>`, and `@PlainData` |
| `Internal` (SyncPolicy.swift:220) | `Internal<Value: PlainData & Sendable>` (P2) | `@PlainData` |

Each side does its own job:
- **The constraint** puts the error at the field. It names the nested type that isn't plain, and for a generic node it names the parameter.
- **`@PlainData` on the wrapper** checks the wrapper's own storage: the value and the dirty flag. If a later change put a reference back into it, the wrapper's own declaration fails to compile. #520 removed exactly that kind of field: a policy enum with closures. A compile test in SwiftStateTreeTests, `PlainDataCheck.field(Sync<Int>.self)` and the same for `Internal`, pins that the wrappers stay `PlainData` (M4).

**Probe** (`swiftc -typecheck -swift-version 6`, one file, Swift 6.4.2):

| Case | Result |
|---|---|
| `@Sync var cards: [String: Card]`, where `Card` isn't `PlainData` | error at the field: `generic struct 'Sync' requires that 'Card' conform to 'PlainData'`, with a note `requirement from conditional conformance of '[String : Card]'` |
| The same with a `PlainData` `Card`, and `field(Sync<[String: PlainCard]>.self)` in the node's check | compiles |
| `struct Box<T: Sendable>: StateNodeProtocol { @Sync var v: T }` | error at the field: `requires that 'T' conform to 'PlainData'` |
| `struct GoodBox<T: PlainData & Sendable>`, check `field(Sync<T>.self)` | compiles |

Nothing in `Sources/` is generic over `Sync<V>`: only the generated code names `Sync<T>`, always with a concrete `T` or the node's own parameter. So the constraint breaks no library code.

### 3.3 What `@StateNodeBuilder` emits

`@StateNodeBuilder` is a member macro with `names: arbitrary` (StateTreeBuilder.swift:33), so it can add the member without changing its declaration. It emits:

```swift
public static func _plainDataCheck() {
    PlainDataCheck.field(([PlayerID: PlayerState]).self, "players")   // @Sync var players: [PlayerID: PlayerState]
    PlainDataCheck.field((Int64).self, "lastTick")                    // @Internal var lastTick: Int64
}
```

- **What it checks:** one line per stored property with a type annotation, on the field's value type, with the field's name (P3/4-0's form). For a type that isn't `PlainData`, P3/4-0's unavailable overload is chosen and its message is the error, on the line that names the field. The wrapper's constraint gives a second error at the field itself (§3.2). The wrappers' own storage is `@PlainData` on the wrappers (§3.2), so it isn't repeated per field.
- **An `@Internal` field without a type annotation** (`@Internal var cache = [String: Int]()`): nothing is emitted for it. `Internal<Value: PlainData & Sendable>` checks the inferred type at the field, so `@Internal var cache = [String: Any]()` doesn't compile; a snippet pins it. A `@Sync` field already needs an annotation (`validateProperties`, StateNodeBuilderMacro.swift:292).
- **Access:** always `public static func`, as `@StateNodeBuilder` already emits its other members (`public func getSyncFields()`). A `public` member compiles in an internal or private type and is a valid witness for a public type. Rev 1 said it would fail in an internal type; that was P1's trap in the extension form, which this member isn't.
- **`@StateNodeBuilder` and `@PlainData` on one type:** two macros would each write `_plainDataCheck`, an invalid redeclaration. `@StateNodeBuilder` sees the sibling attribute and refuses with its own diagnostic: "`@StateNodeBuilder` writes the PlainData check; remove `@PlainData`". `@PlainData` (in SwiftStateTurnsMacros) stays unaware of SwiftStateTree. A macro test pins the diagnostic. A hand-written node without `@StateNodeBuilder` uses `@PlainData` alone (§3.1).
- **Generic node:** nothing extra. The user writes `T: PlainData` and the compiler asks for it at the field (probe).
- **Diagnostics:** per field, the macro runs the shared walk on `T` before emitting. That gives Q2's named replacement for `Date`, `UUID`, `URL` and `Decimal`, and the closure and tuple messages, at the field. The compiler's own message (`requires that 'Date' conform to 'PlainData'`) still appears beside it.
- **#535's refusal stays** for synced fields: `Any`, `AnyObject`, `AnyHashable`, `AnyCodable`, `any P` and compositions, even when `P` refines `PlainData`. The sync has no wire form for an open type. In an `@Internal` field, `any P` already fails `Internal`'s constraint, since an existential doesn't conform to `PlainData`.
- **One `Decimal` message:** the classifier's `Decimal` case (from #597, moved into `PlainDataMacroSupport` by P3/4-0) stops running for state fields through `diagnoseRefusedFieldTypes`. Q2's message from the shared walk covers every field now, `.serverOnly` and `@Internal` included. `@Payload`'s use of it is P3's.

**A gap the emission must close: `#if` members.** `collectStoredProperties` (StateNodeBuilderMacro.swift:160) reads only the struct's direct members. A stored property inside an `#if` block is skipped:
- by the marker check (`validateProperties`, :292);
- by the sync methods;
- and, unless P4 handles it, by `_plainDataCheck`. A class there would pass.

P4 does two things:
- `_plainDataCheck` reads `#if` clauses through the shared member walk (P3/4-0 moves P1's `checkLines` into `PlainDataMacroSupport`: every clause, each under its own condition);
- the marker check runs on `#if` members too, so an unmarked stored property there is refused as it is outside one.

Syncing a field declared inside `#if` is a separate question. P4 doesn't change it: it files an issue if the census finds such a field in use, and none is known.

### 3.4 Nested user types (Q3)

Every type stored under a `@Sync` or `@Internal` field must be `PlainData`. A nested `@StateNodeBuilder` node is `PlainData` through §3.1. Any other user type needs `@PlainData`. Two errors show: the wrapper's constraint at the field, naming the type (probe), and P3/4-0's Q3 message on the emitted line, naming the field and the fix (§3.3).

Two state-side protocols and a macro decide how much users must write:

| | Today | Recommendation |
|---|---|---|
| `@SnapshotConvertible` (StateTreeBuilder.swift:82) | an extension macro that writes the snapshot conformances | **P4-Q1:** it also writes the `PlainData` conformance and `_plainDataCheck` through the shared walk, as `@Payload` will in P3. It writes nothing if the type also carries `@PlainData`. A state value type then needs one attribute, not two |
| `StateProtocol` (StateProtocol.swift:16) | `Codable, Sendable`; used by GameDemo's `Card`, `PlayerHand`, `CardGamePlayerState`, `Viewer` and the benchmark types | **P4-Q2:** refine `PlainData`. A conformer without the macro then fails at its own declaration, not at a field in another file |

### 3.5 The library's types in state

| Type | Where | P4 |
|---|---|---|
| `PlayerID`, `ClientID`, `SessionID`, `LandID` | SwiftStateTree | `@PlainData`, unless P3/4-0 or P3 already did (payloads hold them too) |
| `SnapshotValue` | Sync/SnapshotValue.swift:8 (an enum of values, used as a field type in tests) | `@PlainData` |
| DeterministicMath types | P3/4-0 | none |
| `ReactiveDictionary`, `ReactiveSet` | State/; `@unchecked Sendable`, each stores an `onChange` closure | **P4-Q3:** delete both. Nothing outside their own tests uses them, and with a closure they can't be state. The other option is to drop `onChange` and make them `@PlainData` |
| `StateNode<ID>`, `StateTreeEngine` | StateTree/; never stored in a land's state | none in P4 (unused; a cleanup issue, if wanted) |

### 3.6 Retiring #464's runtime check

**In this repository,** with §3.1–§3.4, the compiler rejects a class, closure, `Any` or `Decimal` anywhere under a synced or internal field. That includes behind a typealias, in a plain struct's own property, and in a hand-written `toSnapshotValue()` type: the stored type itself must be `PlainData`. The registration walks that looked for these find nothing here.

**The boundary (Review MF2).** That holds because the lint refuses a hand-written `_plainDataCheck` (P1). The lint runs only on this repository. In a user's project, `extension MyClass: PlainData { static func _plainDataCheck() {} }` compiles, and a `@Sync var x: MyClass` then compiles too. The parent plan's §3.2 says the same for every `PlainData` conformance: outside the repository a hand-written witness is a visible, unchecked promise. So retiring the runtime walk removes the only check a user's hand-written conformance would still meet. Whether to retire it is P4-Q4, reopened (§9). The table below is the full retirement, option (a). Under (b) or (c), the rows marked † stay as §9 says.

| Item | Where | P4 |
|---|---|---|
| `SyncValueSemantics` (the Mirror walk of a default instance) † | Sync/SyncValueSemantics.swift | delete |
| `SyncValueSemanticsError` (public) † | same file | delete (source break) |
| `SyncRegistrationError.Problem.valueSemantics` (public) † | Land/SyncRegistration.swift:14 | delete (source break) |
| `.existentialField` (public) and `TypeWalker`'s open-type branch, `isOpenType` † | SyncRegistration.swift:30, :172 | delete. The key check in the same walker (`.unsupportedKey`) stays. The same boundary applies: a user's hand-written `PlainData` struct can hold `Any` |
| `.decimalField` (public), the state half of `DecimalFields` † | SyncRegistration.swift:35; DecimalFields.swift | delete the state half. `payloadPaths` stays for P3. The same boundary applies |
| `SnapshotConvertibleStoredFields` | SyncRegistration.swift:77 | stays while `DecimalFields.payloadPaths` reads it (DecimalFields.swift:66); P3 decides |
| `.policyNesting`, `.unsupportedKey`, `.typeNameCollision` | SyncRegistration.swift | stay: not value semantics |
| `SnapshotValue.classRefusal` and the `.class` backstop | SnapshotValue.swift:193, :314, :490, :611 | stay. `SyncOutputVerifier.swift:300` and `SyncStreamCanonical.swift:12` still convert `event.payload.base` (an `AnyCodable`). The comments that call them a state backstop change to name the payload path, with a pointer to P3/P5 |
| `SnapshotValueConvertible`'s "a conformer promises value semantics" doc | SnapshotValue.swift:167 | says what checks it now: the field's type is `PlainData` |

Under (a), registration also stops building a default instance just for the value-semantics walk. The two remaining walks still use one.

### 3.7 Docs

English and zh-TW together:
- `docs/core/sync.md` "What registration refuses": the rows that move to compile time, and the gap list that closes (typealias, plain struct's own `Any` property, hand-written conversion);
- `docs/core/failure-handling.md`: the `.valueSemantics` / `.existentialField` / `.decimalField` problems;
- `docs/macros/state-node-builder.md` and `docs/macros/README.md`: the emitted member, `@PlainData` on nested types, generic nodes;
- `docs/core/land-dsl.md` and `docs/core/reevaluation.md` where they cite #464;
- the DocC catalogs that describe `@Sync` or `StateNodeProtocol`.

## 4. Census (rough, from a grep at 06ce5f99; the PR gives exact counts)

| Area | What changes |
|---|---|
| `Sources/` | Benchmarks: `BenchmarkPlayerState`, `BenchmarkHandState`, `BenchmarkCard` (`@SnapshotConvertible`, `StateProtocol`). ReevaluationMonitor's state: built-in types only. §3.5's library types |
| `Examples/` (own commit) | GameDemo `Card`, `PlayerHand`, `CardGamePlayerState`, `Viewer`; Demo and GameDemo DeterministicMath fields (P3/4-0) |
| `Tests/`: nested types | about 74 user types stored under state fields (22 `@SnapshotConvertible`, 52 plain). With P4-Q1 = yes, only the 52 need `@PlainData` |
| `Tests/`: generic nodes | `PolicyPerReadNode`, `LeafGenericBox`, `TableGenericBox` gain `T: PlainData`; 2 macro-test sources (`SyncPolicyStaticExpansionTests`, `FullStateSnapshotExpansionTests`) are syntax only and need nothing |
| `Tests/`: hand-written nodes | `LeafMislabelled`, `LeafThrowing`, `LeafNormalizing`, `LeafNoLayout` (SyncLeafWritableTests), `DummyReplayState` (NIOAdminRoutesReplayStartTests) gain `@PlainData` |
| `Tests/`: #464's own fixtures | 9 class types in state (`SyncValueSemanticsTests`, `SyncRegistrationTests`, `NestedNodePolicyTests`, `SyncTableDiffTests`, `SyncTableFallbackFieldsTests`, `LandTypeRegistryTests`, `NIOLandHostTests`). Their runtime cases become must-not-compile snippets or go |
| `Tests/`: existential and `Decimal` gaps | `ExistentialGapTests` (Transport), `SyncRegistrationTests`' plain-`Any` and untyped-loadout rows, `DecimalRegistrationTests`' state rows, `RefusedFieldTypeDiagnosticTests` :148–178. The same: snippets or removal, with the macro diagnostics re-pinned |
| Macro goldens | every `@StateNodeBuilder` expansion golden gains the `_plainDataCheck` member and nothing else; the PR shows the golden diff is additions only |

## 5. Tests and mutants

**Macro tests** (SwiftStateTreeMacrosTests):
- the emitted member for `@Sync` and `@Internal` fields, with field names, and nothing for an unannotated `@Internal`;
- `public` on the member in a public, a package and an internal type;
- `@StateNodeBuilder` with `@PlainData` on one type: the diagnostic;
- a generic node;
- an `#if` member;
- an unmarked stored property inside `#if`, refused;
- Q2's message on a `Date` field, one `Decimal` message;
- `@PlainData` on a hand-written node, with no conformance clause in the extension;
- with P4-Q1: `@SnapshotConvertible`'s `PlainData` extension, and none when `@PlainData` is also there.

**Must-not-compile** (scripts/must-not-compile/). Each pins one `expect-error` text, written after P3/4-0's unavailable overload exists. "Q3 message" is P3/4-0's text ("this field's type isn't PlainData: add @PlainData …"), which P4 takes as P3/4-0 merges it.

| Snippet | `expect-error` pins | Which check it proves |
|---|---|---|
| a `@Sync` class field | the Q3 message | the emitted line (M1) |
| a nested struct without `@PlainData`, in `[String: T]` | the Q3 message | the emitted line, through a collection |
| the same nested struct, a second snippet | `generic struct 'Sync' requires` | the wrapper's constraint (M3) |
| a nested struct holding `Any` | `@PlainData`'s existential refusal on the nested type | the existential gap closes |
| a generic node without `T: PlainData` | `generic struct 'Sync' requires that 'T'` | the constraint on a generic node |
| a hand-written `StateNodeProtocol` conformance without `_plainDataCheck` | `does not conform to protocol 'PlainData'` | §3.1 |
| a `.serverOnly` `Decimal` | Q2's `Decimal` message | one `Decimal` message, every policy |
| an unannotated `@Internal var cache = [String: Any]()` | `generic struct 'Internal' requires` | the inferred type, with nothing emitted |
| an unmarked stored property under `#if` | `@StateNodeBuilder`'s marker diagnostic | the marker check reads `#if` (M5) |
| a `@Sync` class field inside `#if` | the Q3 message | `_plainDataCheck` reads `#if` (M2) |
| `@StateNodeBuilder` with `@PlainData` on one type | the new diagnostic's text | §3.3 |

Controls that compile: a hand-written node with `@PlainData`, a generic node with the constraint, a nested `@PlainData` struct, and an unannotated `@Internal var count = 0`.

**Unchanged output:**
- the differential harness (`DifferentialHarnessTests`) byte-compares against its goldens, with no `SST_UPDATE_GOLDEN` run and no golden file changed;
- E2E in the three encodings, and the reevaluation E2E with 0 mismatches;
- the schema and the generated TS client unchanged for Demo and GameDemo (`SchemaGen` output diffed).

**Mutants**, each caught by a named test:
- M1: `@StateNodeBuilder` skips one field's check. Caught by the class-field snippet: the constraint's error is still there, but the Q3 message it pins isn't;
- M2: `_plainDataCheck` skips `#if` members. Caught by the `#if` class-field snippet;
- M3: `Sync` loses its `PlainData` constraint. Caught by the second nested-struct snippet, whose `generic struct 'Sync' requires` text is gone;
- M4: `Sync` loses `@PlainData`. Caught by the wrappers' compile test (§3.2);
- M5: the marker check skips `#if` members. Caught by the unmarked-`#if` snippet;
- M6: `@StateNodeBuilder` drops the `@PlainData` sibling check. Caught by its macro test (and the snippet then fails on a redeclaration, not the pinned text).

## 6. Measurement

P4 is compile-time except one thing. `Sync`'s new constraint adds a witness-table argument wherever its accessors run unspecialized across modules. Its storage doesn't change: the value and a `Bool`.

The check: a Mac magnitude check of `EncodingBenchmark` (messagepack) and `ServerLoadTest`, base against head, release, alternating runs, same toolchain. A host A/B only if that is beyond noise. Registration gets cheaper by one default-instance walk; it isn't on a hot path, so it isn't measured.

## 7. Slices

| PR | Content | Gate |
|---|---|---|
| **P4-1** | §3.1–§3.5. `StateNodeProtocol: PlainData`; the wrappers; the emitted member, `#if` members included; the sibling refusal; nested types and generic nodes migrated in `Sources/` and `Tests/`; Examples in its own commit; docs for the compile-time rule and its boundary (§3.6) | build, macro tests, must-not-compile, mutants M1–M6, full `swift test` (CI), differential harness, E2E three encodings + reevaluation, Mac magnitude check |
| **P4-2** | §3.6, as P4-Q4 decides. Under (a): the runtime retirements and their public API removals; tests of retired rows become snippets or go; docs for the registration rows. Under (b): the walk runs in debug builds only. Under (c): nothing until the stronger seal exists | build, full `swift test` (CI), must-not-compile, E2E |

P4-1 first; it doesn't depend on P4-Q4. P4-2 can be reviewed while P4-1 waits on CI, but merges after it.

**Order against P3:** both PRs touch the shared walk's call sites and the classifier adapter (`diagnoseRefusedFieldTypes`; P3 for `@Payload`'s `Decimal`). P4-1 starts after P3/4-0 merges and the name-visibility decision (§2) is made. Then P3 and P4 can run in parallel with one rule: neither changes the walk's signature without telling the other.

## 8. Public API

All source breaks without deprecation, as the parent plan's §5:
- `StateNodeProtocol` refines `PlainData`. A state node needs `@StateNodeBuilder`, or `@PlainData` on a hand-written conformance;
- `Sync<Value: PlainData & Sendable>` (was `Sendable`). A state field's nested type needs `@PlainData` (Q3), a generic node needs `T: PlainData`;
- `Sync` and `Internal` conform to `PlainData` (additive);
- `@StateNodeBuilder` emits `_plainDataCheck`, and refuses an unmarked stored property inside `#if`;
- `@StateNodeBuilder` refuses `@PlainData` on the same type;
- under P4-Q4 (a), P4-2 removes `SyncValueSemanticsError` and `SyncRegistrationError.Problem.valueSemantics`, `.existentialField` and `.decimalField`. Under (b) they stay, reported in debug builds only. Under (c) they stay;
- whatever the name-visibility decision adds (§2): a re-export of SwiftStateTurns from SwiftStateTree, or typealiases;
- with P4-Q1: `@SnapshotConvertible` writes a `PlainData` conformance;
- with P4-Q2: `StateProtocol` refines `PlainData`;
- with P4-Q3: `ReactiveDictionary` and `ReactiveSet` are removed.

## 9. Questions for the maintainer

| Q | Question | Options | Recommended |
|---|---|---|---|
| P4-Q1 | Does `@SnapshotConvertible` make its type `PlainData`? | (a) yes, through the shared walk, as `@Payload` does in P3; (b) no: a state value type carries both `@SnapshotConvertible` and `@PlainData` | (a): one attribute per type, and the rule stays "the macro that shapes the type checks it" |
| P4-Q2 | `StateProtocol` | (a) refine `PlainData`; (b) leave it; (c) deprecate it (it adds only `Codable, Sendable`) | (a): the error then lands on the type's declaration |
| P4-Q3 | `ReactiveDictionary` / `ReactiveSet` | (a) delete; (b) drop `onChange` and make them `@PlainData` | (a): unused, and they predate the dirty tracking `Sync` does |
| P4-Q4 (reopened) | Retire #464's runtime walk, given the boundary in §3.6? | (a) delete it anyway, as rev 1 planned: the compile check covers the repository, and a user's hand-written `_plainDataCheck` is their stated promise; (b) keep the Mirror walk, run only in debug builds, and report what it finds there; (c) keep it as today until a stronger seal than the lint exists (one a user's build enforces) | (b), Main's recommendation: debug builds still catch a user's wrong promise, and release registration stops paying for a walk that can't fire in this repository |

### Decisions (maintainer, 2026-11-24)

| Q | Decision |
|---|---|
| P4-Q1 | **(a)** `@SnapshotConvertible` also writes the `PlainData` conformance and `_plainDataCheck`, and nothing when the type carries `@PlainData` too |
| P4-Q2 | **(a)** `StateProtocol` refines `PlainData` |
| P4-Q3 | **(a)** delete `ReactiveDictionary` and `ReactiveSet` |
| P4-Q4 | ~~(a) P4-2 lands right after P4-1~~ **reopened** (Review MF2 on rev 1): the options are now (a) delete anyway, (b) debug-only, (c) keep until a stronger seal |
