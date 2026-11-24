# PlainData P3: payloads, server inputs, responses and resolver outputs are PlainData

**Status:** rev 1, plan only, no code. Slice P3 of [PlainData all the way](2026-11-22-plaindata-all-the-way.md) (§3.3, §4), on [P3/4-0](2026-11-24-plaindata-p34-0-shared-walk.md) (GO at a31edbb8), which lands the shared field walk, the re-export of `SwiftStateTurns` and Q3's diagnostic first. It takes in F2 of the #700 plan's census (Appendix A.6, agreed 2026-11-24): `ResponsePayload` refines `PlainData`, and an input's success is a plain `InputOutcome`. It leaves for #700 K1a what that plan's §3.11 lists under "What P3 must leave for K1a".

Code pointers are at main c3d416d9. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`. Counts are from a scan of `Sources/`, `Tests/` and `Examples/` at that commit: a declaration's own inheritance clause, attributes on the lines above it.

## 1. What changes

Six public protocols refine `PlainData`: `ActionPayload`, `ClientEventPayload`, `ServerEventPayload`, `ServerInputPayload`, `ResponsePayload` and `ResolverOutput`. Each conformer must then have `_plainDataCheck`. `@Payload` writes it, through the shared walk; a type that doesn't use `@Payload` (an enum payload, a resolver output) uses `@PlainData`. The keeper then holds a server input as its typed value, and an action's success as `InputOutcome`, not as `AnyCodable`.

| Protocol | Conformers | With `@Payload` | Without |
|---|---|---|---|
| `ActionPayload` | 145 | 143 | 2 (a macro-test fixture; `ENDoorAction`) |
| `ClientEventPayload` | 55 | 48 | 7 (5 enums in `SchemaGenTests`; `ENKnockEvent`, `FPPlainNote`) |
| `ServerEventPayload` | 128 | 121 | 7 (5 enums in `SchemaGenTests`; three bell/chime fixtures) |
| `ServerInputPayload` | 20 | 17 | 3 (`InitWaitInput`, two `Nudge`s) |
| `ResponsePayload` | 98 | 97 | 1 (`QueueIncrementResponse`) |
| `ResolverOutput` | 39 | 0 | 39 |

No conformer is a class or an actor. Three are generic: `ENGenericEvent<T: Codable & Sendable>`, `ENGenericAction<T>` (EventNameRegistrationTests.swift:66, 71) and `WNGenericEvent<W>` (PayloadWireNameTests.swift:37).

## 2. Design

### 2.1 `@Payload` makes its type `PlainData`

`@Payload` gains an extension role, `@attached(extension, conformances: PlainData, names: named(_plainDataCheck))`, beside its member role. It builds the extension the same way `@PlainData` does (one builder in `PlainDataMacroSupport`, moved there from `PlainDataMacro` in this slice, with the witness access rules #772 settled):
- When the type already conforms through one of the six protocols, the compiler passes no protocol, and the extension holds the witness only. That is `@PlainData`'s `protocols.isEmpty` branch (PlainDataMacro.swift:38).
- When it doesn't (a `@Payload` struct used only as a payload's field, or `TestPayload` in the macro tests), the extension also declares the conformance. So a nested type that already carries `@Payload` becomes `PlainData` with no second attribute.
- Field checks come from the shared walk, so `@Payload` refuses what `@PlainData` refuses: a class, closure, `Any`/`AnyObject`/`AnyHashable`/`AnyCodable` field, `Date`/`UUID`/`URL`/`Decimal` with Q2's replacement named, an existential outside the forms P1 accepts. Today `@Payload` refuses only `Decimal` (#597).
- A generic type gets `where T: SwiftStateTurns.PlainData` as `@PlainData` does. A generic payload conforms unconditionally through its primary declaration, so a constrained witness doesn't satisfy it: such a type declares `T: PlainData` itself. Q3's message names the field. The three generic fixtures change.

**Beside other attributes.**
- `@Payload` with `@PlainData` on the same type: `@Payload` refuses it with a diagnostic ("`@Payload` already makes this type PlainData; remove `@PlainData`"), as P4's `@StateNodeBuilder` does.
- `@Payload` with `@SnapshotConvertible` (P4-Q1 makes that macro write the conformance and witness): `@Payload` writes no extension and leaves the witness to `@SnapshotConvertible`. Whichever of P3 and P4 lands second adds its half, with a compile test of a type carrying both. No type in the repository carries both today, nor `@Payload` with `@StateNodeBuilder`.

**The lint.** `@Payload`'s `@attached(extension, …, names: named(_plainDataCheck))` names the member in code. Since #772 round 3, `PlainDataLintTests` refuses any `_plainDataCheck` or `PlainDataCheck` identifier token outside `Sources/SwiftStateTurns/`. P3, or P4 if it lands first (agreed with P4's owner), adds one exemption to the visitor: an identifier inside `named(…)` in the arguments of an `@attached(…)` attribute of a macro declaration. Fixtures: allowed in that position; refused in a `func`, and in `named(…)` of an attribute that isn't `@attached`.

### 2.2 The call sites that change

The compiler finds them; this is what the scan expects.
- **Payloads without `@Payload`** get `@Payload`, or `@PlainData` where the test is about a payload without `@Payload` (`FPPlainNote`, the server-input fingerprint tests: a type that lists no fields keeps that path, #521 D15) and for the `SchemaGenTests` enums (`@Payload` handles structs only).
- **Resolver outputs** get `@PlainData`: 39 types, 4 in GameDemo, 1 in Sources (see `AnyCodableResolverOutput` below).
- **Fields that stop compiling** (Q2 decided: refuse, with the replacement named):

| Where | Field | Change |
|---|---|---|
| `TickProcessedEvent`, `TickProcessedPayload` (ReevaluationMonitorEvents.swift:35, 61) | `expectedState`, `actualState: AnyCodable` | `String`. Production already puts the snapshot's JSON text in them (`AnyCodable(String(…))`, ReevaluationRunnerImpl.swift:433), so live frames don't change. The fixture in PayloadFrameGoldenTests.swift:247 builds them from object trees, so that fixture's expected bytes change. The GameDemo schema and generated TS types go from `AnyCodable` to `string`, regenerated. `TickProcessedPayload` has no user: it is deleted |
| `AnyCodableResolverOutput` (LandContext.swift:336, internal) | `value: AnyCodable` | §2.5 |
| GameDemo `AsyncTestOutput.resolvedAt: Date` | | `resolvedAtMillis: Int64`. No land declares the resolver, and no record holds the output (the records' `resolvedAt` matches are `resolvedAtTick`) |
| `ResolverOutputReplayTests` `ResolverReplayStamp` (`Date`, `URL`, `Decimal`); `ReplayTypedEventDecodeTests`, `VerifierRecordCodecTests` (`Date`, `URL`) | | #707's subject is a field that a JSON round trip can't read back. `Data` stays plain and still has that property, so each test keeps its `Data` field and drops the refused ones |
| `ServerInputTests` `SIDated.at: Date` | | it tests `.unencodable` through a `Date` outside 0001–9999. It moves to a payload nested past the record's depth, the other `.unencodable` cause |
| `ResolverFeasibilityTests` `ProductInfo.price: Decimal` | | `priceCents: Int64` |
| `PayloadWireNameTests` `WNPlayerShotEvent.d: Date` | | `Int64` |
| `InputDecodeOnceTests`, `MessagePackPayloadSourceTests` (`deep: AnyCodable`) | | a recursive `@PlainData` value (`indirect enum Nest { case leaf; case node([Nest]) }`), whose Codable form nests arrays one container per level, so the depths these tests pin stay as they are |
| `ClientFrameFuzzTests` `FuzzContainersEvent` (`any: AnyCodable`, `date`, `uuid`) | | dropped from the fixture; the fuzzer's container coverage is the arrays and dictionaries that remain |
| `PayloadFrameGoldenTests` `PFFallbacksEvent` (`AnyCodable`, `Date`, `UUID`) | | removed with its golden entries: the fallback forms can't reach a typed payload any more. The encoder's fallback code stays while `AnyServerEvent(type:payload:)` (public, takes `AnyCodable`) can still reach it |
| `DecimalSendTests` (`AnyCodable` event and response, a nested plain-`Codable` `Decimal` holder) | | the #597 runtime refusal stays reachable only through `AnyServerEvent(type:payload:)`. The event cases move to that entry. The response case goes: a typed response can't hold a `Decimal` |
| `SchemaFingerprintTests` `FPAnyEvent`, `RefusedFieldTypeDiagnosticTests` `ReportEvent` | | the fingerprint case goes; the macro test's expectations flip to the refusal |

- **Nested types without `@Payload`** used as payload fields need `@PlainData` (Q3, decided), for example the monitor's `TickMismatch` (ReevaluationMonitorState.swift:44, plain `Codable`), which a state also holds: whichever of P3 and P4 lands first adds it. Their number is what the build reports, each with Q3's message naming the field. The PR lists them.
- **`LandID`** gets `@PlainData` if a payload or server input holds one (agreed with P4: whichever lands first).

### 2.3 Server inputs held typed (#387 kept)

Today live applies a server input in its record form: `submitServerInputErased` builds `ServerInputCodec.recordedForm(of:)` (a canonical MessagePack round trip, checked against the record's depth) and queues that tree. The handler decodes it at apply (ServerInput.swift:105), live and in replay alike. That is how #387 makes a live apply and its replay decode the same value.

P3 moves the decode, not the rule:
- **Live, at submit:** after `recordedForm`, decode it as the declared type (`ServerInputCodec.decode`, the handler's `I`), in the same segment. The item holds the result, `input: any ServerInputPayload`, instead of `payload: AnyCodable`. So live still applies the record form's value.
- **A form that doesn't decode back** (an asymmetric `Codable`) is refused at submit as `.unencodable`, and nothing is queued. Today it is accepted, recorded, and fails alone in its turn. This is a behavior change: P3-Q2.
- **Replay, at build** (LK:4405): decode the recorded tree as the declared type when the item is built. A tree that doesn't decode is still queued, with the failure held as K1a's plain `RecordedPayloadDecodeFailure` (`.tooDeep(limit:)` / `.undecodable(String)`), which P3 introduces and K1a reuses. At apply it throws as today: the same type for `.tooDeep`, a `RecordedPayloadDecodeError` carrying the text for `.undecodable`, at the same point, so the input fails alone with the same report. That covers records written before P3 and hand-edited ones.
- **The record keeps today's tree.** The recorder writes `AnyCodable(item.input)`. Canonically encoded, that equals today's `recordedForm` tree for a `Codable` that round-trips, which every server input type in the repository does. A unit test compares the two per `ServerInputTests` fixture, and the record goldens don't move. No format bump (#700 §3.11).
- **The handler** takes the typed value: `AnyServerInputHandler` gains `decode: (AnyCodable) throws -> any ServerInputPayload` for the two decode points, and its invoke casts to `I` (the submit's identity check and the build's decode guarantee it).

`ServerInputRefusal.unencodable`'s doc drops "a `Date` outside the years 0001–9999" (a `Date` can't be a server input field any more) and adds "or its record form doesn't decode back to its type".

### 2.4 `ResponsePayload` and `InputOutcome` (F2)

`ResponsePayload` refines `PlainData` like the others. Inside the keeper, the success side of an input's result becomes a plain enum, as the census proposed:

```swift
@PlainData enum InputOutcome {   // internal
    case none                            // every input but an action's response
    case response(any ResponsePayload)
}
```

- `LandDefinition`'s package init: `invoke` returns `any ResponsePayload` instead of `AnyCodable(apply(…))` (LandDefinition.swift:305).
- `actionSlots` (LK:2251), `inputTurnResults` (LK:5652), `AppliedItem.action(response:)` (LK:3487), the slot and input-turn waiters, and the outcomes map (LK:3900–3944) hold `Result<InputOutcome, any Error>`. `AnyCodable(())` becomes `.none` (LK:2372, 2920, 3052, 3938, 3944, 5608, 5730).
- **The encode path stays K1a's** (F2's condition). The keeper's exits convert at the boundary, as today's values:
  - `ActionSubmission.completed` (package);
  - `awaitActionResult` (package);
  - `handleActionEnvelope` (public).
  
  `.none` becomes `AnyCodable(())`; `.response(r)` becomes `AnyCodable(r)`, the same concrete value inside, so the transport and its frames don't change. K1a moves the encode to the transport's reply and removes the conversion. The record holds no response and replay compares none, unchanged (F2's second condition).
- `FailureID` (F1) stays K1b's: P3 keeps `any Error` on the failure side.

### 2.5 Resolver outputs, `AnyCodableResolverOutput`, and randomness

`ResolverOutput` refines `PlainData`, and each output type carries `@PlainData`. The 39 conformers hold strings, numbers and nested values. The Foundation fields in §2.2 are the only ones that change.

**The replay wrapper.** In replay, a recorded output is held as `AnyCodableResolverOutput` (an `AnyCodable` tree), and `LandContext`'s subscript decodes it on read with the record's codec (#707). An `AnyCodable` can't be `PlainData`, so the wrapper stops conforming to `ResolverOutput`. `LandContext`'s private storage becomes an internal enum, `HeldResolverOutput { case live(any ResolverOutput); case recorded(RecordedResolverOutput) }`. `RecordedResolverOutput` is today's wrapper under a new name, not a `ResolverOutput`.
- The public `LandContext.init(resolverOutputs: [String: any ResolverOutput])` keeps its type and wraps `.live`. `replayedResolverOutputs` (LK:1183) builds `.recorded`.
- The subscript reads `.live` by cast and `.recorded` by the record codec, as today.
- `getAllResolverOutputs` (recording) writes `.live` as `AnyCodable(output)` and `.recorded` as its tree. Today it wraps the wrapper; a replaying keeper doesn't record, and that stays true.
- So the `.recorded` case isn't plain. #769 R1 maps recorded names to the declaration's positions, and R2 decodes at build (eager decode). The wrapper ends there, before K1b needs the context's outputs in the model.

**Randomness** (the same sentence as #769 §3.6, #773 and L-Q2): handlers draw `ctx.random` (the land's RNG, whose state moves into the model if L-Q2 (a) is decided); builders get none until admission is a recorded turn (K2/K5); resolvers use their own source, recorded. P3 changes no source: `AsyncTestOutput`'s wall-clock read stays in its resolver, and only its field's type changes.

**With #769.** #769 rev 2.1 (GO, 659cd242) runs R1 after P3. It relies on `ResolverOutput: PlainData` (§3.1) and on the outputs in §2.2 holding no Foundation types. P3 touches no resolver *declaration* and no `ContextResolver`, so R1's codemod sees the same call sites. #769's generic-parameter finding (§3.1.1, `@PlainData` constrains every generic parameter) applies to `@Payload`'s extension too, since it shares the builder; R1's macro change fixes both.

### 2.6 #616: not in P3

#616 (a live input's payload checked for depth once, by its frame's decode) was parked "until P3 removes the `AnyCodable` payload path". The census agreement leaves that path in place: P3 must not change `PayloadDecodingSource` or the pending items' stored shape, and K1a keeps `InboundPayloadDecoding`'s JSON round trip (#700 §3.11). Since #521 an action decodes once, at intake (LK:2978–2980). The redundant work #616 removes is one `PayloadNesting.check` walk per JSON-sourced action or event. Its own A/B measured the proof's plumbing as a +1.82 % regression before 917a0d24 trimmed it. P3-Q1 asks what happens to it.

## 3. Slices

| PR | Content | A/B |
|---|---|---|
| **P3a** | §2.1, §2.2, §2.5: the six protocols refine `PlainData`, `@Payload`'s extension role, the call-site changes, the replay wrapper split, the lint exemption, docs | none: compile time, and the wrapper split is a storage enum read once per output |
| **P3b** | §2.3: server inputs held typed, `RecordedPayloadDecodeFailure` | none: server inputs aren't on the client path, and the decode moves from apply to submit (one per input either way) |
| **P3c** | §2.4: `InputOutcome` in the keeper | small: `vis-act-mp` and `vis-act-json`. The response moves from an `AnyCodable` box to an existential, then into an `AnyCodable` at the exit. That can add an allocation for a response larger than an existential's inline buffer |

P3a goes first; P3b and P3c touch different keeper paths and can go in either order. Each is its own PR with its own Public API list.

## 4. Tests and mutants

Holds and events, never timing.

**P3a.**
- must-not-compile, `SwiftStateTree` set:
  - payloads with a class field and with a `Date` field (the expect-error is Q2's message);
  - a payload conformed without `@Payload` or `@PlainData` ("does not conform to protocol 'PlainData'");
  - a server input holding `AnyCodable`;
  - a resolver output with a closure;
  - a generic payload without `T: PlainData` (Q3's message naming the field);
  - `@Payload` beside `@PlainData` (the new diagnostic).
- Compiling snippets:
  - a payload holding a nested `@Payload` struct with no `@PlainData`;
  - an enum payload with `@PlainData`;
  - a resolver output with `@PlainData`.
- Macro tests:
  - `@Payload`'s extension with and without conformance (`protocols` empty or not);
  - a generic type's `where`;
  - the refusals the shared walk adds.
- The lint exemption's fixtures (§2.1).
- Mutants:
  - (a) `@Payload` writes no extension: the compiling snippets fail;
  - (b) the shared walk skips the class check: the class-field snippet compiles;
  - (c) the exemption also accepts `named(…)` outside `@attached`: its `refuses` case fails.
- `LandContext`: replay reads a `.recorded` output with the codec, and a live one by cast (the existing #707 tests, kept green). Recording a land's outputs writes the same tree as before: a golden or a unit test on `getAllResolverOutputs`.
- E2E in three encodings and the record/replay E2E (0 mismatch). Frames unchanged except the monitor fixture in `PayloadFrameGoldenTests` and the removed `PFFallbacksEvent` entries. Record goldens unchanged.

**P3b.**
- `replayServerInputDecodeFailureIsReportedAsBefore`, pinned on main first, as K1a's `replayPayloadDecodeFailureIsReportedAsBefore` is (#778): a recorded server input whose tree has a field of the wrong type fails alone, with today's log text and outcome. It stays green after P3b.
- A server input whose form doesn't decode back is refused `.unencodable` at submit, and nothing is queued or recorded. Mutant: skip the submit-time decode, and it is accepted.
- `serverInputRecordFormUnchanged`: per `ServerInputTests` fixture, canonical MessagePack of `AnyCodable(item.input)` equals that of today's `recordedForm`. Mutant: the recorder writes the input's JSON round trip (`InboundPayloadDecoding`'s form) instead of `AnyCodable(item.input)`; a fixture with a `Data` field (base64 text in JSON, `bin` in MessagePack) fails.
- The existing server-input record/replay tests and goldens unchanged.

**P3c.**
- A tickless land's action reply and a tick land's ACK reach the adapter with today's values: frame goldens unchanged, and a unit test on the conversion (`.none` → `AnyCodable(())`).
- Mutant: `.response` converted as `.none`: the action reply tests fail.

## 5. Verification

- On the Mac, holding the slot: `swift build`; `swift test --filter` for the touched suites (`SwiftStateTreeMacrosTests`, `SwiftStateTurnsMacrosTests` for the lint, the server-input, replay and resolver suites); `scripts/check-must-not-compile.sh`; `scripts/lint-turns.sh`; the mutants.
- GameDemo: schema and codegen regenerated (`TickProcessedEvent`), and the WebClient type check.
- On CI: the full `swift test` and E2E in three encodings, record/replay included.
- P3c's A/B on the measurement host, per §3.

## 6. Public API

Every break is a source break with no deprecation step, as for #593: there are no external users.
- **Breaks (P3a):**
  - `ActionPayload`, `ClientEventPayload`, `ServerEventPayload`, `ServerInputPayload`, `ResponsePayload` and `ResolverOutput` refine `PlainData`. A conformer needs `@Payload` or `@PlainData`. A field that isn't `PlainData` stops compiling: a class, a closure, `Any`, `AnyCodable`, `Date`, `UUID`, `URL`, `Decimal`, or a nested type without `@PlainData`. A generic conformer constrains its stored parameters to `PlainData`.
  - `TickProcessedEvent.expectedState`, `actualState` and its initializer take `String` (were `AnyCodable`). The live wire form is unchanged.
  - `TickProcessedPayload` is removed.
- **Additive (P3a):** `@Payload` declares an extension role (`conformances: PlainData`, `names: named(_plainDataCheck)`). It makes a type `PlainData` and refuses `@PlainData` beside it.
- **Behavior (P3b):** a server input whose record form doesn't decode back to its type is refused at submit (`.unencodable`), where today it was accepted and failed in its turn. `ServerInputRefusal.unencodable`'s doc changes to match (§2.3).
- **None public (P3c):** `InputOutcome`, `ActionSubmission`, `awaitActionResult` and the slots are internal or package. `handleActionEnvelope` keeps `-> AnyCodable`.

`AnyCodableResolverOutput`/`RecordedResolverOutput` and `HeldResolverOutput` are internal. `PendingServerInputItem` is package. `RecordedPayloadDecodeFailure` is package (K1a decides whether its record view exposes it).

## 7. Questions

| Q | Question | Options | Recommended |
|---|---|---|---|
| P3-Q1 | #616 | (a) close it as not needed: P3 doesn't remove the `AnyCodable` path, and K1a keeps the round trip. If a later change decodes a JSON payload from its frame bytes with no tree, the walk goes with the tree. (b) Keep it parked until K1a lands, then redesign it on K1a's typed item. (c) Take it into P3 | **(a).** What it saves is one walk per JSON-sourced input, and its plumbing measured as a regression. The lasting fix is to drop the tree, not to prove the walk redundant. That is a separate issue, for after K1a, if a profile shows the walk |
| P3-Q2 | A server input whose record form doesn't decode back to its type | (a) refused at submit (`.unencodable`): it is a broken `Codable` that no apply could run. (b) Accepted, recorded and failed in its turn, as today: the item then has to hold the failure live too | **(a)**: the caller learns at once, and a live keeper never queues an input it can't apply |

## 8. What P3 leaves for K1a (cross-check with #700 §3.11)

- `PendingActionItem`, `PendingClientEventItem` and `PayloadDecodingSource`: unchanged.
- The record's entry types, `ReevaluationRecordMetadata`, `ReevaluationRecordVersion` and the log's payload form: unchanged. A server input is recorded as `AnyCodable` of its typed value (§2.3).
- `InboundPayloadDecoding`'s JSON round trip: unchanged, in one place.
- `_payloadWireName`: still on every payload type. `@Payload` keeps writing it, and an `@PlainData` enum payload gets the protocol's runtime rule, as today without `@Payload`.
- The response's encode path and the record/replay of responses: K1a's (§2.4).
- `RecordedPayloadDecodeFailure`: introduced here for server inputs, with the shape §3.11 gives it, for K1a to use for actions and events.
