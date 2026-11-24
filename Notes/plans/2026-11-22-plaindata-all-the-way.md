# PlainData all the way: no world in the turn core

**Status:** rev 2: the maintainer decided Q1–Q6 (2026-11-22, §6 Decisions). P1 and P2 are implemented in #772 (based on `main`); Review checks this plan and that code together. P3–P5 are not started. Rev 1 was plan only, with no code. The maintainer's direction (2026-11-22): settle the `PlainData` question before #700 K1, and keep the turn core free of a world. #758 (a step-lent world) is on hold, and this plan doesn't design it.

Code pointers are at main 2ef1c328.

## 1. Goal

`TurnCore` holds a machine `M: PlainData`: values only, no references and no existentials. #700 (`2026-11-22-keeper-on-turncore.md` §3.1) found that `LandKeeper`'s turns write data that isn't `PlainData` today, and #758 proposed a second, non-plain value the core lends to steps. This plan makes that data `PlainData` instead, so that #700's model (`KeeperModel`) holds all of the keeper's state and no world is needed. Where something can't be `PlainData`, it stays out of the core's state, and each such item is a question for the maintainer (§6).

## 2. What the compiler can check (probes)

The compile probes ran `swiftc -typecheck -swift-version 6`. Each is one file with a minimal `PlainData`, `PlainDataCheck` and a payload protocol. The first six rows were checked on Swift 6.2.4 (Linux x86_64, the pinned CI toolchain) and on 6.4.2 (macOS), with the same results; the last three rows on 6.4.2 only, so P0 re-runs them on 6.2.4.

| Question | Result |
|---|---|
| `PlainDataCheck.field((any ActionPayload).self)`, with `ActionPayload: PlainData` | refused: an existential doesn't conform to its protocol |
| A closure check, `existential<E>(_: E.Type, _ upcast: (E) -> any PlainData)`, with `E = any ActionPayload` | compiles: `any ActionPayload` converts to `any PlainData` only because the protocol refines it |
| The same check with a protocol that doesn't refine `PlainData` | refused, as it should be |
| A closed per-land enum of action structs | compiles |
| A class, and a struct holding a class, conforming to `ActionPayload` | **compiles: the hole**. A refining protocol lets a type become `PlainData` without `@PlainData`'s field checks |
| `field([any ActionPayload].self)` | refused: the macro must emit the element's closure check |
| `PlainData` with a requirement, `static func _plainDataCheck()`; a class or a struct holding a class conforming to `ActionPayload` without writing it | **refused** (`does not conform to protocol 'PlainData'`): the hole closes |
| The closure check against that `PlainData`, for `any ActionPayload` | compiles |
| The closure check for `Optional<any ActionPayload>` as a whole | refused: for `(any P)?`, `[any P]` and `[K: any P]` the macro checks the wrapped element, not the wrapper |
| Hand-written conformances of a dictionary of structs with arrays, a struct recursive through `[Node]`, and an `indirect enum` | compile |

## 3. Design

### 3.1 Existential fields (Cover 1)

