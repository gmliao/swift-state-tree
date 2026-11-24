# PlainData P4: land State is PlainData

**Status:** rev 1, plan only, no code. Slice P4 of `2026-11-22-plaindata-all-the-way.md` (rev 2, in PR #772), which sets the rule (§3.3, first row) and the maintainer's decisions Q1–Q6. This plan is how P4 does it. It builds on Code-1's P3/4-0 PR (the shared field walk, the Q2/Q3 diagnostics, `@PlainData` on the DeterministicMath types), which isn't up yet. §2 lists what P4 takes from it; anything that PR doesn't do moves into P4.

Code pointers are at #772's head 06ce5f99 (P1 + P2 on main 8a3f3e15). The compile probe in §3.2 ran on Swift 6.4.2 (macOS). P4 re-runs it on 6.2.4 before relying on it.

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
| P3/4-0 | the shared field walk: one field type in, its check lines out, or nil after a diagnostic (Q2 Foundation types, closures, tuples, existentials) | `@StateNodeBuilder`'s per-field diagnostics (§3.3) |
| P3/4-0 | the Q3 diagnostic for a nested type that isn't `PlainData` | the message for a nested user type in a state field (§3.4) |
| P3/4-0 | `@PlainData` on `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle` and the rest of DeterministicMath | Demo, GameDemo and tests keep these in state |

The plan assumes the walk can be called from `SwiftStateTreeMacros` (a target both macro targets depend on, or the same source in both). If P3/4-0 places it differently, only §3.3's call site changes.

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
- **`@PlainData` on the wrapper** checks the wrapper's own storage. If a later change put a reference back into it, the build fails. #520 removed exactly that kind of field: a policy enum with closures.

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
<access> static func _plainDataCheck() {
    PlainDataCheck.field(Sync<[PlayerID: PlayerState]>.self)   // @Sync var players: [PlayerID: PlayerState]
    PlainDataCheck.field(Internal<Int64>.self)                 // @Internal var lastTick: Int64
}
```

- **What it checks:** one line per stored property, on the storage type (`Sync<T>` or `Internal<T>`), not on `T` alone. That covers the wrapper and the value together.
- **Access:** the type's own (`public`, `package`, or none), as P1's witness. A `public` witness in an internal type's member fails to compile, the trap P1 hit.
- **Generic node:** nothing extra. The user writes `T: PlainData` and the compiler asks for it at the field (probe).
- **Diagnostics:** per field, the macro runs the shared walk on `T` before emitting. That gives Q2's named replacement for `Date`, `UUID`, `URL` and `Decimal`, and the closure and tuple messages, at the field. The compiler's own message (`requires that 'Date' conform to 'PlainData'`) still appears beside it.
- **#535's refusal stays** for synced fields: `Any`, `AnyObject`, `AnyHashable`, `AnyCodable`, `any P` and compositions, even when `P` refines `PlainData`. The sync has no wire form for an open type. In an `@Internal` field, `any P` already fails `Internal`'s constraint, since an existential doesn't conform to `PlainData`.
- **One `Decimal` message:** #597's `DecimalFieldTypeDiagnostic` (RefusedFieldTypes.swift) stops running for state fields. Q2's message covers every field now, `.serverOnly` and `@Internal` included. `@Payload`'s use of it is P3's.

**A gap the emission must close: `#if` members.** `collectStoredProperties` (StateNodeBuilderMacro.swift:160) reads only the struct's direct members. A stored property inside an `#if` block is skipped:
- by the marker check (`validateProperties`, :292);
- by the sync methods;
- and, unless P4 handles it, by `_plainDataCheck`. A class there would pass.

P4 does two things:
- `_plainDataCheck` reads `#if` clauses the way P1's `checkLines` does (every clause, each under its own condition);
- the marker check runs on `#if` members too, so an unmarked stored property there is refused as it is outside one.

Syncing a field declared inside `#if` is a separate question. P4 doesn't change it: it files an issue if the census finds such a field in use, and none is known.

### 3.4 Nested user types (Q3)

Every type stored under a `@Sync` or `@Internal` field must be `PlainData`. A nested `@StateNodeBuilder` node is `PlainData` through §3.1. Any other user type needs `@PlainData`. The compiler's error is at the field and names the type (probe); P3/4-0's Q3 diagnostic adds the attribute's name.

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

With §3.1–§3.4, the compiler rejects a class, closure, `Any` or `Decimal` anywhere under a synced or internal field. That includes behind a typealias, in a plain struct's own property, and in a hand-written `toSnapshotValue()` type: the stored type itself must be `PlainData`. The registration walks that looked for these find nothing.

| Item | Where | P4 |
|---|---|---|
| `SyncValueSemantics` (the Mirror walk of a default instance) | Sync/SyncValueSemantics.swift | delete |
| `SyncValueSemanticsError` (public) | same file | delete (source break) |
| `SyncRegistrationError.Problem.valueSemantics` (public) | Land/SyncRegistration.swift:14 | delete (source break) |
| `.existentialField` (public) and `TypeWalker`'s open-type branch, `isOpenType` | SyncRegistration.swift:30, :172 | delete. The key check in the same walker (`.unsupportedKey`) stays |
| `.decimalField` (public), the state half of `DecimalFields` | SyncRegistration.swift:35; DecimalFields.swift | delete the state half. `payloadPaths` stays for P3 |
| `SnapshotConvertibleStoredFields` | SyncRegistration.swift:77 | stays while `DecimalFields.payloadPaths` reads it (DecimalFields.swift:66); P3 decides |
| `.policyNesting`, `.unsupportedKey`, `.typeNameCollision` | SyncRegistration.swift | stay: not value semantics |
| `SnapshotValue.classRefusal` and the `.class` backstop | SnapshotValue.swift:193, :314, :490, :611 | stay. `SyncOutputVerifier.swift:300` and `SyncStreamCanonical.swift:12` still convert `event.payload.base` (an `AnyCodable`). The comments that call them a state backstop change to name the payload path, with a pointer to P3/P5 |
| `SnapshotValueConvertible`'s "a conformer promises value semantics" doc | SnapshotValue.swift:167 | says what checks it now: the field's type is `PlainData` |

Registration also stops building a default instance just for the value-semantics walk. The two remaining walks still use one.

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
- the emitted member for `@Sync` and `@Internal` fields;
- `public` / `package` / internal access;
- a generic node;
- an `#if` member;
- an unmarked stored property inside `#if`, refused;
- Q2's message on a `Date` field, one `Decimal` message;
- `@PlainData` on a hand-written node, with no conformance clause in the extension;
- with P4-Q1: `@SnapshotConvertible`'s `PlainData` extension, and none when `@PlainData` is also there.

**Must-not-compile** (scripts/must-not-compile/; `expect-error:` text in brackets):
- a `@Sync` class field [`conform to 'PlainData'`];
- a nested struct without `@PlainData` [`generic struct 'Sync' requires`];
- a nested struct holding `Any` (the closed existential gap);
- a generic node without `T: PlainData`;
- a hand-written `StateNodeProtocol` conformance without `_plainDataCheck` [`does not conform to protocol 'PlainData'`];
- a `.serverOnly` `Decimal`;
- an unmarked stored property under `#if`;
- controls that compile: a hand-written node with `@PlainData`, a generic node with the constraint, and a nested `@PlainData` struct.

**Unchanged output:**
- the differential harness (`DifferentialHarnessTests`) byte-compares against its goldens, with no `SST_UPDATE_GOLDEN` run and no golden file changed;
- E2E in the three encodings, and the reevaluation E2E with 0 mismatches;
- the schema and the generated TS client unchanged for Demo and GameDemo (`SchemaGen` output diffed).

**Mutants**, each caught by a named test:
- M1: `@StateNodeBuilder` skips one field's check. Caught by the class-field snippet once `Sync`'s constraint is also removed. So M1 runs with M3 applied, which shows the emitted check catches what the constraint would;
- M2: `_plainDataCheck` skips `#if` members. Caught by the `#if` snippet;
- M3: `Sync` loses its `PlainData` constraint. Caught by the nested-struct snippet's `expect-error` text: the error moves into the macro expansion and its wording changes;
- M4: `Sync` loses `@PlainData`. Caught by the build: every node's emitted check names `Sync<T>`, which then doesn't conform;
- M5: the marker check skips `#if` members. Caught by the unmarked-`#if` snippet.

## 6. Measurement

P4 is compile-time except one thing. `Sync`'s new constraint adds a witness-table argument wherever its accessors run unspecialized across modules. Its storage doesn't change: the value and a `Bool`.

The check: a Mac magnitude check of `EncodingBenchmark` (messagepack) and `ServerLoadTest`, base against head, release, alternating runs, same toolchain. A host A/B only if that is beyond noise. Registration gets cheaper by one default-instance walk; it isn't on a hot path, so it isn't measured.

## 7. Slices

| PR | Content | Gate |
|---|---|---|
| **P4-1** | §3.1–§3.5. `StateNodeProtocol: PlainData`; the wrappers; the emitted member, `#if` members included; nested types and generic nodes migrated in `Sources/` and `Tests/`; Examples in its own commit; docs for the compile-time rule | build, macro tests, must-not-compile, mutants M1–M5, full `swift test` (CI), differential harness, E2E three encodings + reevaluation, Mac magnitude check |
| **P4-2** | §3.6. The runtime retirements and their public API removals; tests of retired rows become snippets or go; docs for the registration rows | build, full `swift test` (CI), must-not-compile, E2E |

P4-1 first. P4-2 can be reviewed while P4-1 waits on CI, but merges after it.

**Order against P3:** both PRs touch the shared walk's call sites and `RefusedFieldTypes.swift` (P3 for `@Payload`'s `Decimal`). P4-1 starts after P3/4-0 merges. Then P3 and P4 can run in parallel with one rule: neither changes the walk's signature without telling the other.

