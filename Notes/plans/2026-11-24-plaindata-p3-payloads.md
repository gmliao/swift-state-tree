# PlainData P3: payloads, server inputs, responses and resolver outputs are PlainData

**Status:** rev 2.1, plan only, no code. Rev 2 answered Review's NOT GO on rev 1.1; rev 2.1 answers its targeted NOT GO on rev 2: the design stands, and tests that wouldn't catch their mutants are fixed (§9). P3-Q1 is decided (closed, maintainer 2026-11-24); P3-Q2 is decided (a), maintainer 2026-11-24 (§7). Slice P3 of [PlainData all the way](2026-11-22-plaindata-all-the-way.md) (§3.3, §4), on [P3/4-0](2026-11-24-plaindata-p34-0-shared-walk.md) (GO at a31edbb8), which lands the shared field walk, the re-export of `SwiftStateTurns` and Q3's diagnostic first. It takes in F2 of the #700 plan's census (Appendix A.6, agreed 2026-11-24): `ResponsePayload` refines `PlainData`, and an input's success is a plain `InputOutcome`. It leaves for #700 K1a what that plan's §3.11 lists under "What P3 must leave for K1a".

Code pointers are at main c3d416d9. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`. Counts are from a scan of `Sources/`, `Tests/` and `Examples/` at that commit, outside the macro tests: a declaration's or extension's own inheritance clause, attributes on the lines above it. Rev 2's counts were redone and agree with Review's Codex track.

## 1. What changes

Six public protocols refine `PlainData`: `ActionPayload`, `ClientEventPayload`, `ServerEventPayload`, `ServerInputPayload`, `ResponsePayload` and `ResolverOutput`. Each conformer must then have `_plainDataCheck`. `@Payload` writes it, through the shared walk; a type that doesn't use `@Payload` (an enum payload, a resolver output) uses `@PlainData`. The keeper then holds a server input as its typed value, and an action's success as `InputOutcome`, not as `AnyCodable`.

| Protocol | Conformers | With `@Payload` | Without |
|---|---|---|---|
| `ActionPayload` | 143 | 141 | 2: `ENDoorAction`, `RTHandWrittenAction` (LandRegistrationPayloadTests.swift:25) |
| `ClientEventPayload` | 55 | 48 | 7: 5 enums in `SchemaGenTests`; `ENKnockEvent`, `FPPlainNote` |
| `ServerEventPayload` | 126 | 115 | 11: 5 enums in `SchemaGenTests`; `FPPlainEvent`, `ENPlainEvent`, `ENBellEvent`, `EHBellEvent`, `EHTChimeEvent`, `HostHandWrittenEvent` (NIOLandHostTests.swift:386), `PWHandWrittenEvent` (PayloadWithoutWriterTests.swift:12) |
| `ServerInputPayload` | 20 | 16 | 4: `FPPlainInput`, `InitWaitInput`, two `Nudge`s |
| `ResponsePayload` | 98 | 96 | 2: `QueueIncrementResponse`, `RTHandWrittenResponse` |
| `ResolverOutput` | 39 | 0 | 39 |

Outside `Tests/` and `Examples/`, `scripts/must-not-compile/Prelude.swift:30` declares `SnippetInput: ServerInputPayload` without `@Payload`. Every snippet imports the prelude, so it gets `@Payload` in P3a, or every snippet would fail for the wrong reason.

No conformer is a class or an actor. Three are generic: `ENGenericEvent<T: Codable & Sendable>`, `ENGenericAction<T>` (EventNameRegistrationTests.swift:66, 71) and `WNGenericEvent<W>` (PayloadWireNameTests.swift:37). One is nested in a generic type: `WNBox<T>.InnerEvent` (PayloadWireNameTests.swift:41), which stores no `T`.

## 2. Design

### 2.1 `@Payload` makes its type `PlainData`

`@Payload` gains an extension role, `@attached(extension, conformances: PlainData, names: named(_plainDataCheck))`, beside its member role. It builds the extension the same way `@PlainData` does (one builder in `PlainDataMacroSupport`, moved there from `PlainDataMacro` in this slice, with the witness access rules #772 settled):
- When the type already conforms through one of the six protocols, the compiler passes no protocol, and the extension holds the witness only. That is `@PlainData`'s `protocols.isEmpty` branch (PlainDataMacro.swift:38).
- When it doesn't (a `@Payload` struct used only as a payload's field, or `TestPayload` in the macro tests), the extension also declares the conformance. So a nested type that already carries `@Payload` becomes `PlainData` with no second attribute.
- Field checks come from the shared walk, so `@Payload` refuses what `@PlainData` refuses: a class, closure, `Any`/`AnyObject`/`AnyHashable`/`AnyCodable` field, `Date`/`UUID`/`URL`/`Decimal` with Q2's replacement named, an existential outside the forms P1 accepts. Today `@Payload` refuses only `Decimal` (#597).
- **Generic payloads.** A payload conforms unconditionally, through its primary declaration's inheritance clause. A conditional witness (`where T: PlainData`) can't satisfy that conformance, so a payload that stores a generic parameter declares the constraint itself. The macro sees the declaration, so it diagnoses the case instead of leaving the compiler's message:
  - **the rule:** for a type whose inheritance clause names one of the six protocols, each generic parameter that stored content names (#769 §3.1.1's "named" test) must have `PlainData`, or one of the six protocols, among its constraints. That means its own inheritance or a `where` requirement on it, as spelled;
  - **if not, a diagnostic** at the parameter: "generic parameter 'T' is stored in 'value'; a payload must declare 'T: PlainData'";
  - **a spelling the macro can't read** passes the macro, for example a typealias or a protocol that refines `PlainData` under another name. The compiler then refuses it with its own message. The must-not-compile snippet for that case pins the fragment `does not conform to protocol 'PlainData'`, which is stable across 6.4.x;
  - **the extension** writes no `where` for such a type, since the parameters already carry it;
  - `WNBox<T>.InnerEvent` stores no `T` and gets an unconditional extension. It is a compiling fixture as it is;
  - **the three generic fixtures** add `T: PlainData`;
  - **the builder** is the one #772 merges: round 5's value-form builder, in `PlainDataMacroSupport`. P3a follows its final shape and doesn't fork it.

**Local types (found in P3a).** Swift doesn't attach an extension macro to a type declared inside a function: the compiler refuses the attachment itself ("local type cannot have attached extension macro", probed with `swiftc -typecheck` on 6.4.3), whether or not the macro would write an extension. So a `@Payload` or `@PlainData` type can't be local. About 35 test fixtures were local (in `SchemaGenTests`, `LandDSLTests`, `ActionEventSyncTests`, `TransportMessageEncoderTests`, `FieldMetadataDefaultValueTests`); each moves into a `private enum <testName>Fixtures` beside its test, which keeps the last-component names that schemas and wire names read. A member-role witness for `@Payload` was considered and declined: it can't add the conformance for a `@Payload` struct used as a field, and a local `@PlainData` type would still not compile. The must-not-compile snippet `payload-local-type.swift` pins the limit, and fails if a later Swift lifts it. No payload in `docs/` or `Examples/` is local.

**Beside other attributes.**
- `@Payload` with `@PlainData` on the same type: `@Payload` refuses it with a diagnostic ("`@Payload` already makes this type PlainData; remove `@PlainData`"), as P4's `@StateNodeBuilder` does.
- `@Payload` with `@SnapshotConvertible`, `atomic:` or not: both write `getFieldMetadata()`, so the pair doesn't compile today (a redeclaration). `@Payload` refuses it with a diagnostic naming the other attribute. No type in the repository carries both, nor `@Payload` with `@StateNodeBuilder`.
- **Who writes `_plainDataCheck`, in either landing order.** A type has one writer:
  - with `@Payload` only, `@Payload` writes it;
  - with `@SnapshotConvertible` only, P4-Q1 makes that macro write it;
  - the pair is refused (above).
  
  If P3 lands first, a `@SnapshotConvertible` type isn't a payload and gets its witness in P4. If P4 lands first, `@Payload` is unchanged until P3. Neither order leaves a type with two witnesses or none.

**The lint.** `@Payload`'s `@attached(extension, …, names: named(_plainDataCheck))` names the member in code. Since #772 round 3, `PlainDataLintTests` refuses any `_plainDataCheck` or `PlainDataCheck` identifier token outside `Sources/SwiftStateTurns/`. P3, or P4 if it lands first (agreed with P4's owner), adds one exemption to the visitor, as narrow as the use:
- **Exempt:** the identifier `_plainDataCheck`, and only it (`PlainDataCheck` stays refused everywhere), inside `named(…)` in the `names:` argument of an `@attached(…)` attribute on a macro declaration.
- **Fixtures, allowed:** that position.
- **Fixtures, refused:**
  - `_plainDataCheck` in a `func`;
  - `_plainDataCheck` in `named(…)` of an attribute that isn't `@attached`;
  - `_plainDataCheck` in another argument of `@attached` (`conformances:`);
  - `PlainDataCheck` inside `names: named(…)`.

### 2.2 The call sites that change

The compiler finds them; this is what the scan expects. Registration doesn't change: a land still lists its types (`ClientEvents { Register(…) }` and the other blocks, kept by #771 rev 2.2), and nothing here assumes a payload registers itself.
- **Payloads without `@Payload`** (the table in §1):
  - **`@PlainData`, not `@Payload`,** where the test is about a payload without `@Payload`, so that path stays tested. These are the hand-written ones (`RTHandWrittenAction`, `RTHandWrittenResponse`, `HostHandWrittenEvent`, `PWHandWrittenEvent`), the plain ones (`FPPlainNote`, `FPPlainEvent`, `FPPlainInput`, `ENPlainEvent`: a type that lists no fields keeps that path, #521 D15), and the bell and chime fixtures;
  - **`@PlainData`** also for the `SchemaGenTests` enums (`@Payload` handles structs only);
  - **`@Payload`** for the rest: `ENDoorAction`, `ENKnockEvent`, `InitWaitInput`, the `Nudge`s, `QueueIncrementResponse`, and the prelude's `SnippetInput`.
- **Each replaced fixture keeps its assertion.** A test whose fixture stops compiling either keeps the assertion with a fixture that still reaches it, or moves it to a must-not-compile snippet that fails for that reason. The PR lists each, old assertion to new. One case is `DecimalAlias` (DecimalRegistrationTests.swift:16):
  - `DecimalRegistrationTests`' payload cases (an event, an action, a response and a server input holding `DecimalAlias`, refused at registration naming each path) stop compiling, since `Decimal` isn't `PlainData`;
  - the macro sees only the spelling, so the refusal is the compiler's, not Q2's message;
  - the assertion moves to one must-not-compile snippet per payload kind, pinning `does not conform to protocol 'PlainData'`;
  - the synced cases stay P4's.
- **Resolver outputs** get `@PlainData`: 39 types, 4 in GameDemo, 1 in Sources (see `AnyCodableResolverOutput` below).
- **Fields that stop compiling** (Q2 decided: refuse, with the replacement named):

| Where | Field | Change |
|---|---|---|
| `TickProcessedEvent`, `TickProcessedPayload` (ReevaluationMonitorEvents.swift:35, 61) | `expectedState`, `actualState: AnyCodable` | `String`. Production already puts the snapshot's JSON text in them (`AnyCodable(String(…))`, ReevaluationRunnerImpl.swift:433), so live frames don't change. The fixture in PayloadFrameGoldenTests.swift:247 builds them from object trees, so that fixture's expected bytes change. The GameDemo schema and generated TS types go from `AnyCodable` to `string`, regenerated. `TickProcessedPayload` has no user: it is deleted. **The bridge:** the monitor land builds the event from the public `ReevaluationStepResult.actualState: AnyCodable?` (ReevaluationInterfaces.swift:30, ReevaluationMonitorLand.swift:59), which stays as it is. A `String` inside passes through. Any other value, from a runner that isn't the built-in one, is encoded as JSON text with sorted keys, and the projector (ReevaluationReplayProjector.swift:42) reads it the same way. **Pinned on main first:** one `TickProcessedEvent` frame from the built-in runner in `json`, `opcodeJsonArray` and `messagepack`, unchanged after P3a |
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
- **`LandID`** gets `@PlainData` in P3a. A payload holds one (`PayloadFrameGoldenTests.swift:43`, `let land: LandID`), so it is a P3a dependency, not a whichever-lands-first item. P4 finds it done.

### 2.3 Server inputs held typed (#387 kept)

Today live applies a server input in its record form. `submitServerInputErased` builds `ServerInputCodec.recordedForm(of:)` (a canonical MessagePack round trip, checked against the record's depth) and queues that tree. The handler decodes it at apply (ServerInput.swift:105), live and in replay alike. That is how #387 makes a live apply and its replay decode the same value.

P3 moves the decode, not the rule. **The item keeps the tree, and adds the typed value decoded from it:**

```swift
package struct PendingServerInputItem: Sendable {
    package let sequence: Int64
    package let typeIdentifier: String
    package let payload: AnyCodable                     // the record form: what the record writes
    package let decoded: Result<any ServerInputPayload, RecordedPayloadDecodeFailure>
    package let resolvedAtTick: Int64
}
```

- **The record writes `payload`, the tree, as today.** It doesn't re-encode the typed value. A re-encode differs from the tree whenever decode-then-encode isn't the identity, for example:
  - an `Int??` field holding `.some(nil)` is in the tree as an explicit nil; it decodes to `.none` and re-encodes with the key absent;
  - a hand-written `Codable` whose `init(from:)` normalizes what `encode(to:)` wrote verbatim: it lowercases a string, so `"ABC"` is in the tree and `"abc"` in the re-encode.
  
  So "record unchanged" holds by construction, not by a property of every type, and the record goldens can't move.
- **Live applies `decoded`**, the value decoded from that same tree: the value replay decodes. The tree and the value come from one decode, at submit.
- **Live, at submit, in order** (P3-Q2 (a), decided, §7). Steps 1–5 are today's (LK:3204–3236):
  1. `ensureInitialized`: a land that failed to initialize refuses `.draining`;
  2. the mode: a keeper that isn't live refuses `.notLive`;
  3. the identity check: `.unknownType`;
  4. the drain check: `.draining`;
  5. `recordedForm`: `.unencodable` for a tree that can't be built or exceeds the record's depth. This one fires **before** the cap, as today;
  6. the in-flight cap: `.overCap`;
  7. **the decode** (new; `ServerInputCodec.decode`, the handler's `I`). A tree that doesn't decode back is refused `.unencodable`. This one fires **after** the cap;
  8. the sequence and the queue.
  
  The new decode comes after the cap check, so an input refused for the cap costs no decode. It comes before the sequence is taken, so a refused input leaves no gap in the sequence. **Two inputs pin the combined case:** one that is over the cap and doesn't decode back is refused `.overCap` (the cap comes first), and one under the cap that doesn't decode back is refused `.unencodable` with the sequence unchanged.
- **Under a debug freeze** the decode happens at submit too: the held item (`serverInputsHeldWhileFrozen`) has `decoded` set before it waits. A resume only queues it, and apply reads `decoded`, so an input is decoded once across freeze, resume and apply, and a freeze changes no refusal.
- **Replay, at build** (LK:4405): `decoded` is the decode of the recorded tree. A tree that doesn't decode is still queued, with `.failure(RecordedPayloadDecodeFailure)`. At apply it throws at the same point as today, so the input fails alone with the same report. That covers records written before P3 and hand-edited ones.
- **The failure, per source.** Today a too-deep recorded server input throws `CanonicalMessagePackError.nestingTooDeep` from the record codec (ServerInput.swift:201), not `PayloadNesting.TooDeep`. So the failure record gets a case per source, and each rebuilds its source's error type:

  ```swift
  @PlainData package enum RecordedPayloadDecodeFailure: Error {
      case tooDeep(limit: Int)        // rebuilt as PayloadNesting.TooDeep(limit:) (K1a: actions, events)
      case recordTooDeep              // rebuilt as CanonicalMessagePackError.nestingTooDeep (server inputs)
      case undecodable(String)        // rebuilt as RecordedPayloadDecodeError, the decode error's text
  }
  ```

  - It is `package` and an `Error`, since the item holds it as `Result`'s failure.
  - `recordTooDeep` is the case K1a's shape (#700 §3.11) doesn't have. K1a reuses the enum as it is.
  - **Which errors keep today's type.** Only the too-deep one: `.recordTooDeep` rebuilds today's `CanonicalMessagePackError.nestingTooDeep`. A field of the wrong type throws `CanonicalMessagePackError.typeMismatch` today. After P3b it arrives as `.undecodable(text)`, and apply throws `RecordedPayloadDecodeError`, a new type.
  - So that the report doesn't change, `RecordedPayloadDecodeError` is `CustomStringConvertible`, and its `description` returns the stored text verbatim: `String(describing:)` of today's error. Nothing in replay matches a server input's error by type. `applyInputs` logs `String(describing: error)` and counts it (LK:3941–3960), so the log line and `replayRejected` are unchanged.
  - A unit test pins the rebuilt error for each case: its type, and its description against today's (§4).
- **The handler** takes the typed value. `AnyServerInputHandler` gains `decode: (AnyCodable) throws -> any ServerInputPayload` for the two decode points. Its invoke casts to `I`: the submit's identity check and the build's decode guarantee the cast.

`ServerInputRefusal.unencodable`'s doc drops "a `Date` outside the years 0001–9999" (a `Date` can't be a server input field any more) and adds "or its record form doesn't decode back to its type".

### 2.4 `ResponsePayload` and `InputOutcome` (F2)

`ResponsePayload` refines `PlainData` like the others. Inside the keeper, the success side of an input's result becomes a plain enum, as the census proposed:

```swift
@PlainData enum InputOutcome {   // internal
    case none                            // every input but an action's response
    case response(any ResponsePayload)
}
```

- **`AnyActionHandler`.** Its stored handler returns `any ResponsePayload` instead of `AnyCodable`. That covers the public init's closure (LandDefinition.swift:305) and the DSL's box (LandDSL.swift:1024), which stop wrapping in `AnyCodable`.
  - **The public methods keep their signatures.** `invoke(_:action:ctx:)` and `invokeErased(_:action:ctx:)` (LandDefinition.swift:348, 357) are public and return `AnyCodable`. They stay, and wrap: `AnyCodable(try handler(…))`, the same concrete value inside as today. `MonitorTicketTests.swift:242` calls `invoke` and is unchanged.
  - **A package `invokeTyped(_:action:ctx:) -> any ResponsePayload`** is what the keeper calls (LK:3609, today `invokeErased`).
  - **The package init** (`invoke: … -> AnyCodable`) takes `… -> any ResponsePayload`.
- **Two tests use the package init to answer with a dictionary**, which can't be a `ResponsePayload` any more: `UntypedEventPayloadTests` (`makeUntypedResponseLand`, line 174) and `ClosedGatePendingFailureTests` (`makeClosedGateLand`, line 74). They test what happens when an action's answer fails to encode at the adapter. **The new seam keeps that failure at the adapter's encode:**
  - **The throw sits in a field's type, not in the reply's own `encode(to:)`.** The compressed encoders don't call a `@Payload` type's `encode(to:)`. They call its `_writePayloadFields` (PayloadMacro.swift:248–265, MessagePackTransportMessageEncoder.swift:254–280), so a throwing `encode(to:)` on the reply would be bypassed on `messagepack` and `opcodeJsonArray`, which most of these tests use (ClosedGatePendingFailureTests.swift:203–309). A field of a plain `Codable` type is written through the writer's `Codable` fallback on every encoder. So:

    ```swift
    @PlainData struct UnencodableMarker {          // test fixture
        func encode(to encoder: any Encoder) throws { throw UnencodableMarkerError() }
    }
    @Payload struct UnencodableReply: ResponsePayload { let marker: UnencodableMarker }
    @Payload struct UnencodableResponseAction: ActionPayload { typealias Response = UnencodableReply; let tag: String }
    ```
  - **The fixture's error first.** A unit test encodes `UnencodableReply` with each transport encoder (`json`, `opcodeJsonArray`, `messagepack`) and expects `UnencodableMarkerError` from each. Only then do the land tests run on it;
  - the handler is the public `HandleAction` form, so the package init has no dictionary user left;
  - the keeper never encodes a response (it converts to `AnyCodable` at the exit, below, without encoding), so the first encode is the adapter's. The tests' holds (`.failureSubmit`) stay;
  - **assertions that name `UntypedPayloadError` for the response land** move to `UnencodableMarkerError`, for example the failure detail at UntypedEventPayloadTests.swift:347. The PR lists each. The untyped-event assertions stay as they are: `AnyServerEvent(type:payload:)` can still carry a dictionary;
  - **`UntypedResponseAction` and `UntypedResponseReply` stay.** `ActionErrorReplyEncodeTests` (lines 20–25) uses them for an action whose `validate` throws; its reply never encodes. Only the two failing-encode lands move to `UnencodableResponseAction`;
  - the PR shows each test reaching the same hold, with the same outcome, as on main. A mutant, the marker's `encode(to:)` succeeding, makes both tests fail.
- **The keeper's inventory**, every place that holds an input's success as `AnyCodable` today. Each holds `Result<InputOutcome, any Error>` after P3c:
  - the action slots (`actionSlots`, LK:2251) and `fillActionSlot` (LK:2447);
  - the job's completion (LK:2350–2372) and its cancellation (`cancelActionJob`, LK:2519);
  - `AppliedItem.action(response:)` (LK:3487);
  - the outcomes map (LK:3900–3944);
  - `inputTurnResults` (LK:5652, 5730);
  - the slot and input-turn waiters (LK:5608).

  `AnyCodable(())` becomes `.none` at LK:2372, 2920, 3052, 3938, 3944, 5608 and 5730.
- **What stays `AnyCodable`, at the boundary:** the transport adapter's `Result<AnyCodable, any Error>` (TransportAdapter.swift:5448, 5476), which `awaitActionResult` feeds.
- **The encode path stays K1a's** (F2's condition). The keeper's exits convert at the boundary, as today's values:
  - `ActionSubmission.completed` (package);
  - `awaitActionResult` (package);
  - `handleActionEnvelope` (public).
  
  `.none` becomes `AnyCodable(())`; `.response(r)` becomes `AnyCodable(r)`, the same concrete value inside, so the transport and its frames don't change. One conversion function does it, used at the three exits. K1a moves the encode to the transport's reply and removes the conversion. The record holds no response and replay compares none, unchanged (F2's second condition).
- `FailureID` (F1) stays K1b's: P3 keeps `any Error` on the failure side.

### 2.5 Resolver outputs, `AnyCodableResolverOutput`, and randomness

`ResolverOutput` refines `PlainData`, and each output type carries `@PlainData`. The 39 conformers hold strings, numbers and nested values. The Foundation fields in §2.2 are the only ones that change.

**The replay carrier.** Today a recorded output in replay is an `AnyCodableResolverOutput`, an `AnyCodable` tree that conforms to `ResolverOutput`. `LandContext`'s subscript decodes it on read with the record's codec (#707). An `AnyCodable` can't be `PlainData`, so the wrapper stops conforming to `ResolverOutput`, and everything that stores outputs as `[String: any ResolverOutput]` needs another type for replay. P3 names it:

```swift
/// A resolver output as an item holds it: produced live, or read from a record.
package enum HeldResolverOutput: Sendable {
    case live(any ResolverOutput)
    case recorded(RecordedResolverOutput)
}