`@PlainData` accepts a field of type `any P` when `P` refines `PlainData`, and emits `SwiftStateTurns.PlainDataCheck.existential { (value: any P) in value }` for it (#772's form; rev 1 showed a metatype argument, which doesn't parse for `any (P & Q)`). A wrapper spelled out (`Array<any P>`, bare or `Swift.`-qualified) also gets a pinned check, `PlainDataCheck.array((Array<any P>).self) { (_: any P) in }`, which compiles only for the standard library's type with the spelled element. For the nested forms it checks the element:
- `[any P]`, `ContiguousArray<any P>`, `Set` can't hold an existential (not `Hashable`), so it doesn't arise;
- `(any P)?`;
- `[K: any P]`: `K` with `field`, the value with `existential`;
- any nesting of those (`[[any P]?]`), by unwrapping each layer in the macro's type walk.

A protocol that doesn't refine `PlainData` is refused with the field's name, as a class field is today. The macro needs the field's written type, which `@PlainData` already requires (every stored property has a type annotation).

**What changes in the macro.** Today `@PlainData` refuses every `any` and `some` type syntactically, wherever it appears in a field's type (`RefusedTypeVisitor`, PlainDataMacro.swift:160, diagnostic `.existential`), and emits one `field(T.self)` per field. P1 changes that:
- `any P` (and a composition `any P & Q`) is accepted; the compiler decides whether it converts to `any PlainData`;
- `some P`, an existential metatype (`any P.Type`) and a function type stay refused;
- a field whose type holds `any P` inside `Optional`, `Array`, `ContiguousArray` or a `Dictionary` value emits the element's `existential` check and no `field` check for the wrapper, which can't conform (probe above);
- `any P` inside any other generic type (`Foo<any P>`) is refused, because the macro can't see what `Foo` does with it.

**Indirect enums.** The macro has no special case for `indirect` (read from PlainDataMacro.swift, not yet compiled through the macro): an `indirect enum` or `indirect case` takes the enum path, and a recursive case emits `field(Tree.self)` inside `Tree`'s own conformance extension, which the hand-written probe shows compiles. An indirect payload lives in an immutable heap box with value semantics, so it is plain data. P1 adds a macro test for an `indirect enum` and an `indirect case`, so this is pinned rather than read.

### 3.2 Closing the hole (Cover 2)

A protocol that refines `PlainData` lets any type become `PlainData`, a class included, without field checks. Today's lint (`scripts/lint-turns.sh`, rule `plain-data`) refuses every protocol refining `PlainData` outside `SwiftStateTurns` for that reason, and only sees the literal word `PlainData`.

The fix moves the check into the protocol:
- **`PlainData` gains a requirement, `static func _plainDataCheck()`, with no default.** `@PlainData` already emits a member of that name (`names: named(_plainDataCheck)`) holding the field checks. A type that conforms to a refining protocol without the macro doesn't compile (probe above), so the hole needs a hand-written `_plainDataCheck`, which is visible.
- **The built-in conformances** (`Int` … `Data`, `Optional`, `Array`, `Dictionary`, `Result`, the core's ids; `PlainData.swift:24–54`) each get an empty implementation, in `SwiftStateTurns`.
- **The lint changes:**
  - a protocol refining `PlainData` becomes allowed: the requirement makes it safe;
  - new: a hand-written `_plainDataCheck` outside `SwiftStateTurns`, or a `PlainData` extension that gives it a default, is refused;
  - kept: a typealias for `PlainData`.
- **`@Payload` and `@StateNodeBuilder` emit `_plainDataCheck`** with the same field checks as `@PlainData`. A conformance of a payload or state type then needs its macro, or a visible hand-written check.

Outside this repository the lint doesn't run. There, a hand-written `_plainDataCheck` is the only way past the compiler, and the docs say what it gives up.

### 3.3 What becomes PlainData (Cover 3)

| Item | Today | Replacement | Public break |
|---|---|---|---|
| Land `State` | `StateNodeProtocol: Sendable` (StateNodeProtocol.swift:36); synced fields checked at runtime by `SyncValueSemantics.validate` (#464); `@Internal` unchecked (#767) | `StateNodeProtocol` refines `PlainData`; `@StateNodeBuilder` emits the field checks. `@Sync` (value plus dirty, #520) and SwiftStateTree's state containers get `@PlainData`. `@Internal` requires `PlainData` (#767). #464's runtime check stays until the compile check covers the same fields, then goes | A `State` with a class, closure or `Any` field stops compiling. A nested user struct in `State` needs `@PlainData` (Q3) |
| Action, client-event and server-event payloads | `ActionPayload`, `ClientEventPayload`, `ServerEventPayload`: `Codable, Sendable` | Each refines `PlainData`; `@Payload` emits the checks | The same as `State`: payloads with reference or `Any` fields stop compiling; a hand-conformed payload without `@Payload` needs it |
| Server inputs | `ServerInputPayload`; queued as `PendingServerInputItem.payload: AnyCodable` (LandKeeper.swift:138) | `ServerInputPayload` refines `PlainData`; the item holds `any ServerInputPayload` | the same rule for server-input types |
| Resolver outputs | `ResolverOutput: Codable & Sendable`; held as `[String: any ResolverOutput]` (LandKeeper.swift:168, LandContext.swift:159) | `ResolverOutput` refines `PlainData`; the dictionary's value check is emitted (§3.1) | each resolver output type needs `@PlainData` |
| Entry facts | `PlayerSession`: strings, a bool and `[String: String]` (JoinTypes.swift:22–31); the keeper keeps `services` beside it | `@PlainData` on the session; `services` stays out (§3.4) | none: already plain fields |
| The action's decoded payload and type | `decoded: (any ActionPayload)?`, `actionType: any ActionPayload.Type` (LandKeeper.swift:200–204) | `decoded` passes as an existential (§3.1). A metatype isn't `PlainData`: the item keeps the type's wire name (`_payloadWireName`), and the step looks the type up in the land definition (§3.4) | `PendingActionItem.actionType` (public) becomes a name, or stays as a computed lookup |
| The recorded raw payload | `source: any PayloadDecodingSource`; `AnyCodablePayloadSource`, `RecordPayloadSource` hold `AnyCodable` (`base: Any`, AnyCodable.swift:5) | The wire bytes as `Data` (already `PlainData`) with an encoding tag. The typed `decoded` value is what the step runs; the bytes are what the record writes. Q4 | `PendingActionItem.action: AnyCodable` (public) becomes a decode on demand, outside the core's state |
| Server events staged for `emit` | the `OutputCollector` class (#700 §3.1) | the staged buffer holds `any ServerEventPayload` (now `PlainData`) and the sequence counter, in the model | none |
| An action's result | `.completed(AnyCodable)` (LandKeeper.swift:87) | the encoded response bytes, or a response protocol that refines `PlainData` (K1's census decides by use) | depends on K1's census |
| `LandFailure` | a struct of an enum, strings and a position (LandFailure.swift:9) | `@PlainData` | none |

Foundation value types that users put in `State` and payloads (`Date`, `UUID`, `Decimal`, `URL`) aren't `PlainData`, and stay that way (Q2): `@PlainData` refuses them with a diagnostic that names what to store instead.

### 3.4 What stays out of the core's state (Cover 4)

No item above needs a world. What remains is not data the turn writes:

| Item | Why it isn't `PlainData` | Where it lives without a world |
|---|---|---|
| **The land definition and config:** handler closures, resolver lists, `LandConfig` | closures | **Q1.** A step must call the handlers, so the machine has to reach them. Options in §6 |
| `services`, including the RNG | references (`DeterministicRngService` is a locked class) | passed to effects explicitly; handlers reach them through the context built in the step from the definition (Q1). The RNG's state moves into the model as plain data (#700 Q7), which this plan makes natural |
| The port | an actor reference | in inputs and effects as a binding token, as #700's fit read split it. Inputs and effects are `Sendable`, not `PlainData`. The actor keeps the attached port, written only from `flush` |
| The recorder | a sink | record drafts are outputs; `flush` hands them on (#700 §3.1) |
| Waiters, effect tasks | the core's own | unchanged |

So, with Q1 answered, `KeeperModel` holds every value the keeper's turns change, and #758 can close as not needed. If Q1 picks an option the core doesn't have yet (§6, option D), that is a narrower core issue than #758: an immutable value fixed at init, not a world that steps mutate.

## 4. Slices and order (Cover 5)

| Slice | Content | Order |
|---|---|---|
| **P0** | The probes re-run on 6.2.4 (in progress) and again at the 6.4.3 bump. Any difference is recorded here | now; again at the bump |
| **P1** (SwiftStateTurns) | `_plainDataCheck` as a requirement; built-ins implement it; `@PlainData` emits the existential and nested checks (§3.1); the lint change (§3.2); the Foundation refusals with their replacements (Q2) | first. Independent of the toolchain bump (the macro's swift-syntax range is unchanged); either order |
| **P2** = #767 | `@Internal` requires `PlainData` | with or right after P1 |
| **P3** (SwiftStateTree) | The payload and resolver protocols refine `PlainData`; `@Payload` emits `_plainDataCheck`; server inputs typed | after P1 |
| **P4** (SwiftStateTree) | `StateNodeProtocol` refines `PlainData`; `@StateNodeBuilder` emits the checks; containers and `@Sync` get `@PlainData`; #464's runtime check retired where the compile check covers it | after P1, with or after P3 |
| **P5** (keeper storage) | The metatype becomes a name, the raw payload becomes bytes, the action result's form, `LandFailure` and the session as `@PlainData` | merged into #700 K1: K1's census places each field, and with P1–P4 every field has a `PlainData` home |
| #700 K2 | Unblocked by Q1 instead of #758 | after K1 |

Tests and mutants, per slice (holds and events, never timing; must-not-compile snippets where a refusal is the point):
- **P1:**
  - must-not-compile: a class conforming to a refining protocol; a struct holding a class doing the same; a field `any NotPlain`; `[any NotPlain]`, `(any NotPlain)?`, `[String: any NotPlain]`;
  - compiles: each nested form with a refining protocol;
  - lint fixtures: a hand-written `_plainDataCheck`, a defaulting extension, a typealias;
  - mutants: the macro skips the element check; the macro emits no `_plainDataCheck`; the lint misses a hand-written one.
- **P2:** #767's tests (the macro tests pinning "may hold anything" flip), plus `Decimal` per Q2.
- **P3:**
  - must-not-compile: a payload, server input or resolver output with a class field; a payload conformed without `@Payload`;
  - E2E in three encodings and the record/replay E2E (0 mismatch): wire bytes unchanged.
- **P4:**
  - must-not-compile: a `State` with a class field, an `@Internal` class, a nested struct without `@PlainData` (Q3);
  - the differential harness byte-compared;
  - mutant: `@StateNodeBuilder` skips a field.
- **P5:** K1's census test (every stored field has a home), with no "world" home left.

A/B: P1–P4 are compile-time only, so no host A/B. P3 and P4 get a Mac output check of `EncodingBenchmark` in case codegen moves. P5 follows K1's tier.

## 5. Public API

Every break here is a source break with no deprecation step, as for #593, because there are no external users:
- `PlainData` gains a requirement. Hand-written conformances outside the core are already refused by the lint.
- `StateNodeProtocol`, `ActionPayload`, `ClientEventPayload`, `ServerEventPayload`, `ServerInputPayload` and `ResolverOutput` refine `PlainData`.
- `Internal`'s constraint (#767).
- `PendingActionItem.action` and `actionType` (P5's census).

Each slice's PR lists its own.

## 6. Questions for the maintainer

| Q | Question | Options | Recommended |
|---|---|---|---|
| Q1 | How a step reaches the land definition (handler closures, resolvers, config) without a world | **A.** Carry it in each input: the facade attaches it. But core-dispatched steps have no adopter input (`handleFollowUp`, `handleAbandoned`, `handleLateResult`), so they couldn't reach it. **B.** A static per-type registry: two land types can share a `State` type, and it is global mutable state. **C.** The model holds a definition id, and the step looks it up in a process-wide table that is immutable after registration: no core change, a lookup per step, and a global. **D.** A core feature: an immutable `Sendable` value fixed at `TurnCore.init`, readable by every step and never writable. Not a world: nothing is lent and taken back, and nothing in it is turn state | **D.** It is the smallest core addition that covers every step kind, and it carries no mutable state. It needs its own core issue (#758 stays on hold). If the maintainer rejects any core addition, C |
| Q2 | Foundation value types in `State` and payloads: `Date`, `UUID`, `Decimal`, `URL` | conform them to `PlainData` in `SwiftStateTurns` (it already imports Foundation); or refuse them and ask for plain replacements (an `Int64` instant, a string id) | conform all four: they are immutable values, and users already use them in payloads |
| Q3 | Nested user types inside `State` and payloads | require `@PlainData` on each, with a diagnostic that names the field and suggests the attribute; or have `@StateNodeBuilder`/`@Payload` accept unannotated nested types, which the compiler can't check | require `@PlainData`, with the diagnostic |
| Q4 | The recorded raw action payload | keep the wire bytes (`Data` plus an encoding tag); or keep only the decoded typed value and re-encode it for the record, which can change record bytes (the integral-float case `RecordPayloadSource` handles) | keep the bytes |
| Q5 | A copy-on-write storage class inside a SwiftStateTree container, if K1's census finds one | rewrite it over value storage; or allow an audited hand-written `_plainDataCheck` in SwiftStateTree, with a value-semantics test | decide when the census finds one; none is known today |
| Q6 | #767's order | fold it into P2, with P1's mechanism; or ship it alone first | P2, with P1 |

### Decisions (maintainer, 2026-11-22)

| Q | Decision |
|---|---|
| Q1 | **D**, named `Behavior`: #768 adds `TurnMachine.Behavior`, given once to `TurnCore.init(machine:behavior:…)` and read through `turn.behavior` in every step kind |
| Q2 | **Refuse all four.** The diagnostic names the replacement: an `Int64` of milliseconds or the turn's `now` for `Date`; a `String` or a project ID type for `UUID`; a `String` for `URL`; an integer in the smallest unit or a `String` for `Decimal`. This replaces rev 1's recommendation (conform all four) |
| Q3 | **Require `@PlainData`** on nested user types, with a diagnostic |
| Q4 | **Keep the raw bytes** per action. The encoding goes once in the record header (`ReevaluationRecordMetadata`), not per entry; the bytes are base64 inside the JSON record |
| Q5 | If the census finds a copy-on-write class, **rewrite it over value storage**; no hand-written exception |
| Q6 | **Fold #767 into P2**, with P1 |