## 8. Public API

All source breaks without deprecation, as the parent plan's §5:
- `StateNodeProtocol` refines `PlainData`. A state node needs `@StateNodeBuilder`, or `@PlainData` on a hand-written conformance;
- `Sync<Value: PlainData & Sendable>` (was `Sendable`). A state field's nested type needs `@PlainData` (Q3), a generic node needs `T: PlainData`;
- `Sync` and `Internal` conform to `PlainData` (additive);
- `@StateNodeBuilder` emits `_plainDataCheck`, and refuses an unmarked stored property inside `#if`;
- P4-2 removes `SyncValueSemanticsError` and `SyncRegistrationError.Problem.valueSemantics`, `.existentialField` and `.decimalField`;
- with P4-Q1: `@SnapshotConvertible` writes a `PlainData` conformance;
- with P4-Q2: `StateProtocol` refines `PlainData`;
- with P4-Q3: `ReactiveDictionary` and `ReactiveSet` are removed.

## 9. Questions for the maintainer

| Q | Question | Options | Recommended |
|---|---|---|---|
| P4-Q1 | Does `@SnapshotConvertible` make its type `PlainData`? | (a) yes, through the shared walk, as `@Payload` does in P3; (b) no: a state value type carries both `@SnapshotConvertible` and `@PlainData` | (a): one attribute per type, and the rule stays "the macro that shapes the type checks it" |
| P4-Q2 | `StateProtocol` | (a) refine `PlainData`; (b) leave it; (c) deprecate it (it adds only `Codable, Sendable`) | (a): the error then lands on the type's declaration |
| P4-Q3 | `ReactiveDictionary` / `ReactiveSet` | (a) delete; (b) drop `onChange` and make them `@PlainData` | (a): unused, and they predate the dirty tracking `Sync` does |
| P4-Q4 | Retirement timing | (a) P4-2 right after P4-1; (b) keep the runtime walk one release as a debug-only assertion | (a): the compile check covers every field the walk sees, and a check that can't fire only costs registration time |