/// Replay only: a recorded output's tree, decoded when the handler reads it (#707).
package struct RecordedResolverOutput: Sendable {
    let typeIdentifier: String
    let value: AnyCodable
    let integralFloats: Bool       // the JSON view's integer-to-float allowance
}
```

**The path, end to end:**
- **Build.** `replayedResolverOutputs` (LK:1183) returns `[String: HeldResolverOutput]` of `.recorded`, with `integralFloats` set as today, for a `JSONReevaluationSource`. Live resolution (LK:2324, 1783, 2008, 2705) produces `.live`.
- **The replayed items' init.** The replay builds an action item (LK:4358) and a lifecycle item (LK:4434) with the public initializers today. Each gets a package initializer that takes the held form, `heldResolverOutputs: [String: HeldResolverOutput]`. The action's keeps today's `AnyCodablePayloadSource` for the recorded payload and `decoded: nil`, so the payload is decoded at apply as today (K1a changes that, not P3).
- **Pending storage.** `PendingActionItem` and `PendingLifecycleItem` hold `package let heldResolverOutputs: [String: HeldResolverOutput]`.
  - **Their public `resolverOutputs: [String: any ResolverOutput]` property** (LK:208, 168) can't hold a `.recorded` output, so it goes. That is a public break (§6).
  - Their public initializers keep taking `[String: any ResolverOutput]` and wrap each in `.live`.
  - **`PendingAction`** (LK:331), the legacy queue's item, has no replay path, so its outputs are always live. It keeps its public property, a narrower break than rev 2 listed. `TicklessReplayPassTests.swift:661` reads `PendingAction`'s and is unaffected.
- **The held map is carried end to end:**
  - `LandContext.getAllResolverOutputs()` returns `[String: HeldResolverOutput]`;
  - `completeAction` (LK:2336) passes it on;
  - `with(resolverOutputs:resolvedAtTick:)` (package, LK:258) takes the held form, renamed `with(heldResolverOutputs:resolvedAtTick:)`;
  - nothing converts back to `[String: any ResolverOutput]` on the way, so a `.recorded` output can't be dropped by a cast.
- **`makeContext`** (LK:3326) and `LandContext`'s private storage take `[String: HeldResolverOutput]`:
  - the internal init takes the held form;
  - `setResolverOutput` (a live resolver writing its output) stores `.live`;
  - **the subscript** reads `.live` by cast, and `.recorded` lazily with `RecordPayloadSource(value, integralFloats:)`, as today (#707). A failed decode still logs today's warning ("A recorded resolver output doesn't decode in replay; the handler reads nil", with the output's name and the error) and returns nil.
- **The record: one projection for all three write sites.** The sites are the initialize record (LK:1376), the action (LK:3586) and the lifecycle item (LK:3753). A single `recordedResolverOutputs(_ held: [String: HeldResolverOutput]) -> [String: ReevaluationRecordedResolverOutput]` replaces the three copies:
  - `.live(o)` writes `typeIdentifier: String(describing: type(of: o))` and `value: AnyCodable(o)`, as today;
  - `.recorded(r)` writes `r.typeIdentifier` and `r.value`, the tree it was read as.

  A replaying keeper doesn't record today, and still doesn't. The `.recorded` branch exists so that the projection is total, not because a record is written from replay.
- **`AnyCodableResolverOutput`** becomes `RecordedResolverOutput`, internal to the keeper and the context. It isn't a `ResolverOutput`, so nothing outside can mistake it for an output.

**Where the raw trees live, after P3 and after K1b:**
- **After P3:** in `.recorded`, in the items and the context, replay only. `HeldResolverOutput` is `Sendable` and not `PlainData`, since `AnyCodable` isn't.
- **K1b** moves the pending queue into `KeeperModel`, which is `@PlainData` (#700 §3.1). So K1b stores `.recorded`'s tree as its canonical MessagePack bytes, `Data` (as `recordedForm` already encodes a tree, ServerInput.swift:190). With the type identifier and `integralFloats` beside them, that makes `RecordedResolverOutput` `@PlainData`. The subscript decodes the bytes on read, still lazily, still with the warning on failure. This is K1b's change, named here so K1b's census finds the field (#700 Appendix A's `pendingItems` row).
- **R2, with K5,** decodes every output when the item is built (#769 §3.3, eager decode). `.recorded` and its bytes go, and items hold typed outputs only.

**Randomness** (the same sentence as #769 §3.6, #773 and L-Q2): handlers draw `ctx.random` (the land's RNG, whose state moves into the model in #700 K1b (L-Q2 (a))); builders get none until admission is a recorded turn (K2/K5); resolvers use their own source, recorded. P3 changes no source: `AsyncTestOutput`'s wall-clock read stays in its resolver, and only its field's type changes.

**With #769.** #769 rev 2.2 (GO, 48fcabcf) runs R1 after P3. It relies on `ResolverOutput: PlainData` (§3.1) and on the outputs in §2.2 holding no Foundation types. P3 touches no resolver *declaration* and no `ContextResolver`, so R1's codemod sees the same call sites. #769's generic-parameter rule (§3.1.1: constrain only the parameters stored content names, probed in its R0) shares the builder with `@Payload`'s extension. A payload, unlike a resolver, conforms unconditionally, so §2.1's diagnostic applies to it on top of that rule.

### 2.6 #616: closed, not in P3

#616 (a live input's payload checked for depth once, by its frame's decode) was parked "until P3 removes the `AnyCodable` payload path". The census agreement leaves that path in place: P3 must not change `PayloadDecodingSource` or the pending items' stored shape, and K1a keeps `InboundPayloadDecoding`'s JSON round trip (#700 §3.11). Since #521 an action decodes once, at intake (LK:2978–2980). The redundant work #616 removes is one `PayloadNesting.check` walk per JSON-sourced action or event. Its own A/B measured the proof's plumbing as a +1.82 % regression before 917a0d24 trimmed it. **Decided (P3-Q1):** the maintainer closed #616 on 2026-11-24. The remaining JSON walk goes with #606. P3 does nothing for it.

## 3. Slices

| PR | Content | A/B |
|---|---|---|
| **P3a** | §2.1, §2.2, §2.5: the six protocols refine `PlainData`, `@Payload`'s extension role, the call-site changes, the replay carrier, the lint exemption, docs | none on the measurement host: compile time, and the carrier is a storage enum read once per output. **A Mac output check:** `vis-act-mp` and the record/replay E2E produce the same frames and the same record bytes as main (a diff, not a timing) |
| **P3b** | §2.3: server inputs held typed, `RecordedPayloadDecodeFailure` | **a focused cost check, not an A/B cell:** server inputs aren't on the client path, and the decode moves from apply to submit (one per input either way). A micro-benchmark of submit plus apply for one server input, main against P3b, release build, reports both medians. The item now holds the tree and the value, so the check also reports the item's size |
| **P3c** | §2.4: `InputOutcome` in the keeper | **two cells, each with an out-of-line response:** one tick land and one tickless, each answering an action with a response larger than an existential's three-word inline buffer (a struct of four `Int`s and a `String`), on `messagepack`. The response moves from an `AnyCodable` box to an existential, then into an `AnyCodable` at the exit, and that can add an allocation exactly when it doesn't fit inline. `vis-act-mp` and `vis-act-json` as before, beside them |

P3a goes first; P3b and P3c touch different keeper paths and can go in either order. Each is its own PR with its own Public API list.

## 4. Tests and mutants

Holds and events, never timing.

**P3a.**
- must-not-compile, `SwiftStateTree` set:
  - payloads with a class field and with a `Date` field (the expect-error is Q2's message);
  - a payload conformed without `@Payload` or `@PlainData` ("does not conform to protocol 'PlainData'");
  - a server input holding `AnyCodable`;
  - a resolver output with a closure;
  - a generic payload that stores `T` without `T: PlainData` (§2.1's diagnostic naming the parameter and the field), and one whose constraint the macro can't read (the compiler's `does not conform to protocol 'PlainData'`);
  - `@Payload` beside `@PlainData`, and beside `@SnapshotConvertible` (the new diagnostics);
  - one per payload kind holding `DecimalAlias` (§2.2: the moved `DecimalRegistrationTests` assertion).
- Compiling snippets:
  - a payload holding a nested `@Payload` struct with no `@PlainData`;
  - an enum payload with `@PlainData`;
  - a resolver output with `@PlainData`;
  - `WNBox<T>.InnerEvent` (a payload nested in a generic type);
  - the prelude's `SnippetInput` with `@Payload`: every existing snippet still fails for its own reason (the script's expect-error lines are unchanged).
- Macro tests:
  - `@Payload`'s extension with and without conformance (`protocols` empty or not);
  - a generic type's `where`;
  - the refusals the shared walk adds.
- The lint exemption's fixtures (§2.1).
- Mutants:
  - (a) `@Payload` writes no extension: the compiling snippets fail;
  - (b) the shared walk skips the class check: the class-field snippet compiles;
  - (c) the exemption also accepts `named(…)` outside `@attached`: its `refuses` case fails;
  - (d) the exemption also accepts `PlainDataCheck`: its `refuses` case fails;
  - (e) the generic-parameter diagnostic skipped: its snippet fails with the compiler's text, not the diagnostic's;
  - (f) the record projection writes `.recorded` as `AnyCodable(r)` (the carrier, not its tree): the projection's unit test fails.
- `LandContext`: replay reads a `.recorded` output with the codec, and a live one by cast (the existing #707 tests, kept green, including the JSON view's `integralFloats` case and the warning on a failed decode, which a test captures by its log text).
- The record projection: a unit test feeds one `.live` and one `.recorded` output and checks both entries. The record goldens with resolver outputs don't move.
- The monitor: the three `TickProcessedEvent` frames pinned on main (§2.2) are unchanged, and a step result whose `actualState` isn't a `String` reaches the event as JSON text.
- E2E in three encodings and the record/replay E2E (0 mismatch). Frames unchanged except the monitor fixture in `PayloadFrameGoldenTests` and the removed `PFFallbacksEvent` entries. Record goldens unchanged.

**P3b.**
- **`replayServerInputDecodeFailureIsReportedAsBefore`**, pinned on main first, as K1a's `replayPayloadDecodeFailureIsReportedAsBefore` is (#778). It stays green after P3b.
  - **Three recorded server inputs:** a field of the wrong type, a tree nested past the record codec's depth, and a good one.
  - **The frame is built in memory,** with `JSONReevaluationSource(metadata:frames:)`. A record file can't hold the deep one: the loader refuses a tree that deep (ActionSource.swift:265, CanonicalMessagePack.swift:754), so a file-based fixture would never reach the build.
  - **What it pins.** Replay applies a failing input inside `applyInputs`, which logs and counts it (LK:3941–3960) and throws nothing to the caller. So the test pins what that leaves:
    - the state after the tick: the good input applied, the other two not;
    - `replayRejected`;
    - the log text of each failure, captured.
- **The rebuilt errors** are a unit test of `RecordedPayloadDecodeFailure`, not of the replay:
  - `.recordTooDeep` rebuilds `CanonicalMessagePackError.nestingTooDeep`, today's type and value;
  - `.undecodable(text)` rebuilds `RecordedPayloadDecodeError`, whose `description` equals `text`. `text` is `String(describing:)` of today's `CanonicalMessagePackError.typeMismatch` for the wrong-type fixture;
  - `.tooDeep(limit:)` rebuilds `PayloadNesting.TooDeep(limit:)`.
- **Refused at submit, nothing queued or recorded:** a server input whose form doesn't decode back (a hand-written `Codable` whose `init(from:)` requires a key its `encode(to:)` doesn't write) is refused `.unencodable`. The sequence counter is unchanged. Mutant: skip the submit-time decode, and it is accepted.
- **The combined case:** the same input with the land at its in-flight cap is refused `.overCap`. Mutant: decode before the cap check, and it is refused `.unencodable`.
- **Under a freeze:** the same input submitted while frozen is refused at submit. An input that decodes is held with `decoded` set, and applied at the resume. **A counting fixture** (its `init(from:)` increments a counter) shows one decode per input across freeze, resume and apply. The counter is per test, a task-local (`@TaskLocal`, as #778's `PayloadNesting.$droppedForTesting`), not a process-wide static, so parallel tests don't share it. Mutant: the resume decodes the held tree again, and the count is two.
- **`serverInputRecordFormUnchanged`:** per `ServerInputTests` fixture, the record's tree is today's `recordedForm`, byte for byte in canonical MessagePack. Two fixtures where a re-encode differs:
  - **a normalizing `Codable`:** a `@Payload` server input with a field whose type's `init(from:)` lowercases the string that its `encode(to:)` wrote verbatim. Submitted with `"ABC"`, the tree holds `"ABC"`, and the decoded value re-encodes as `"abc"`. (Rev 2's legacy-key `Codable` doesn't kill the mutant: it reads the key it writes, so the re-encode equals the tree.)
  - **an `Int??` field holding `.some(nil)`.** `@Payload` refuses optional fields (PayloadMacro.swift:116–123), and a type with `@PlainData` alone, fields but no field metadata, breaks the record schema fingerprint (SchemaFingerprint.swift:78–90). So this fixture is `@PlainData` only, declared in a recording-only unit test that is never registered: the test submits it to a keeper built directly, with no fingerprint check, and reads the recorder's entry.

  **Each fixture first asserts that the two canonical encodings differ** (the tree's and `AnyCodable(decoded)`'s), so the fixture can kill the mutant. Then the record is compared with the tree. Mutant: the recorder writes `AnyCodable(decoded)`, the typed value re-encoded, instead of the tree. Both fixtures fail. (Rev 1's mutant leaned on `Data` being `bin` in MessagePack and base64 in JSON. In the record codec, `Data` is an array of bytes, since the codec doesn't use `bin` (CanonicalMessagePack.swift:139), so that premise was wrong.)
- The existing server-input record/replay tests and goldens unchanged.

**P3c.**
- A tickless land's action reply and a tick land's ACK reach the adapter with today's values: frame goldens unchanged, and a unit test on the conversion (`.none` → `AnyCodable(())`, `.response(r)` → `AnyCodable(r)`).
- The public `invoke` and `invokeErased` return the same `AnyCodable` as on main for one action (a unit test).
- **The seam's fixture first:** `UnencodableReply` throws `UnencodableMarkerError` from the `json`, `opcodeJsonArray` and `messagepack` encoders.
- `UntypedEventPayloadTests` and `ClosedGatePendingFailureTests` on the new seam (§2.4): the same holds and outcomes as on main, with the failure detail naming `UnencodableMarkerError` where it named `UntypedPayloadError` for the response. Mutant: the marker encodes, and both fail.
- `ActionErrorReplyEncodeTests` unchanged, on `UntypedResponseAction`.
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
  - `PendingActionItem.resolverOutputs` and `PendingLifecycleItem.resolverOutputs` (public, `[String: any ResolverOutput]`, LK:208, 168) are removed. A replayed item's outputs aren't `ResolverOutput` values any more (§2.5). Their public initializers keep their parameters. `PendingAction.resolverOutputs` stays: the legacy queue has no replay path.
  - `@Payload` refuses `@PlainData` and `@SnapshotConvertible` beside it, and a generic payload that stores a parameter without `T: PlainData`.
  - A payload or resolver output can't be declared inside a function: extension macros don't attach to local types (§2.1, Local types).
- **Additive (P3a):** `@Payload` declares an extension role (`conformances: PlainData`, `names: named(_plainDataCheck)`). It makes a type `PlainData`. `LandID` is `PlainData`.
- **Unchanged (P3a):** `ReevaluationStepResult.actualState: AnyCodable?` (the monitor bridges it, §2.2). `LandContext`'s public API.
- **Behavior (P3b, P3-Q2 (a)):** a server input whose record form doesn't decode back to its type is refused at submit (`.unencodable`), where today it was accepted and failed in its turn. One that decodes to a different value is accepted, and both live and replay apply the decoded value. `ServerInputRefusal.unencodable`'s doc changes to match (§2.3).
- **None public (P3c):** `InputOutcome`, `ActionSubmission`, `awaitActionResult`, `invokeTyped` and the slots are internal or package. `handleActionEnvelope`, `AnyActionHandler.invoke` and `invokeErased` keep `-> AnyCodable`. The package init's closure type changes (`-> any ResponsePayload`).

`RecordedResolverOutput` (was `AnyCodableResolverOutput`) and `HeldResolverOutput` are package. `PendingServerInputItem` is package. `RecordedPayloadDecodeFailure` is package (K1a decides whether its record view exposes it).

## 7. Questions

| Q | Question | Options | Recommended |
|---|---|---|---|
| P3-Q1 | #616 | **Decided 2026-11-24:** closed by the maintainer; the remaining JSON walk goes with #606 | — |
| P3-Q2 | A server input whose record form doesn't decode back to its type | **Decided (a), maintainer 2026-11-24.** Refused at submit (`.unencodable`), after the cap check and before the sequence is taken (§2.3). It catches a broken hand-written `Codable` at the developer's first test, not at replay. A value that decodes to a *different* value (`Int??` holding `.some(nil)`, a normalizing `Codable`) isn't refused: live and replay both apply the decoded value, and the record keeps the tree. Option (b), accepted, recorded and failed in its turn as today, was declined | — |

## 8. What P3 leaves for K1a (cross-check with #700 §3.11)

- `PendingActionItem`, `PendingClientEventItem` and `PayloadDecodingSource`: unchanged.
- The record's entry types, `ReevaluationRecordMetadata`, `ReevaluationRecordVersion` and the log's payload form: unchanged. A server input is recorded as the tree the item kept (§2.3), not as a re-encode of its typed value.
- `InboundPayloadDecoding`'s JSON round trip: unchanged, in one place.
- `_payloadWireName`: still on every payload type. `@Payload` keeps writing it, and an `@PlainData` enum payload gets the protocol's runtime rule, as today without `@Payload`.
- The response's encode path and the record/replay of responses: K1a's (§2.4).
- `RecordedPayloadDecodeFailure`: introduced here for server inputs, with §3.11's shape plus `recordTooDeep` (§2.3), for K1a to use for actions and events.
- `HeldResolverOutput.recorded`: a tree in P3; K1b stores it as bytes (§2.5).

## 9. Revisions

**Rev 2** answers Review's NOT GO on rev 1.1. That review had 3 must-fix, 6 should and 3 nits, with a Codex track.
- **MF1** (record unchanged only by a property of types): the item keeps the `recordedForm` tree, and the record writes it. Live applies the value decoded from that tree (§2.3). The mutant's premise is fixed: `Data` is a byte array in the record codec, so the new fixtures are `Int?? = .some(nil)` and a legacy-key `Codable` (§4).
- **MF2** (the replay wrapper had no carrier past `LandContext`):
  - `HeldResolverOutput` and `RecordedResolverOutput` are named, with the path through build, the pending items (whose public `resolverOutputs` goes, §6) and `makeContext`;
  - one record projection replaces the three write sites;
  - #707's lazy read, `integralFloats` and the failed-decode warning are kept;
  - where the raw trees live after K1b (bytes) and after R2 with K5 (gone) is stated (§2.5).
- **MF3** (public `invoke`/`invokeErased` return `AnyCodable`; the DSL boxes too): the public wrappers stay, and a package `invokeTyped` is added. The two tests that answered with a dictionary move to a response whose `encode(to:)` throws, which still fails at the adapter's encode (§2.4).
- **Shoulds:**
  1. A too-deep server input throws `CanonicalMessagePackError.nestingTooDeep`. It gets its own case, `recordTooDeep`, and the test pins the type (§2.3, §4).
  2. P3-Q2's decode comes after the cap check and before the sequence. The combined case and the frozen path are pinned (§2.3, §4).
  3. The census is redone (143/141, 55/48, 126/115, 20/16, 98/96, 39/0) and agrees with Codex. Also:
     - the hand-written and plain fixtures, `RTHandWrittenAction`/`Response`, `FPPlainEvent`, `FPPlainInput`, `ENPlainEvent`, `HostHandWrittenEvent` and `PWHandWrittenEvent`, get `@PlainData`;
     - the prelude's `SnippetInput` gets `@Payload`;
     - `LandID` is a P3a dependency;
     - `DecimalAlias`'s assertion moves to snippets;
     - every replaced fixture keeps its assertion (§1, §2.2).
  4. Generic payloads: the macro diagnoses a stored parameter without the constraint, and the compiler's text is pinned for what it can't read. `WNBox<T>.InnerEvent` is a fixture. P3a follows #772 round 5's builder (§2.1).
  5. The monitor: a bridge from `ReevaluationStepResult.actualState`, and one frame pinned in three encodings. `@Payload` with `@SnapshotConvertible` is refused, and who writes `_plainDataCheck` in each landing order is stated (§2.1, §2.2).
  6. The A/B: P3c has a tick and a tickless cell with an out-of-line response. P3a gets a Mac output check, and P3b a focused submit cost check (§3).
- **Nits:**
  - the randomness sentence names K1b and L-Q2 (a), decided;
  - the lint exemption covers `_plainDataCheck` only, in `names: named(…)` of `@attached` only;
  - §2.4's inventory adds the job's completion and cancellation, `fillActionSlot` and the adapter's `Result<AnyCodable, any Error>`.

**Rev 2.1** answers Review's targeted NOT GO on rev 2 (the design's MF1–3 were closed; these are tests that wouldn't have caught their mutants):
- **MF1** (§2.4, §4 P3c): the compressed encoders bypass a `@Payload` type's `encode(to:)`, so the throw moves into a stored `@PlainData` field type, reached through the `Codable` fallback on every encoder. The fixture's error is asserted on all three encoders before the holds. The response-land assertions on `UntypedPayloadError` move to the fixture's error. `ActionErrorReplyEncodeTests` keeps `UntypedResponseAction`.
- **MF2** (§2.3, §4 P3b): the legacy-key fixture didn't kill the mutant. It is replaced by a normalizing `Codable` (lowercase on decode). The `Int??` fixture is `@PlainData` only, in a recording-only unit test, since `@Payload` refuses optionals and a fieldless-metadata type breaks the fingerprint. Each fixture asserts up front that the two encodings differ.
- **Shoulds:**
  1. The replay test builds its frame in memory, since the loader refuses deep trees. It pins state, `replayRejected` and the log text, since `applyInputs` logs and doesn't throw. The rebuilt errors are a unit test. Only `.recordTooDeep` keeps today's type. `RecordedPayloadDecodeError` returns the stored text as its description, so the log text holds (§2.3, §4).
  2. The resolver carrier: package held-form inits for the replayed action and lifecycle items, keeping `AnyCodablePayloadSource` and `decoded: nil`. The held map goes through `getAllResolverOutputs`, `completeAction` and `with(…)`. `PendingAction` keeps its public property, so the break is narrower (§2.5, §6).
  3. The freeze path: a counting fixture shows one decode per input across freeze, resume and apply, with a mutant (§4).
- **Nits:** `RecordedPayloadDecodeFailure` is `package` and an `Error`. The submit order lists the leading guards, and says that `recordedForm`'s `.unencodable` fires before `.overCap` and the new decode's after it (§2.3).
- **P3-Q2 decided (a)** by the maintainer, 2026-11-24, with its rationale (§7, §6).
- **Review's GO nits on rev 2.1** (10b4c920): P3-Q2's wording in the status line and §7; the counting fixture's counter is a task-local.
