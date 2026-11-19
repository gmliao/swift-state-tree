# Typed server events and client actions, without AnyCodable (#521)

**Status:** rev 13, for a delta review of PR 2's scope (§9.1): PR 2 adds the decode source itself, since PR 1b isn't built; #616's single check goes into the typed path without a proof type; #606's strict decode and #611 go to a PR 2c; the lookup and replay staging go to a PR 2b. Rev 12 answered review of rev 11. D14 and D15 decided (2026-11-18); PR 1f before PR 1b; the N3 scan dropped. Rev 6 reviewed GO (2026-11-13). PR 0 (#540) and PR 1a (#559) are merged. No PR 1b code before rev 8 is reviewed.
- Read at `main` 882cabe7; the cited lines are unchanged at 06125d40. Each fact is marked **checked** (read in the code or run) or **inferred** (reasoned, to be pinned by a test in the PR).
- **Rev 2** answers review of rev 1: the handler lookup (M1), record payloads (M2), non-finite numbers (M3), replay loading (M4), the replay land's registry (M5), `Sendable` (M6), `PendingActionItem` (M7), the unit for untyped events (M8), EV5's bound (M9), what a failed cycle has already sent (M10), and the shoulds. Decisions review settled are recorded as such (§10). Those left to the maintainer are D1, D7, D9, D13 and the compatibility exceptions N3, N7–N10.
- **Rev 3** answers review of rev 2:
  - the record check refuses non-finite numbers anywhere in the tree, under undeclared keys too (M3);
  - an event encode failure is a fact about the value, so D9 now recommends (b), always the land, and the per-player repeat bound is dropped under (b) (M9);
  - every registration entry point is named, with how a refusal surfaces there (§5);
  - the shoulds: N5's interim, the API table, A7's qualifier, the hybrid and compression-off nits, and N9 as one yes/no question.
- **Rev 4** answers review of rev 3, and takes #535's names (its plan, §3.6):
  - the whole-tree check runs whether or not the keeper records; `makeRecordPayload()` performs the same walk before it builds the tree;
  - the public `AnyClientEventHandler.invoke(_:event:ctx:)` keeps working, decoding through the descriptor's closure;
  - `LandFailure` (`.eventEncode`), `InTurnSyncResult.landFailed`, `LandKeeper.submitLandFailure(_:ticket:)`, close code 4016 `landFailed`, and one `LandDefinition.validateForRegistration(context:)` for both plans' checks;
  - the replay input skips (#535's R1/R2) are this plan's A5;
  - #537 and #538 are filed.
- **Rev 5** records the maintainer's decisions (2026-11-13, §10): D1 (a), D7 (a), D9 (b), D13 (b), N3 (b), N7 (settled by D13 (b)), N8 (a), N9 yes, N10 (a).
  - **D9 (b):** the text that held only under D9 (a) is gone: EV5's per-session close, its close code, and the bound.
  - **D13 (b):** `encodeAsArray()` is removed in PR 1a, with its inventory (§6.1). It also encodes action responses and outgoing actions and client events today, so those move to the writer in PR 1a (D12 is narrowed). PR 1 is split in two (§9).
  - **N3 (b):** old records holding a malformed client event fail replay. There is no version gate and no record-version step, and a scan of the cited record sets runs before PR 2 merges (§9).
- **Rev 6** answers review of rev 5:
  - the public `AnyClientEventHandler.invoke` decodes through a closure its own init captures, since it has no registry (M1);
  - the `Void` response branch is kept and pinned, and the opcode JSON empty ACK is settled by the base goldens (M2);
  - PR 1a keeps a path for events without `wireForm` at every site, so `main` stays green between 1a and 1b (M3);
  - the N3 scan has a manifest and totals, and can't report "zero rejected" with anything unscanned (M4);
  - the shoulds, and `position` on each `LandFailure` this plan builds.
- **Rev 7**, after the GO: the `Void` ACK pinned per encoding, excluded ticks reported as information, and the `docs/core/failure-handling.md` row each PR flips (§9).
- **Rev 8**, before PR 1b. It records the decision of 2026-11-18 on #521 (§10) and the drift since rev 7, read at `main` a42b481c:
  - **The decision:** the replay land re-emits recorded server events typed. It resolves each recorded name through the land definition's event registry, decodes the payload into that type and emits it with `emitEvent`. A payload that doesn't decode is a record/code mismatch: it is reported and fails fast, never forwarded. `LandContext.emitAnyServerEvent` is deleted in the same PR, with no deprecation. So land code has no way left to emit an untyped server event (N5, EV7, §4, §6).
  - **#535's mechanism is merged** (#580): `LandFailure`, `submitLandFailure`, 4016 and the loss path for an event that reaches no frame (#535 row 17). The event-encode row of `docs/core/failure-handling.md` is current (EV4). So PR 3 folds into PRs 1b and 2, as §9 already allowed.
  - **#590** (open, GO, closes #544) makes the positional encoders throw `UntypedPayloadError` instead of trapping on a value that isn't a payload type. An untyped event ends its land with `.eventEncode`; an action response that isn't a payload type ends it with `.responseEncode`. The crash EV7 and N5 kept until PR 3 is gone. Under this decision #590's refusal stays as a backstop for framework bugs only.
  - **Action responses:** #586 (#591, open) constrains a handler's result to `A.Response`. That is not in this plan's PRs.
  - **#593:** the client-event decode failure handling folds into PR 2 (A3), not PR 1b.
  - **New in the same path (checked):** the runner reads a tick's recorded events with `(try? await source.getServerEvents(for: tickId)) ?? []` (`ReevaluationRunnerImpl.swift:352`). A read error therefore looks like a tick with no recorded events. PR 1b fails the run on it (A9).
  - **Where the mismatch is reported (D14, for review):** a tick handler is non-throwing (`LandDefinition.swift:85`) and has no way to end its land. So the replay land fails the verification run through its runner service; it doesn't end itself (§4).
- **Rev 9** answers review of rev 8. These parts don't depend on D14:
  - **M2:** A9 also covers the recorded state hash. `try? await source.getStateHash(for:)` (`ReevaluationRunnerImpl.swift:332`) turns a read error into nil, and a nil recorded hash counts as a match (:338-346). Both reads now fail the run.
  - **S1:** two more silent skips in the same tick are now rows:
    - A10, the runner's snapshot encode (`try?`, :324);
    - A11, the replay land's state decode (`GenericReplayLand.swift:89-107`).
  - **S2:** the two descriptor closures get distinct names, `decodeServerEvent` (PR 1b) and `decodeClientEvent` (PR 2), and one rule: both take `any PayloadDecodingSource`. PR 1b adds the protocol and its `AnyCodable` source; PR 2 adds the MessagePack source (§2.4, §4).
  - **S4:** `requestSyncBroadcastOnly()` is listed among the steps after the events resolve.
  - **Nits:**
    - a descriptor without `decodeServerEvent` is unreachable from the DSL, and a test asserts it;
    - PR 1b is cut from `main` after #590 (85c9c297).
  - **D14:** review proposes (a′): resolve the recorded payloads in the runner's async `step()`, so the tick gets typed values and can't fail. It is with the decision-maker, together with a sub-point: decode every recorded event, or only those the policy selects. M1 (an in-flight step still queues after `failRun`) and S3 (a synchronous seam for the stale-ticket test) belong to (a) and wait for it. §4's run-failure text is (a)'s until then.
- **Rev 10** records two decisions of 2026-11-18 (§10):
  - **D14 = (a′), every recorded event decoded.** The runner resolves the tick in its async `step()`: its state, every recorded server event (not only the ones the policy selects) and the projected events. A mismatch throws a typed error, and the service's existing catch sets `.failed` under the run's ticket, so the loop stops and nothing after that tick is queued. The result carries typed values, so the replay tick can't fail (§4). This drops `consumeNextResultWithTicket`, `failRun` and the stale-ticket seam, and with them M1 and S3. A9, A10 and A11 fail in the same place, the same way. By decision, a record with any event that doesn't decode now fails even under `.projectedOnly`.
  - **D15 = a strict schema fingerprint in the record** (§4.1). A stable hash of the land's types and fields, compared before the first step; a mismatch refuses the replay. It is a record-format change: the next record minor when PR 1f merges, called **F** below (§4.1). Records without it are refused (reasoning in §4.1). It lands as **PR 1f**, its own small PR before PR 1b (§9).
  - **Found while writing it (checked):** the record-and-code check today is `validateReplayCompatibility` (`ReevaluationRunnerImpl.swift:369-396`). It compares the land type, `landDefinitionID` (the land's `id` string) and the format version. The admin replay start has its own copy (`NIOAdminRoutes.swift:708-730`), and `ReevaluationEngine.run` checks the version only (:219). SchemaGen doesn't cover server inputs (`git grep -i serverInput Sources/SwiftStateTree/SchemaGen` finds nothing), so the fingerprint adds them (§4.1).
- **Rev 11** answers review of rev 10:
  - **M1:** minor 3.5 is taken by #591 (open: `current = "3.5"`, `rejectedMinor = 5`). The plan names the fingerprint's minor **F**, whichever minor is next when PR 1f merges. If #591 lands first, its records at 3.5 have no fingerprint and are refused, and its `rejectedMinor` gating joins the follow-up issue's pre-F branches.
  - **M2:** `processResult` rebuilds the result field by field when a replay projector is registered (`ReevaluationRunnerService.swift:228-240`). It already drops `recordedPassMismatch`, an existing bug, and the default for hero-defense, and it would drop `replayFrame` too. PR 1b replaces it with a copy, `with(projectedFrame:)`, that keeps every field, and tests with a projector (§4).
  - **S1:** `as? State` is reachable. `ReevaluationTargetFactory` is public and picks the runner's `State` at run time; the GameDemo factory picks between VisibilityTest states from the environment. The service now checks the frame's state type when the result is queued (§4).
  - **S2:** the fingerprint's input is canonical (§4.1):
    - `required` lists are sorted;
    - fields are named by their wire key, not the Swift property name;
    - a type whose sample can't be built isn't fingerprinted;
    - `Set` defaults are sorted;
    - the macOS goldens are checked on Linux.
  - **S3:** §4.1 says what the fingerprint excludes, and that strict refuses additive changes too.
  - **S4:** the Public API rows are corrected and completed (§6).
  - **S5:** PR 1f updates the tests that replay pre-F records, named in §7. The replay minimum becomes F; `minimumSupported` stays for readers (§4.1).
  - **Nits:** the docs say which of 2002 and 2004 is which (§4.1). The codes 2004 and 2005 are free on main (checked: the enum ends at 2003).
  - **Q4:** review agrees to drop the N3 scan. PR 1f's body lists every record it makes unreplayable (§4.1, §9).
- **Rev 12** answers review of rev 11 (§4.1):
  - **U1:** "unbuildable" is detected where the converter fails to build a sample, not from an empty-object shape. Field-less types are empty objects too: hero-defense's `PlayAction`, `ShootEvent` and `UpgradeWeaponEvent`, VisibilityTest's `ParkEntitiesAction` (`VisibilityTestLand.swift:284`), and Demo's `IncrementAction`. So a shape check would refuse every hero-defense record, the E2E replay's included. Field-less types and the `Any` def are hashed as they are, and a test fingerprints every land in the repository.
  - **U2:** the Mirror and key limit is restated: such a change isn't seen by the fingerprint, and replay catches it only where a required field fails to decode.
  - **U3:** an unbuildable definition is refused at registration when recording or reevaluation is on, instead of logged.
  - **Nits:**
    - a `resolveEvents` frame, which has no state, fails the `State` compare for a `GenericReplayLand`;
    - two cases `@Payload`'s key list can't see are named: `CodingKeys` declared in an extension, and a custom `encode(to:)`.
- **Order (#521):** after the `@Sync` wrapper changes (#519 merged; #520 merged as #527) and a fresh profile of main (§0).
- **Error rule:** #535 and its scope decision (2026-11-13). A failure that can't be brought back to fully correct ends the smallest unit it corrupted: a session when only that session's output is wrong, the land when every recipient's output or the land's state is wrong. A type error knowable at registration is refused there. No absorb-and-continue path is added. A malformed input from a client is a client input error: the input is rejected as today, and nothing else ends.

**Correction to #521's text (checked).** `@Payload` writes the positional array in field-name order, not declaration order: `collectStoredProperties(…).sorted { $0.name < $1.name }` (`PayloadMacro.swift:49-50`), and `encodeAsArray()` follows that list (:255-268). `getFieldMetadata()` uses the same order, so the schema and the TypeScript SDK's field-order tables agree with it. The typed writer keeps this order.

## 0. Before starting: a fresh profile

The cost #521 cites (about 2.3 % of cycles in `tryCast*` frames, plus the name and boxing work) was measured before #519 and #527, which removed most of the tick's copying. Its share of the tick is now larger, and its absolute cost the same, since the event work itself didn't change (inferred).

**The measurement:** a user-only `perf record` of `cap100-local` on `main` (messagepack-pathhash, Hero Defense, cap 100, server events on), release, with call graphs. It buckets user cycles into:
- (a) the event name: `String(describing:)`, the split and the suffix drop (`EventPayload.swift:145-163`);
- (b) the boxing: `AnyCodable` allocation in `AnyServerEvent.init` and `encodeAsArray()`;
- (c) the cast chains under event encode: `MessagePackValueEncoder.box` (`MessagePackValueEncoder.swift:11-90`), `MessagePackDirectEncoder.encodeAnyCodable` (`MessagePackDirectEncoder.swift:264-340`), and the runtime's `tryCast*`/conformance lookups below them;
- (d) the rest of event encode and the 107 merge.

Action and client-event decode isn't in that cell. It is profiled once the benchmark can submit inputs from wire bytes (§8, PR 0).

**No stop rule (D1 (a), decided).** #521 gives the main reason as type information that is known at compile time and thrown away; the cost is secondary. The work goes ahead whatever the profile shows. The profile is reported, not a gate: it sets the expected size of the A/B, and is posted on #521.

## 1. Where AnyCodable sits today

### 1.1 Server events: emit to wire

| Step | Where (checked) | What it does |
|---|---|---|
| Emit | `LandContext.emitEvent` (`LandContext.swift:231-234`); `emitAnyServerEvent` (:240-242) for a pre-built event | `AnyServerEvent(event)` |
| Name | `AnyServerEvent.init(_:)` (`EventPayload.swift:135-139`), `eventName(for:)` (:145-163) | `String(describing: type(of:))`, split on `.`, drop an `Event` suffix, on every emit |
| Box | the same init, :137 | `payload = AnyCodable(event)`: the event as `Any` |
| Queue and flush | legacy: `LandKeeper.flushOutputs` (`LandKeeper.swift:480-528`), one `await transport?.sendEventToTransport` per event (:491-492); in-turn: `runSyncPhaseInTurnIsolated` (`TransportAdapter.swift:2852-2864`) | each event goes to `enqueueEventSynchronously` (:2782-2808) |
| Opcode 107 body | `encodeServerEventBody` (TA :3075) → `EncodingPipeline.encodeServerEventBody` (`EncodingPipeline.swift:122-135`) → `MessagePackTransportMessageEncoder.encodeServerEventBody` (`MessagePackTransportMessageEncoder.swift:52-63`) | builds `[AnyCodable]` (`encodeEvent`, :191-247), then converts each element with `MessagePackValueEncoder` (:283-286) |
| Positional payload | `encodePayloadAsArray` (MessagePack :251-279, opcode JSON `TransportMessageEncoder.swift:320-343`), only when the encoder's `enablePayloadCompression` is set | unwraps `payload.base`, casts it to `any PayloadCompression`, calls `encodeAsArray()` and boxes the result again. A payload type without `@Payload` reaches the default `encodeAsArray()`'s `fatalError` (EventPayload :37-41); a payload that isn't a `PayloadCompression` at all (a dictionary) reaches the encoder's own (MessagePack :273, opcode JSON :336) |
| Per field | `encodeAsArray()` (macro, `PayloadMacro.swift:243-270`) | `[AnyCodable(self.a), AnyCodable(self.b), …]`: each field boxed, its static type lost |
| Per value, MessagePack | `MessagePackValueEncoder.box` (:11-90) | 20 `as?` checks, then `as? AnyCodable` hands the field to `encodeAnyCodable` (:264-340), about 30 more cases; a struct field (`Position2`) falls through to `any Encodable` and re-enters `box` for each nested value |
| Per value, opcode JSON | `OpcodeTransportMessageEncoder.encode` (`TransportMessageEncoder.swift:127-130`) | `JSONEncoder` over `[AnyCodable]`; each `AnyCodable.encode` runs its own cast switch (`AnyCodable.swift:39-80`) |
| JSON object | `JSONTransportMessageEncoder` (`TransportMessageEncoder.swift:68-84`) | the synthesized `Codable` of `AnyServerEvent`, whose payload is `AnyCodable(event)`: one `any Encodable` hop into the event's own `Codable` |
| Type number | `encodeEvent` (MessagePack :224, opcode JSON :293) | `eventHashes?[serverEvent.type]`: a string-keyed lookup per event; a name missing from the table is sent as its string. The per-land table comes from the schema through the host configuration (`NIOLandServer.swift:60`) |
| Non-107 send | `sendEventImmediately` (TA :2946-3033) → `EventSendingPipeline.prepareImmediateSend` (`EventSendingPipeline.swift:88-`) | `messageEncoder.encode(.event(…))`: the same paths as above, one encode per event, enqueued right after its own encode (:2985, :3024) |

Each event is encoded once, before fan-out, on every path except the hybrid configs, where a body encode is tried and fails before the standalone encode (D10 removes that attempt) (checked: the 107 body is queued as a `MessagePackValue`, `EventSendingPipeline.swift:42-77`; the immediate path encodes once and enqueues the same `Data` to every session). Events are encoded **one at a time, in order**: on the immediate path and on the legacy flush, the events before a failing one have already been enqueued when it fails (checked; this bounds what EV4 can claim, §5).

**Encoders with compression off (checked).** The encoders' public inits default to `enablePayloadCompression: false` (MessagePack :32, opcode JSON :115). The host's configuration passes `shouldEncodePayloadAsArray` (`TransportEncodingConfig.swift:286`), true for `opcodeJsonArray` and `messagepack` (:56). With compression off, a payload is encoded keyed, through `AnyCodable`, and `encodeAsArray()` isn't called.

**Four copies of the name rule (checked):** `AnyClientEvent.eventName` (EventPayload :89-108), `AnyServerEvent.eventName` (:145-164), `EventRegistry.eventName(for:)` (`EventRegistry.swift:166-185`), `SchemaExtractor.generateEventID` (`SchemaExtractor.swift:235-255`). The schema's event IDs, and so its `eventHashes` (ranks of the sorted IDs, :165-180), come from the last one.

**Two copies of the action-name rule (checked):** `SchemaExtractor.generateActionID` (`SchemaExtractor.swift:210-230`) and `LandKeeper.generateActionIDForMatching` (`LandKeeper.swift:2808-`): `String(describing:)`, its last `.` component, then an `Action` suffix dropped (a type named `Action` gives the empty ID).

### 1.2 Client actions: wire to handler

| Step | Where (checked) | What it does |
|---|---|---|
| Wire, MessagePack | `MessagePackDirectDecoder` opcode 101 (`MessagePackDirectDecoder.swift:81-89`), `decodeAnyCodable(from:)` (:485-524) | the payload `MessagePackValue` becomes a tree of `Any` in an `AnyCodable`. It throws on a map key that isn't a string, at any depth (:513-516); that rejects the frame |
| Wire, opcode JSON | `TransportMessageDecoder.decodeAction` (`TransportMessageDecoder.swift:121-152`) | `JSONSerialization` tree wrapped in `AnyCodable`; an array payload is accepted here as an array |
| Wire, JSON object | `ActionEnvelope`'s `Codable` (`TransportMessage.swift:4-12`) | `AnyCodable.init(from:)` (`AnyCodable.swift:15-37`) |
| Handler match | `LandKeeper.submit` (`LandKeeper.swift:2683-2711`) | a linear scan of the land's handlers in declaration order. Handler `h` matches input `x` when any of four predicates holds: (1) `name(h) == x`, where `name` is `String(describing:)`; (2) `last(name(h)) == last(x)`, where `last` is the last non-empty `.` component (`split` drops empty pieces, so `AddGoldAction.` matches); (3) `sid(h) == x`, the schema ID; (4) `sid(h).lowercased() == x.lowercased()`, on the whole input. The first handler that matches wins. So `X.AddGold` and `x.addgold` match nothing, `addgold` matches by (4), and `addgoldaction` matches nothing |
| Replay match | `LandKeeper.swift:4110-4124` | predicates (1) and (2) only, against the record's `typeIdentifier`, which is `String(describing: actionType)` (:3437) |
| Decode at intake | `LandKeeper.swift:2719-2721` | `JSONEncoder().encode(envelope.payload)`, then `JSONDecoder().decode(actionType, from:)`: a JSON round trip. `JSONEncoder` encodes the **whole** tree and refuses NaN and ±∞, so a non-finite MessagePack number is rejected here at any depth, also under a key the type doesn't declare (`{valid: 1, ignored: NaN}` is refused) |
| Queue | `PendingActionItem` (`LandKeeper.swift:189-218`), public with a public non-throwing init; rebuilt at :1910, :2074 (resolver completion), :2748, :2767 (intake) and :4154 (replay) | keeps `action: AnyCodable` (the wire tree), not the decoded value. The decoded value goes to the resolver job separately (`decodedAction`, :2758) |
| Decode at apply | `LandKeeper.swift:3412-3415` | the same round trip again, inside the turn |
| Record | `ReevaluationRecordedAction` (`ActionRecorder.swift:652-`), built at `LandKeeper.swift:3434-3445` on every apply, whether or not the keeper records | `payload: actionItem.action`: the wire tree as received |

**Clients send action payloads as objects (checked).** The TypeScript SDK writes `[101, requestID, typeIdentifier, payload(object)]` (`sdk/ts/src/core/protocol.ts:156-166`). Its `actionFieldOrder` table is filled from the schema but not used to send. An array payload reaches the keeper as an array and fails the round trip's keyed decode (inferred; pinned by a test, §7).

### 1.3 Client events: wire to handler

- Wire: as actions (opcode 103), into `AnyClientEvent.payload: AnyCodable` (MessagePack :103-115, opcode JSON :174-230). Checked.
- Intake: `handleClientEvent` (`LandKeeper.swift:2850-`) looks up the descriptor by name (a dictionary) and queues the `AnyClientEvent` undecoded.
- Apply: the event is recorded before its handlers run (`LandKeeper.swift:3487-3498`). `AnyClientEventHandler` (`LandDefinition.swift:273-279`) then runs the JSON round trip with `try?`. **A payload that doesn't decode silently skips the handler**: no error to the client, no log, and the event stays recorded (checked). That is an absorb path under #535's rule.

### 1.4 Other consumers of the boxed payload

| Consumer | Where (checked) | Needs |
|---|---|---|
| Server event records | `LandKeeper.swift:495-505`, `ReevaluationRecordedServerEvent` (`ActionRecorder.swift:744`) | `payload: AnyCodable` of the event, written to the record as the event's keyed JSON |
| Replay comparison | `ReevaluationEngine.serverEventsMatch` (`ReevaluationEngine.swift:389-410`) | sorted-key JSON of recorded vs emitted payloads. An encode failure becomes `Data()` on both sides, so two unencodable payloads compare equal |
| Replay input loading | `LandKeeper.swift:4099-4256` | a recorded action whose type has no handler, or whose handler type isn't an `ActionPayload`, is logged and skipped (`continue`, :4126-4139). Any error while loading the tick's inputs is logged and the tick runs without them (:4251-4256). Unknown server inputs and lifecycle kinds, by contrast, fail the tick (`recordedPassMismatches`, :4189-4194, :4217-4222) |
| Replay land | `GenericReplayLand.makeLand` (`GenericReplayLand.swift:47-70`) | a new `Land` with the base's ID, access control and tick; **no `ServerEvents` registry** |
| Replay re-emit (until PR 1b; §4 has the typed re-emit) | `GenericReplayLand` (:126-129) → `emitAnyServerEvent` | `AnyServerEvent(type:payload:)` from a result. With `replayEventPolicy: .projectedWithFallback` (public, `ReevaluationFeature.swift:8-27`; the examples use `.projectedOnly`), a tick that emitted no events re-emits the recorded ones (`selectReplayEventsToEmit`, :11-24). Those come from the record source (`ReevaluationRunnerImpl.swift:306`), so the payload is a decoded dictionary. On a compressed encoding it reaches `encodePayloadAsArray`'s `fatalError` (inferred; pinned by a red exit test, §7) |
| Sync-stream digest | `TransportAdapter.canonicalEvent` (:3988-3992), `SyncOutputVerifier.addEvents` (`SyncOutputVerifier.swift:292-299`) | `SnapshotValue.make(from: payload.base)`, only when the keeper records the sync stream |
| Schema | `SchemaExtractor.swift:106-143` | event types and names only; no payload values |

**Not in this plan** (they use `AnyCodable` for other reasons): server inputs (#387, `ServerInput.swift`), resolver outputs, join metadata, error details, admin and monitor DTOs. Action responses (`LandDSL.swift:872/916/943`, `TransportActionResponsePayload`) stay boxed in `AnyCodable` up to the encoder (D12). On the compressed encodings, though, their payload is written through `encodePayloadAsArray`, which D13 (b) removes, so that **encode step** moves to the writer in PR 1a (§6.1).

## 2. The typed design

### 2.1 A static wire name per payload type

`@Payload` emits the name the schema uses, computed at expansion from the struct's name:

```swift
public static let _payloadWireName: String = "PlayerShoot"
```

- **The rule, per protocol the type conforms to:**
  - **Events** (`ServerEventPayload`, `ClientEventPayload`): `generateEventID`'s rule, the name with an `Event` suffix dropped.
  - **Actions** (`ActionPayload`): `generateActionID`'s rule, the name with an `Action` suffix dropped, including to the empty string for a type named `Action`.
  - The macro sees the conformance list. When it can't tell (the conformance is added in an extension), it emits the computed form below.
- **Generic types, nested-in-generic types, and unknown conformance** take a computed static that calls the runtime rule (`EventRegistry.eventName(for: Self.self)`, or the action rule), with the lexical-context predicate #527 introduced for `_syncPolicy_` (`2026-11-12-sync-policy-per-type.md` §3). No generic payload type exists outside tests (inferred; checked in the PR).
- **`AnyServerEvent.init(_:)`** and `AnyClientEvent.init(_:)` read `E._payloadWireName` instead of deriving the name.
- **One derivation per kind left.** The two private copies in `EventPayload.swift` are removed. `EventRegistry.eventName(for:)` stays as the runtime event rule, and one shared function replaces the two copies of the action rule (`generateActionIDForMatching` calls it).
- **Checked at registration (EV2):** for each registered event and action type, `_payloadWireName` equals the schema's ID.

### 2.2 A typed field writer

The macro emits a writer in place of `encodeAsArray()` (removed, D13 (b)), fields in the same name-sorted order:

```swift
public func _writePayloadFields<W: _PayloadFieldWriter>(into w: inout W) throws {
    try w.field(self.from)
    try w.field(self.playerID)
    try w.field(self.to)
}
public static var _payloadHasTypedWriter: Bool { true }
```

**Two overloads, resolved at compile time** (in a protocol extension of `_PayloadFieldWriter`, so the macro's call site picks one per field from the field's static type):
- `field<T: _PayloadWireLeaf>(_ v: T)` forwards to the writer's `leaf(_:)` requirement: the typed form.
- `field<T: Encodable>(_ v: T)` forwards to the writer's `fallback(_:)` requirement. The fallback runs **today's per-field path verbatim**: `encodeAnyCodable(AnyCodable(v))` for MessagePack, `container.encode(AnyCodable(v))` for JSON. So a fallback field's bytes equal today's by construction, quirks included (a top-level `Decimal` is a MessagePack double today and a nested one a string; the fallback keeps both).

**The leaf protocol.** Core can't name `MessagePackValue` (`SwiftStateTreeMessagePack` depends on core), so a leaf writes itself through primitives:

```swift
public protocol _PayloadWireLeaf: Encodable {
    func _writeWire<P: _PayloadPrimitiveWriter>(into p: inout P)
}
// _PayloadPrimitiveWriter: int(Int64), uint(UInt64), bool, float, double, string,
// and object(count:) followed by key(String) and a value per entry, keys in byte order.
```

- The MessagePack writer's `leaf` runs `_writeWire` into a primitive writer that builds the `MessagePackValue`.
- The JSON adapter's `leaf` is `container.encode(v)`. That is what today's `AnyCodable.encode` does for each leaf type (a native scalar, or `any Encodable` into the type's own `Codable`), so a leaf's JSON bytes are unchanged without a second form.

**The rule for a type without a typed form (D5, settled (a)):**
- **Typed leaves:** `Bool`; `Int`, `Int8`–`Int64`; `UInt`, `UInt8`–`UInt64`; `Float`; `Double`; `String`; `PlayerID`, `ClientID`, `SessionID`, `LandID`; and, in `SwiftStateTreeDeterministicMath`, `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle`. These are the `SyncLeafWritable` types plus `Float` and the unsigned types. Each leaf writes exactly the MessagePack value today's top-level path gives that type. That is `encodeAnyCodable`'s case for scalars and IDs, and the `Codable` form for the math types (`Position2` → `{"v": {"x": Int32, "y": Int32}}`, `Angle` → `{"degrees": Int32}`).
- **The `SyncLeafWritable` conversions aren't reused as they are.** Their target is `SnapshotValue`, whose forms differ from the wire's for `Float` (widened to double) and for `UInt`/`UInt64` above `Int.max` (decimal strings). The leaves share their structure: one conformance file per module, as `SyncLeafWritable+DeterministicMath.swift`.
- **Everything else is a fallback field:** arrays, dictionaries, optionals (which `@Payload` refuses anyway, :109-116), nested structs, `AnyCodable`, `Date`, `Data`, `Decimal`, enums. Typed arrays of leaves are a later extension.
- **Visible, not silent.** The macro also emits `static let _payloadFieldForms: [_PayloadFieldForm]`. It is built from the same two overloads (`_payloadFieldForm(of: T.self)` → `.typed` / `.codable`), so it can't disagree with the writer. Land registration logs each registered payload type's fallback fields once, at info level. A test pins the list for every payload type in the repository (§7). The choice is per declared field type, fixed at compile time, never per message.

**In the repository today (checked):** the Hero Defense events and client events are all typed (`PlayerID`, `Int`, `Position2`, `Angle`). The reevaluation monitor's events have fallback fields: `expectedState`/`actualState: AnyCodable` and `mismatches: [TickMismatch]` (`ReevaluationMonitorEvents.swift:37-38, 63-64, 102`).

**The macro's declared names.** `@Payload`'s `@attached(member, names: …)` (`StateTreeBuilder.swift:84`) lists `getFieldMetadata`, `getResponseType` and `encodeAsArray`. It gains `named(_payloadWireName)`, `named(_payloadHasTypedWriter)`, `named(_writePayloadFields)` and `named(_payloadFieldForms)`.

### 2.3 How it reaches each encoding

The typed path is taken when the encoder's own `enablePayloadCompression` is set, the same condition as today's positional path. With it off, today's keyed path runs unchanged (N10 (a)). The same writer serves every positional payload the encoders write: server events (below), and action responses, actions and client events (§6.1).

| Encoding | Today | Typed |
|---|---|---|
| `messagepack` (the default config), and the 107 body | `[AnyCodable]` → `MessagePackValueEncoder` per element (§1.1) | A `_PayloadFieldWriter` that appends `MessagePackValue`s: the body is `.array([.int(1), typeValue, .array(fields)])`, as `encodeServerEventBody` builds it after `dropFirst()`. `rawBody` is nil for a typed event. A standalone frame packs `[103, 1, typeValue, fields]`. Building bytes directly, without `MessagePackValue`, is a later step |
| `opcodeJsonArray` | `JSONEncoder` over `[AnyCodable]` | `JSONEncoder` over the same outer array, whose payload element is a typed `Encodable` wrapper: its `encode(to:)` opens an unkeyed container and runs the macro's writer through an adapter (`field` → `container.encode(v)` for a leaf, `container.encode(AnyCodable(v))` for a fallback) (D6, settled (a)) |
| `json` (object) | `JSONEncoder` of the whole `TransportMessage`; the payload is `AnyCodable(event)` → the event's synthesized `Codable` | unchanged, except the static name. This is the debugging encoding; the boxing here is one existential hop |
| 107 merged frame | the queued bodies (`PendingEventManager`) are merged into the frame by `EncodingPipeline` (:78, :107) | unchanged: it merges the typed bodies |
| Hybrid (`message: json/opcodeJsonArray`, `stateUpdate: opcodeMessagePack`) | every event first tries a body (JSON bytes unpacked as MessagePack, which fails), then is sent alone (TA :2794-2804) | decided once at adapter init: in a hybrid config every event is sent alone, as today's bytes show, and no body is attempted (D10, settled (a)). The per-event `.sentAlone` outcome goes away |

**`AnyServerEvent` carries the typed form (D3, settled (a)).** `init<E: ServerEventPayload>(_:)` stores, beside `payload`, a package-level `wireForm: (any ServerEventPayload)?`, the same event value, set when `E._payloadHasTypedWriter` is true. `ServerEventPayload` is `Sendable` (`EventPayload.swift:13`); `PayloadCompression` isn't, so it can't be the stored type in the `Sendable` `AnyServerEvent`. The encoders use `wireForm` when it is present. `AnyServerEvent(type:payload:)`, the hand-built and replay form, has none; it is resolved once at emit (§4, replay re-emit).

**Payloads without `wireForm`, in PR 1a (M3).** Every positional site keeps a path for a payload that isn't carried typed: it unwraps `AnyCodable.base`, casts it to `any PayloadCompression`, and calls `_writePayloadFields`. That is today's `encodePayloadAsArray` with the writer in place of `encodeAsArray()`. It covers the encoder tests that build `AnyServerEvent(type:payload:)` from a concrete value (`TransportMessageEncoderTests.swift:108-126`), action responses (`AnyCodable(result)`, `LandDSL.swift:872-`), and outgoing actions and client events. A dictionary payload still reaches today's `fatalError` there; resolving it through the registry (N5) is PR 1b's. Without this path, `main` would be red between 1a and 1b.

**The `Void` payload (M2).** MessagePack's `encodePayloadAsArray` writes `Void` as `[]` before the cast (`MessagePackTransportMessageEncoder.swift:261-264`). It is reached by the immediate ACK of an action queued for a tick, `.completed(AnyCodable(()))` (`LandKeeper.swift:2799-2801` → TA :5886-5907). The branch is kept as it is, and the `Void` response is in the base goldens. Opcode JSON's version has no such branch (`TransportMessageEncoder.swift:320-339`): the response goes through it (:192), `()` isn't a `PayloadCompression`, and the cast's `fatalError` (:334-336) runs, so an empty ACK on compressed opcode JSON traps today (checked by reading; to be confirmed by the exit test (§7)). It is reported and filed as its own issue, and any fix is named there, not made under byte identity. So the pins differ per encoding (§7).

**The type number** stays a dictionary lookup by the static name. An `ObjectIdentifier`-keyed table per adapter is a follow-up if the profile shows the lookup.

### 2.4 Typed action decode

**A decode source instead of an `Any` tree.** A core protocol:

```swift
package protocol PayloadDecodingSource: Sendable {
    func decode<T: Decodable>(_ type: T.Type) throws -> T
    /// Today's `AnyCodable` tree of the payload, for records. Runs the same whole-tree
    /// walk as `validateRecordable()` first, so it throws wherever that throws.
    func makeRecordPayload() throws -> AnyCodable
    /// Checks, without building the tree, that today's intake would accept the whole tree:
    /// string map keys and finite numbers at every depth, declared fields or not.
    func validateRecordable() throws
}
```

`ActionEnvelope` and `AnyClientEvent` gain a package-level `source`. Their public `payload` stays readable, as a computed property (§6), and their `Codable` forms are unchanged (the source is excluded).
- **MessagePack** (the default): the payload's `MessagePackValue`, decoded with `MessagePackValueDecoder`. No `Any` tree, no JSON.
- **Opcode JSON and JSON object:** today's semantics, unchanged: the source holds the `AnyCodable` tree and decodes it with today's round trip. The accepted inputs are then identical by construction on the JSON encodings. `makeRecordPayload()` returns the tree and can't throw.
- **Hand-built envelopes** (tests, benchmarks, `ActionEnvelope(typeIdentifier:payload:)`): an `AnyCodable` source, as above.

**What intake accepts, on MessagePack (M2, M3).** Today, MessagePack acceptance is the intersection of two steps: `decodeAnyCodable` (string map keys, at any depth) and the JSON round trip (which refuses non-finite numbers, among others). The typed decode must not accept more than that by accident:
- **The whole payload tree is validated at intake, before a sequence is taken.** `validateRecordable()` walks every value, including those under keys the type doesn't declare, and refuses what today's two steps refuse: a map key that isn't a string (`decodeAnyCodable`), and NaN or ±∞ as a float or double (`JSONEncoder` over the whole tree). It runs on every MessagePack input, whether or not the keeper records, so what is accepted doesn't depend on recording. When the keeper records, `makeRecordPayload()` runs at intake instead, and the tree rides on the pending item. `makeRecordPayload()` isn't today's `decodeAnyCodable` alone: that wraps floats and doubles without a finite check (`MessagePackDirectDecoder.swift:501-504`). It runs the same walk first, then builds the tree, so both branches refuse the same inputs. A failure rejects the input, as A2. Nothing can throw at apply.
- **Non-finite numbers are refused anywhere (M3).** Today's round trip refuses them wherever they sit, since `JSONEncoder`'s default `nonConformingFloatEncodingStrategy` is `.throw` and it encodes the whole tree before the typed decode reads the declared fields. The whole-tree walk above reproduces that, so the typed decoder needs no rule of its own, and `MessagePackValueDecoder`'s other uses don't change. It keeps today's behavior, so it isn't an exception.
- **The other differences** (an integral float into an integer field, a binary value into a `String` field, duplicate map keys, extra keys) are listed by the differential test, in both directions: what today accepts and the typed decode refuses, and the reverse. Each one is named in the PR (N1, D7).

**Decode once (M7).** The intake decodes (`LandKeeper.swift:2719-2721`, from the source), and the pending item keeps the decoded value. The apply step (:3412-3415) calls `invokeErased` with it. Live mode decodes nothing inside the turn.
- `PendingActionItem` gains package-level `decoded: (any ActionPayload)?` and `source: (any PayloadDecodingSource)?`. **The public init stays**, non-throwing and unchanged: it sets `decoded` to nil and wraps `action` in an `AnyCodable` source. An item from the public init is decoded at apply, with today's round trip, as now.
- **A package init** takes the decoded value, the source and the record payload. The intake sites (:2748, :2767) use it.
- **A package copy,** `with(resolverOutputs:resolvedAtTick:)`, carries `decoded`, `source` and the record payload across the rebuild sites: resolver completion (:2074) and delivery (:1910). Replay (:4154) uses the package init with the value decoded when the tick's inputs are staged (§4).
- `startActionJob`'s separate `decodedAction` parameter goes away: the job reads `decoded` from its item.

**A handler lookup with today's predicates (M1).** Three indexes, built at land definition, one per predicate shape, each keyed by exactly what its predicate compares:

| Index | Key, per handler | Looked up with |
|---|---|---|
| exact | `name(h)` and `sid(h)` | the whole input |
| basename | `last(name(h))` | `last(input)`, the last non-empty `.` component, with `split`'s rules |
| lowercased schema ID | `sid(h).lowercased()` | `input.lowercased()`, the whole input |

- The lookup tries the three and returns the hit. It accepts exactly the inputs today's scan accepts: `X.AddGold`, `x.addgold` and `addgoldaction` match nothing, as today; `AddGoldAction.` and `addgold` match, as today.
- **Collisions are refused at registration (A4).** Today's scan returns the first handler, in declaration order, for which any predicate holds. The indexes reproduce that only if no input matches two handlers. Every predicate implies that the input's lowercased last component equals the lowercased last component of `name(h)` or of `sid(h)`. So two handlers whose sets {lower(last(name)), lower(last(sid))} intersect are refused, and with none refused, no input can match two. The test is also exact: for a shared folded name, an input built from it matches both handlers, so a refused land is one where today's declaration order decides which handler runs (N9; the generated-pairs test checks both directions).
- **An unvalidated definition keeps today's scan.** The land builder can't throw, so it records when its indexes are ambiguous. A keeper whose definition wasn't validated (§5, entry points) then looks handlers up with today's scan, so it behaves as today.
- **Replay keeps its own two predicates.** A recorded action is matched with the exact and basename indexes only, on `name(h)`, as :4110-4124 does today.
- **Erased handlers are validated at registration.** Each action handler's `getActionType()` must be an `ActionPayload` type, and each client-event handler's type must match its registry descriptor. Today the first check runs per input (:2715-2717, `actionNotRegistered`) and in replay (:4133-4139, a skip). It becomes a registration refusal (A8). The per-input check stays as an invariant (A7).

**Client events (D2, settled (a))** take the same source and decode, at intake, through a decode closure the registry captures at `Register<E>`: `AnyEventDescriptor` (`EventRegistry.swift:6`) gains a package-level `decodeClientEvent: @Sendable (any PayloadDecodingSource) throws -> any ClientEventPayload` (PR 2; the server-event closure is `decodeServerEvent`, PR 1b, §4). The handler receives the typed value. A payload that doesn't decode is rejected at intake with an error to the client, as for an action. Today it is silently skipped at apply (§1.3).

**Records are built only when something reads them.** Today the action and client-event records are built on every apply (:3434-3445, :3488-3498), recording or not. They are built when the keeper has a recorder or runs in reevaluation mode, from the record payload made at intake. `appliedOrder` is kept either way, since the tickless pass record and the turn's emptiness use it (:3751-3753, :5007).

**Not in this plan: a positional action wire form (D11, settled (a)).** #521 suggests a typed positional decoder for actions, but clients send objects (§1.2). A positional form would be a new wire form with an SDK change.

## 3. The byte-identity contract

**Holds** for every registered payload type, in every encoding, for every value, when nothing fails (§5):
- **Event frames:** the 107 bodies, the standalone event frames, and the merged frames are byte-identical to today's, per session. Field order is the same name-sorted list; leaves write today's top-level values; fallback fields run today's path.
- **Event names and numbers:** the static name equals today's derived name for every type (pinned, and checked at registration). The numbers come from the same schema table.
- **Schema:** `SchemaGen` output is unchanged (no change to metadata or IDs). Each example's output is byte-identical, base against head, with its sha256 recorded. Records carry the schema hash, so a change would also show there.
- **Records:**
  - Server event records: unchanged (`payload` is still the event).
  - Action and client-event records, **for the inputs this change still accepts:** unchanged. The record payload is today's tree: for MessagePack, `makeRecordPayload()` is today's `decodeAnyCodable(from:)` of the same value, so the record JSON is the same (D8, settled (a)). A malformed client event is rejected at intake (N2), so it is no longer in a new record at all; record identity covers accepted inputs only.
- **Actions:** the same handler is chosen for every ID, when no handlers collide (§2.4). On the JSON encodings, the same inputs are accepted and decode to the same values. On MessagePack, non-finite numbers and non-string keys are refused as today.

**Can't hold, by design (named, each pinned).** N1, N2, N4, N5 and N6 follow from the rule or from review's settled decisions. N3 and N7–N10 are compatibility exceptions the maintainer decided (§10).
- **(N1) MessagePack action and client-event decode differs where the differential finds it (D7).** `MessagePackValueDecoder` is exact. It refuses an integer field sent as a float (`decodeInteger` takes only `.int`/`.uint`, `MessagePackValueDecoder.swift:431-445`). Today's round trip can accept such an input, depending on how `JSONEncoder` writes the double (inferred). The TypeScript SDK sends integers as MessagePack integers, so SDK clients are unaffected (inferred, pinned by the E2E). Every difference, in either direction, is listed by the differential test (§7) and named in the PR.
- **(N2) A malformed client event is rejected with an error,** and not recorded. Today it is accepted, recorded and silently not applied (§1.3).
- **(N3) Records written before this change that hold a malformed client event fail replay (N3 (b)).** The staged batch (§4) refuses the event as any undecodable recorded input: the tick fails and the run stops failed, with the sequence and type. No version gate. A new record never holds one, since intake rejects it (N2). Since rev 11, D15 refuses every record from before PR 1f at replay, so this case can't be reached by replay, and the scan is dropped (§4.1).
- **(N4) Types that crash today are refused instead** (EV1 for a type without the writer). Today the process hits `fatalError` at that type's first send.
- **(N5) The replay land re-emits recorded server events typed** (the decision on #521, 2026-11-18). Each recorded name is resolved through the base land's registry, its payload is decoded into that type, and the event goes out through `emitEvent`. So its frame is byte-identical to the live one on every encoding (§4). Before #590, a recorded dictionary reached the positional encoders' `fatalError`; with #590 it ends the replay land with `.eventEncode`. An unregistered name or a payload that doesn't decode is a record/code mismatch (EV7): the run fails with the reason, and nothing of that tick is sent.
- **(N6) The failure outputs** change as §5 says.
- **(N7) A hand-written `encodeAsArray()` (settled by D13 (b)).** The protocol requirement is gone, so such a method is an unused method of the type. A type without the writer is refused at registration where EV1 applies; the refusal names the fix: add `@Payload`, or implement both `_writePayloadFields(into:)` and `static var _payloadHasTypedWriter: Bool { true }` (the default is `false`, so a writer alone is still refused).
- **(N8) A registered event missing from the host's `eventHashes` (EV3, N8 (a)).** Today it is sent with its string name, which a client built from that schema doesn't know. Under this plan it is refused at registration.
- **(N9) Lands that are ambiguous today (A4, N9 yes).** Two handlers that some input matches both are refused at registration. Today the first in declaration order wins.
- **(N10) Encoders built with compression off (N10 (a)).** Their events keep today's keyed `AnyCodable` path; nothing in them is typed. EV1 applies only where the encoder in use has compression on.

## 4. Replay and reevaluation

- **Recording:** unchanged on all three input kinds (§3). Server events keep `payload = AnyCodable(event)`. Actions and client events record the tree made at intake (§2.4).
- **Replay input loading: a per-tick staged batch (M4).** Today the loader skips an action without a handler, or whose type isn't an `ActionPayload` (:4126-4139). It also logs and swallows any load error, so the tick runs with inputs missing (:4251-4256). Under this plan:
  - **Fetch:** the tick's records are read from the source, with the awaits as today.
  - **Stage:** after the last await, in one synchronous segment, every recorded input of the tick is matched (§2.4, replay predicates) and decoded through an `AnyCodable` source, which is today's semantics, into a staging list. Nothing is appended to `pendingItems` yet.
  - **Commit:** only when every input staged does the list go into `pendingItems`.
  - **Owner:** this plan's A5 owns those two skips (#535's sweep calls them R1/R2); #535's plan drops its own PR for them.
  - **A failure is terminal for the run:** an unmatched type, a non-`ActionPayload` handler, a payload that doesn't decode, or a source read that throws. The tick fails with the reason in `recordedPassMismatches`, as unknown server inputs do today, and the run stops with a failed verdict. Later ticks would run on a state missing those inputs, so their comparisons can't mean anything.
  - **No exception for old records** (N3 (b)): a recorded client event that doesn't decode fails the tick and the run like any other input.
- **`serverEventsMatch`:** compares as today, sorted-key JSON of both payloads. Under #535's rule, an encode failure on either side is a mismatch with its error as the reason, not `Data()` on both sides (§1.4).
- **The replay land's event registry (M5).** `GenericReplayLand.makeLand(basedOn:)` copies the base definition's server-event descriptors into the replay land's `serverEventRegistry`, through a package-level hook on the land builder. So the replay land registers the same event types, names and decode closures as the base.
  - **Registration checks EV1–EV3** run on the replay land as on any land. Its registry equals the base's, and `registerWithGenericReplay` gives it the live land's configuration and `eventHashes` (`ReevaluationFeature.swift:225-250`). So it passes exactly when the base did. `makeLand` called on its own is checked against the configuration it is registered with.
- **The decode closure (S2).** Each server-event descriptor gains a package `decodeServerEvent: @Sendable (any PayloadDecodingSource) throws -> any ServerEventPayload`. It follows the same rule as the client-event closure of PR 2, `decodeClientEvent` (§2.4): both decode through a `PayloadDecodingSource`.
  - **What PR 1b adds:** the protocol and its `AnyCodable` source, today's JSON semantics, the one a record's payload needs. PR 2 adds the MessagePack source and the client-event closure.
  - **How it is built:** the builder registers server events through `registerErased(_:)` with an `Any.Type` (`LandBuilder.swift:149`). So the closure is made by opening the type as `any ServerEventPayload.Type` and calling a generic helper. A type that doesn't open isn't a server event and gets no closure; on a compressed encoding, EV1 already refuses it.
  - **The `AnyCodable` source for `E`:**
    - a payload whose base is already `E` is taken as is, with no round trip; the projected events of an in-process run hold the typed value (`LandKeeper.swift:521-546`);
    - otherwise it encodes the payload with `JSONEncoder` and decodes `E` with `JSONDecoder`. A record's payload is the event's own JSON, so this is the record's semantics.
  - **Pinned:** the frames this gives are byte-identical to the live ones (§7). Any type for which they differ is named in the PR as an N item.
- **Resolving in the runner's `step()` (D14 (a′)).** `ConcreteReevaluationRunner.step()` already reads the record (the hash at :332, the events at :352) in its async body. After those reads it resolves the tick, through one public throwing function, `ReevaluationReplayFrame.resolve(...)`. Custom runners call the same function (the repository's test fakes do).
  - **Events:** every recorded server event, and every projected one, is looked up by `typeIdentifier` in the base definition's registry (the runner's keeper holds the definition, `LandKeeper.swift:290`). Its payload goes through that descriptor's `decodeServerEvent`, with an `AnyCodable` source. A projected event already holds its typed value, so it is taken without a round trip. Every recorded event is decoded, not only the ones the policy would select (the decision): a record that holds one that doesn't decode fails under `.projectedOnly` too.
  - **State:** the snapshot of the runner's state is encoded (A10) and then built back as `State(fromBroadcastSnapshot:)` (A11), in `step()`.
    - The runner is generic over `StateNodeProtocol`, and `GenericReplayLand` needs `StateFromSnapshotDecodable`. So the runner opens `State.self as? any StateFromSnapshotDecodable.Type`, a cast on a metatype, not on data, and calls the generic resolver.
    - A state type that doesn't conform has no replay land (`GenericReplayLand<State: StateFromSnapshotDecodable>`), so its frame carries the events and no state.
  - **A mismatch throws** `ReevaluationReplayResolutionError`, with the tick, the event's sequence and name, and the decode error; for A9–A11 it names the read, the encode or the state decode instead.
    - It leaves `step()` and reaches the service's existing catch (`ReevaluationRunnerService.swift:166-172`). That catch sets `phase = .failed` and `errorMessage` under the run's ticket, and the loop ends.
    - Nothing after that tick is queued, and the tick itself isn't queued either.
    - The replay land stays up and gets no further results. The admin status reports the failed run and its reason.
  - **The result carries the frame:** `ReevaluationStepResult` gains a public optional `replayFrame: ReevaluationReplayFrame?`. The frame's stored members are package:
    - the resolved recorded events and the resolved projected events, each with its target;
    - the decoded state, in a package box.
- **Replay re-emit (typed); the tick can't fail.** The tick takes the frame and does three things, in this order (S4):
  1. it sets `state` to the frame's state;
  2. it calls `ctx.requestSyncBroadcastOnly()`;
  3. it emits each event `selectReplayEventsToEmit` picks from the frame's resolved lists with `ctx.emitEvent(_:to:)`, in record order, each with its target.
  - **The state box, checked when queued (S1).** The runner's `State` is chosen at run time by a public `ReevaluationTargetFactory`; the GameDemo factory picks between the VisibilityTest states from the environment. So it can differ from the replay land's `State`.
    - The frame records `ObjectIdentifier(State.self)` and the type's name.
    - `registerWithGenericReplay<State>` gives the service the replay land's expected `ObjectIdentifier`.
    - `processResult` compares the two under the lock, before it queues. A mismatch fails the run with "runner state X, replay land Y" and queues nothing.
    - So the land's `as? State` can't fail for a queued result. A test asserts that, and another asserts the queue-time refusal with a factory that returns the other VisibilityTest state.
  - **A result without a frame,** from a custom runner that didn't resolve, is refused by the same queue-time check: the run fails with "result not resolved", and the land never sees one. A frame from `resolveEvents` carries no state, so it fails the `State` compare for a `GenericReplayLand` the same way.
  - **The projector copy (M2).** With a replay projector registered, `processResult` builds a new `ReevaluationStepResult` field by field (`ReevaluationRunnerService.swift:228-240`). That already drops `recordedPassMismatch`, so with a projector a tick whose passes didn't match falls back to the recorded events, which `selectReplayEventsToEmit` exists to prevent. It would drop `replayFrame` too. PR 1b replaces it with `ReevaluationStepResult.with(projectedFrame:)`, a copy that keeps every other field. A test runs with a projector and checks both fields survive.
- **Every replay entry point fails the same way:**
  - the admin replay start: the record's fingerprint, before a land exists (§4.1);
  - the runner: the fingerprint before the first step, then the frame in each `step()`;
  - `ReevaluationEngine.run`: the fingerprint, and the same frame resolution for the events it compares.
- **`emitAnyServerEvent` is removed** in PR 1b (§6). Its only caller is the replay land (checked: `git grep emitAnyServerEvent` at a42b481c finds `LandContext.swift:240` and `GenericReplayLand.swift:129`).
- **Sync-stream digests** (`canonicalEvent`, `SyncOutputVerifier.addEvents`): unchanged. They read `payload.base`, which is still the event.

### 4.1 The record's schema fingerprint (D15, PR 1f)

**Why.** Today a record is checked against the code by land type, `landDefinitionID` and format version only (`ReevaluationRunnerImpl.swift:369-396`). `landDefinitionID` is the land's `id` string, not its shape. So a change to an event's, an action's or the state's fields passes the check, and the replay then fails partway through, or passes on a meaning that changed. The fingerprint refuses such a record before the first step. The per-event decode of D14 stays as the last guard, for framework bugs and corrupt records.

**What it hashes.** It is derived from the source SchemaGen uses, and its input is made canonical, so it is deterministic across processes and platforms:
- **The schema:** the land's `ProtocolSchema` from `SchemaExtractor.extract(from:)` for the definition, with a fixed version string. That covers the state tree (the types, the fields, their sync policies and their default values), the actions and their responses, the client events, the server events and their `defs`.
- **Server inputs:** each registered server input's name and the JSON schema of its payload type, through the same `TypeToSchemaConverter`. SchemaGen leaves them out (above).
- **Left out:**
  - every `description`, since documentation text doesn't change what replays;
  - the root `x-stateTree` wire form, since it describes the build's wire and not the land.
- **Canonical input (S2).** SchemaGen's own output stays byte-identical (§3); these rules apply only to the fingerprint's copy:
  - **`required` is sorted.** SchemaGen lists it in declaration order (`TypeToSchemaConverter.swift:209`, `:336`), so a reorder alone would change the fingerprint.
  - **Fields are named by their wire key, not their Swift property name.** A record holds payloads and snapshots by key, so a property renamed under the same key replays and a changed key doesn't.
    - **State fields:** the key is the snapshot key, which is the `@Sync` field name.
    - **`@Payload` types:** `@Payload` emits a package list of the wire keys, read from the type's `CodingKeys` raw values, or the property name where there are none. The macro sees only the type's own declaration, so two cases are past it: `CodingKeys` declared in an extension, and a custom `encode(to:)`. For those the list holds the property names, and the limit below applies.
    - **Types read through the Mirror fallback** (`:357-400`; nested `Codable` structs of a payload, response types without `@Payload`): their fields are Mirror's property labels. **The limit (U2):** a change to a key alone isn't seen by the fingerprint. Replay catches it only where decoding a **required** field fails:
      - an optional field whose key changed decodes as nil, with no error;
      - action responses are never decoded at replay;
      - nested structs in action payloads are decoded at replay only from PR 2 on.

      The docs state the limit in these words.
  - **A type whose sample can't be built isn't fingerprinted (U1).** The test is the converter's own failed-sample branch: neither the `{}` sample (`createSampleInstance`, `TypeToSchemaConverter.swift:461`) nor the snapshot sample (`createSnapshotDecodableSampleInstance`, :454) decoded (:370-371, the `else` at :396-400).
    - The converter reports that branch to the fingerprint (a package flag on the extraction), and the fingerprint throws `SchemaFingerprintError.unbuildableType`.
    - The schema's shape isn't the test. A field-less type is an empty object too, and it is hashed as it is: hero-defense's `PlayAction`, `ShootEvent` and `UpgradeWeaponEvent`, VisibilityTest's `ParkEntitiesAction` (`VisibilityTestLand.swift:284`), and Demo's `IncrementAction`. So is the `Any` def.
    - SchemaGen's output doesn't change; only the fingerprint looks at the flag.
  - **Refused at registration when it would record (U3).** When recording or reevaluation is on for the land (`enableLiveStateHashRecording`, `NIOLandHost.swift:196`, `LandManager.swift:199`; or a reevaluation keeper), registration computes the fingerprint. An `unbuildableType` throws `LandRegistrationError`, naming the type, from the same entry points as the other registration rows (§5). So no record that can never replay is made. With recording off, the fingerprint isn't computed, and nothing changes.
  - **`Set` defaults are sorted** by each element's canonical JSON, since a `Set`'s iteration order depends on the hash seed.
- **What it doesn't cover (S3).** It describes the shapes on the wire and in the record, not the behavior. Handler and tick logic, the tick interval, services, the land's configuration and the environment aren't in it. Replay still checks those through the state hash per tick, as today.
- **Strict means additive changes are refused too.** A new action, a new event, or a new optional field changes the fingerprint, so older records of that land stop replaying, by decision (D15).
- **The hash:** sorted-key JSON of the parts above, then `DeterministicHash.fnv1a64` as 16 hex digits, the same function as `ProtocolSchema.computeHash()`.
  - A format tag, `"fp1"`, is part of the hashed input. A change to the rule bumps the tag, and the new value can never equal an old one.
  - The fingerprint is cached per definition type and computed once per recorded land, off the tick path.

**Written and checked:**
- The recorder writes `ReevaluationRecordMetadata.schemaFingerprint` from the keeper's definition, in the same place it forces `version` (`ReevaluationRecorder.setMetadata`). For a registered land the fingerprint was already computed at registration (U3), so this can't fail. A directly built keeper, which skips registration, whose fingerprint throws gets none, and its record is refused at replay. That is the one path left without a registration refusal, as for the other rows (§5, "`LandKeeper` used directly").
- The check runs at the admin replay start (`NIOAdminRoutes.swift:708-730`), in the runner before the first step (`ReevaluationRunnerImpl.swift:117`, `:186`), and in `ReevaluationEngine.run` (:219). Each compares the record's fingerprint with the current definition's. On a mismatch it throws `ReevaluationReplayCompatibilityError.schemaFingerprintMismatch(recorded:current:)`, and the admin route returns it as its replay-start error.
- **The two codes (nit):** the docs name both. 2002 `schemaMismatch` compares `landDefinitionID`, the land's `id` string, and its name stays for compatibility. 2004 `schemaFingerprintMismatch` compares the fields. 2005 is `schemaFingerprintMissing`. The admin route's error `code` strings are `RECORD_SCHEMA_FINGERPRINT_MISMATCH` and `RECORD_SCHEMA_FINGERPRINT_MISSING`, next to today's codes.

**Format: the fingerprint minor, F (M1).** F is the next minor when PR 1f merges: 3.5 if it merges before #591, 3.6 if after (#591 takes 3.5 with `rejectedMinor = 5`). `ReevaluationRecordVersion.current` becomes F, with the field, and `ReevaluationRecordVersion.fingerprintMinor = F` names it. An older build already refuses a newer minor (`isReadable`, since 3.2).

**The replay minimum becomes F (S5).**
- **Replay:** a new `ReevaluationRecordVersion.minimumReplayable`, equal to F, is checked first at each replay entry point. A record below it is refused with `schemaFingerprintMissing` before anything else is read.
- **Readers that don't replay** keep `minimumSupported` (2.5): the record log reader and the JSONL exporter.
- **If #591 merges first,** its 3.5 records are below F and refused. Its `rejectedMinor` branch can then be reached only by readers, and it joins the follow-up issue.

**Records without a fingerprint (before F, or an F record without the field): refused.** They are refused with `ReevaluationReplayCompatibilityError.schemaFingerprintMissing(recordedVersion:)`, kept apart from the mismatch, so a tool can tell "re-record" from "the code changed". The reasoning:
- **It is the failure D15 exists to stop.** A record without a fingerprint can't be shown to match the code. Replaying it with a warning would print a verdict on a record nobody can check, which is the absorb-and-continue path #535's rule forbids.
- **The precedent:** records before 2.5 are already refused as unsupported, "not comparable, never a mismatch: re-record them" (`ReevaluationRecordVersion.minimumSupported`). This is the same class.
- **Foundation before release:** no record outside this repository and its measurement data needs to keep replaying. Published experiment data names its git SHA (`meta.git_sha`), and is reproduced by replaying at that SHA, not with a later build.
- **The cost, stated (Q4).** PR 1f's body lists every record it makes unreplayable. Those in the repository are re-recorded at F in PR 1f:
  - `Examples/GameDemo/reevaluation-records/{1,2,3}-hero-defense.json`, which the GameDemo E2E replay uses;
  - the five `Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/*.reeval.sstr`;
  - every record a test builds in code (named in §7).

  Records outside the repository, such as the measurement data's record sets and any record the tools replay, are listed as unreplayable at the head. They are reproduced at their recorded git SHA.
  - the version-dependent replay branches before F can no longer be reached from replay. Readers that don't replay still use them (the JSONL exporter, the record log reader). Removing them is a follow-up issue, not this PR.
- **The rejected alternative, allowing with a warning,** is what today's `landDefinitionID` check amounts to for a changed field.

**Its effect on N3 (settled in review of rev 10).** Under D15, a record from before PR 2 has no fingerprint (PR 1f is earlier), so it is refused whatever client events it holds. N3 (b)'s case can't be reached by replay any more, so **PR 2's scan is dropped**. N3's intake rule stays, and so does a test that a record below F is refused as `schemaFingerprintMissing`.

**PR 1f, before PR 1b, on its own. Why:**
- it is a record-format change with its own review surface: the version bump, refusing old records, the re-recorded fixtures and the admin route's error;
- it is independent of the event writer, and PR 1b's decode doesn't depend on it to be correct, since the decode is the last guard;
- landing it first means PR 1b's mismatch tests build records that pass the fingerprint and carry a corrupt payload, which is the case the decode guards;
- the fixtures' re-recorded diff would otherwise bury PR 1b's logic.

**PR 1f as built: where it departs from the text above.**
- **F is 3.6:** #591 merged first with 3.5. Its 3.5 records have no fingerprint and are refused with the older ones; #591's gate tests expect that refusal, through the engine and both runner initializers.
- **The cache is per definition value, not per definition type.** A key of the state type and the land's `id` let a changed definition with the same `id` reuse the old value within a process (a test replaying against a land without its server input passed the fingerprint that way). Registration computes it once and stores it on the definition; the land's keepers, built from the same value, read it there.
- **The engine's own error.** `ReevaluationEngine.run` lives in the core module, so it throws `ReevaluationRecordFingerprintError` (`.missing`, `.mismatch`); the runner maps it to `ReevaluationReplayCompatibilityError` 2004 / 2005, and the admin route to its two code strings.
- **Server inputs list their fields.** `ServerInputPayload` refines `SchemaMetadataProvider`, with a default empty field list. A `SchemaMetadataProvider` type whose field list is empty but that has fields (a payload or server input without `@Payload`) is unbuildable, so a land that records must give its server inputs `@Payload`: a behavior change for a recording land with such a type.
- **What isn't unbuildable** besides field-less types: collections, raw-value types, `Date`, `Data`, `URL`, `UUID`, `Decimal`, a value with its own snapshot conversion (`SnapshotValueConvertible` without `@SnapshotConvertible`), and `Any` / `AnyCodable`. None has a `{}` sample, and none is described by its stored fields.
- **Defaults are hashed as present, not by value** (after review). A default a macro computes when the process runs (`UUID()`, `Date()`, a `Set`'s iteration order) gave each process its own fingerprint, so only whether a state field has a default is hashed, and `Set` defaults aren't sorted. This supersedes "their default values" and "`Set` defaults are sorted" above. A static default's change doesn't move the fingerprint either: `ReevaluationEngine.run` and the monitor catch it by the state hash per tick, and keeper-mode replay (`LandManager`'s `.reevaluation`) doesn't, since it compares no hash. A payload field's default isn't in the schema at all.
- **What the schema doesn't carry is added from the extraction:** a `Set`'s element schema, a `CaseIterable` raw-value enum's raw values, and the response type of each action. Server inputs are walked in key order. A `@Payload` type with two fields under one wire key throws `SchemaFingerprintError.wireKeyCollision`, and a `Set` whose element can't be listed is unbuildable.
- **Blind spots beside U2:** the cases of a raw-value enum that isn't `CaseIterable`, and a `let` with an initial value in a `@Payload` type, which a synthesized `Decodable` doesn't decode (#611, with #606's strict decode).
- **`@Payload` names a backticked property without its backticks** in `getFieldMetadata()`, the wire keys and `_payloadFieldForms`, as a synthesized `Codable` does (`Notes/solutions/2026-11-18-macro-names-from-identifier-text-keep-backticks.md`).
- **Registration for reevaluation** (`registerWithReevaluation*`) checks the fingerprint with recording off too: its records are replayed by definition.
- **The admin route** compares with the realm's fingerprint for the live land type. When there is none to compare with (a land server that reports none, the protocol's default; an unregistered type; a definition the fingerprint can't list), it refuses every record with 409 `RECORD_SCHEMA_FINGERPRINT_UNAVAILABLE` (after review; as first built, it skipped the mismatch check).
- **Keeper mode checks too** (after review): `LandManager`'s `.reevaluation` mode runs `checkRecord` before the keeper exists, against the fingerprint the record holds. A replay definition whose id is the recorded `landDefinitionID` plus `replayLandSuffix` is fingerprinted under the recorded id; any other, the live definition reused among them, under its own. Keying on the suffix alone would misname a live type that ends in it.
- **`ReevaluationRunner --verify`** exits 10 for a record without a fingerprint, as for a record this build can't verify, and 13 for one of another schema.
- **The tracked hero-defense records** are re-recorded as `{1,2,3}-hero-defense.sstr`. The old `3-hero-defense.json` stays, bytes unchanged, as `Tests/SwiftStateTreeTests/Fixtures/hero-defense-record-2.5.json`, the canonical MessagePack tests' input only.

## 5. Error paths under #535's scope rule

| # | Failure | Today (checked) | Under this plan | Unit that ends |
|---|---|---|---|---|
| EV1 | A registered event type, or a registered action's `Response` type, has no typed writer (`_payloadHasTypedWriter` is false), and the encoder in use has compression on | `fatalError` at its first send | refused at land registration | registration (type knowable) |
| EV2 | A registered type's static name differs from the schema ID | the client can't map the event | refused at land registration | registration |
| EV3 | The host passes `eventHashes`, and a registered event type is missing from it | sent with its string name (N8) | refused at land registration (the table and the land disagree) | registration |
| EV4 | A registered event's value fails to encode (a fallback field that throws; a non-finite number under `JSONEncoder`; an unsupported value or map key), any target | 107: no body, then the standalone frame fails too: logged, `.lost`. Otherwise logged and dropped (TA :3026-3032) | the failing event and everything after it in that cycle (its later events, its state update) aren't sent. Events of the cycle enqueued before it may already be out (§1.1). The land is stopped through #535's path (`LandFailure`, kind `.eventEncode`; its sessions closed with 4016 `landFailed`) | **the land**: the value is encoded once, before fan-out, so the failure is a fact about the value, a type error in #535's table (D9 (b), decided) |
| EV6 | The merged 107 broadcast frame, or a per-session frame carrying targeted events, fails to encode | #535's classes 2–3 | as #535 decides | #535's |
| EV7 | A recorded server event the replay land re-emits (§4) whose name isn't in the base land's registry, or whose payload doesn't decode into the registered type | with #590: the re-emit is untyped, and on a compressed encoding it ends the replay land with `.eventEncode`; on `json` it is sent as recorded | a record/code mismatch: the runner's `step()` throws `ReevaluationReplayResolutionError` (tick, sequence, name, error), the run fails, and nothing from that tick on is queued (D14 (a′)). That holds whatever the policy, every recorded event decoded. A field change is refused earlier, before the first step, by the fingerprint (§4.1). Live land code can't emit an untyped event (`emitAnyServerEvent` is removed); a framework bug that builds one still meets #590's refusal (`.eventEncode`) | **the replay run**: the record and the code disagree, so later ticks would compare against events the code can't produce |
| A9 | The runner can't read a tick's recorded server events or its recorded state hash (M2) | events: `(try? …) ?? []` (`ReevaluationRunnerImpl.swift:352`), so the tick looks as if it recorded none, and under `.projectedWithFallback` a tick that emitted none falls back to nothing. Hash: `try?` (:332) gives nil, and a nil recorded hash is a match (:338-346), so a read error passes the tick | either read error throws from `step()` and fails the run, with the tick, which read, and the error (D14 (a′)). A record that holds no hash for the tick (the source returns nil without throwing) is unchanged | the replay run |
| A10 | The runner's snapshot of the replayed state doesn't encode (S1) | `try?` (:324): `actualState` is nil, so the replay land can't decode the tick and skips it silently (A11) | the encode error throws from `step()` and fails the run, with the tick | the replay run |
| A11 | The replay land can't decode a result's state: `decodeReplayState` returns nil, or `State(fromBroadcastSnapshot:)` throws (S1) | the tick returns with no state and no events (`GenericReplayLand.swift:89-107`), logged only with `GENERIC_REPLAY_DEBUG` | the runner builds the state in `step()` (D14 (a′)), and a failure there fails the run like EV7. The tick only reads a decoded state and can't meet it | the replay run |
| A1 | An unknown action or client-event name | `actionNotRegistered` / `eventNotRegistered` thrown, an error frame to the client | unchanged | the input (rejected) |
| A2 | A malformed action payload, including one that can't be recorded (§2.4) or holds a non-finite number | the round trip throws at intake, or the wire decode throws, an error frame (the catch in `handleActionRequest`, TA :5912-5921, and `handleActionError`, :6079) | the typed decode or the record check throws at intake, the same error frame | the input (rejected) |
| A3 | A malformed client-event payload | silently skipped at apply, recorded (§1.3) | rejected at intake with an error frame, not recorded (N2) | the input (rejected) |
| A4 | Two action handlers' folded names overlap (§2.4) | the first in declaration order wins, silently | refused at land registration (N9) | registration |
| A5 | A recorded input can't be staged in replay (§4), an old record's malformed client event included (N3 (b)) | skipped with a warning, or the tick runs without its inputs (:4126-4139, :4251-4256); a malformed client event is skipped by the handler | the tick fails, and the run stops failed | the replay run |
| A6 | `serverEventsMatch` can't encode a payload | `Data()` on both sides: equal | a mismatch, with the error | the verification (fails) |
| A7 | A decoded value's cast to the handler's type fails | at intake, `actionNotRegistered` (:2715-2717) | can't fail after A8 for handlers the DSL builds (`HandleAction`, `HandleEvent`: the descriptor and the handler share `E`). A hand-built erased handler, or a keeper whose definition wasn't validated, can still reach it. If it does, the land is stopped as an internal invariant, never skipped | the land |
| A8 | An erased handler's type isn't an `ActionPayload`, or a client-event handler's type differs from its descriptor | per input: `actionNotRegistered`; in replay, a skip | refused at land registration | registration |

**No per-recipient event encode failure (D9 (b), decided).** Each event is encoded once, before fan-out (§1.1), so whether it encodes depends on its value, not on who receives it. A failure that does depend on the session is a per-session frame failure, EV6, which is #535's (#532). So an event encode failure ends the land at the first throw, whatever the target. This plan keeps no per-player state and uses no per-session close code.

**Where registration is checked (the entry points).** `LandKeeper.init` (`LandKeeper.swift:807`) doesn't throw, validates nothing and has no encoding configuration, so the check can't live there. The checks go into `LandDefinition.validateForRegistration(context:)`, the single registration check #535's plan also uses; whichever PR merges first adds it, and the other adds its rows. Its context is core-level, since core can't name the NIO configuration; this plan needs two fields in it, whether payloads are compressed and the `eventHashes`. Without them, it runs the encoding-independent checks only (EV2, A4, A8).

| Entry point | Has | Checks | How a refusal surfaces |
|---|---|---|---|
| `NIOLandHost.register`, and `registerWithReevaluationSameLand`, `registerWithGenericReplay` and the monitor land, which call it | the definition and the land's configuration (encoding, `eventHashes`) | all: EV1–EV3, A4, A8 | `register` throws `PayloadRegistrationError` next to `SyncValueSemantics.validate` (`NIOLandHost.swift:363`), before `NIOLandServer` is built (:380) and the path is mapped. The host doesn't serve that land type |
| `LandManager` used directly (public init, non-throwing, a definition per land ID), and `NIOLandServer` used directly (its init throws, but holds a factory, not a definition) | the definition only when a land is created; the manager's `transportEncoding` and `eventHashes` | all, in `createLand` (`LandManager.swift:397`), before the keeper and adapter are built | `getOrCreateLand` (async throws, :367) throws, so the join that asked for the land gets an error and no land instance exists. Later than the host's check, but before any input |
| `LandTypeRegistry.init` (throws) | the state type, no definition | none new | unchanged |
| `ReevaluationEngine.run` (async throws, `ReevaluationEngine.swift:192`) and `ReevaluationRunnerImpl.init` (async throws) | the definition, no transport | EV2, A4, A8 | throws before the keeper is built; the run fails with the error |
| `LandKeeper` used directly (tests, benchmarks), and a benchmark's own `TransportAdapter` | the definition; the adapter's encoding config, but its init doesn't throw | none | nothing is refused. Handler lookup uses today's scan when the definition is ambiguous (§2.4), A7 stays per input, and an EV1 type keeps today's crash. A caller can run `validateForRegistration` itself |
| A custom `LandKeeperTransport` (public protocol, `LandKeeperTransport.swift:59`) | its own encoding | EV2, A4, A8, if it calls `validateForRegistration` without the encoding fields | its own. EV1 and EV3 concern the shipped encoders only |

**How EV4 and EV7 stop things (depends on #535).** No keeper state is mutated after an await to stop a land:
- **In-turn sync:** the encode runs in the adapter's synchronous sync phase. A failure ends that phase's plan and returns `InTurnSyncResult.landFailed(LandFailure)` (kind `.eventEncode`, `position` the `LandFailurePosition` #535 defines for the in-turn sync phase) to the keeper's turn, which stops the land as #535 does.
- **The legacy flush** (`flushOutputs`, :491-492) awaits per event. A failure there doesn't stop the land from the flush's frame. The adapter submits a `LandFailure` (kind `.eventEncode`, `position` #535's value for the legacy flush) through the package `LandKeeper.submitLandFailure(_:ticket:)`, with the ticket captured when the flush began; it arrives as a turn input. The keeper's handler re-reads the land's state and validates the ticket, as the reentrancy rule requires. The flush stops sending the rest of its batch.
- **#535's stop and session-close paths exist** (#580), and EV4 is current (#535 row 17). PR 1b removes the hybrid per-event fallback (D10) and adds no absorb path. EV7 isn't a land stop any more: under the 2026-11-18 decision it fails the replay run (§4, D14).

**Logs and counters** follow #535's fields: land type and ID, class (`eventEncode` / `actionDecode`), event or action name, target, error text, sync sequence. A malformed client input (A2, A3) is counted per land type and logged at debug, so a flood of bad inputs doesn't flood the log.

## 6. Public API changes

| API | Change | Compatibility |
|---|---|---|
| `PayloadCompression` | loses `encodeAsArray()` (D13 (b)); gains `_payloadWireName`, `_payloadHasTypedWriter`, `_writePayloadFields(into:)`, `_payloadFieldForms`. The defaults: the runtime name, `false`, a writer that throws, and an empty list | `@Payload` emits them. A hand-written conformance compiles; an `encodeAsArray()` it wrote is an unused method (N7); it is refused at registration only where EV1 applies |
| `@Payload` | the `names:` list gains the four members (§2.2) | macro users recompile; no source change |
| `PayloadCompression.encodeAsArray()` | **removed** (D13 (b)): the requirement, its default, and the macro's emission. §6.1 lists what goes | source break for code that calls it, or that declares the macro's `names:` list by hand; none in the repository outside the parts removed (checked) |
| `_PayloadFieldWriter`, `_PayloadPrimitiveWriter`, `_PayloadWireLeaf`, `_PayloadFieldForm` | new, public and underscored: the macro's expansion in user modules calls them, and `SwiftStateTreeDeterministicMath` conforms its types | additive. A cross-module compile fixture proves the expansion builds outside `SwiftStateTree` (§7) |
| `AnyServerEvent` | package `wireForm: (any ServerEventPayload)?`; no public signature change | `Codable` and `Sendable` unchanged |
| `AnyClientEvent` | package `source`; `payload` becomes a computed get-only property (it is a `let` today) | reads compile; `Codable` unchanged |
| `AnyClientEventHandler` | a package invocation that takes the value decoded at intake. The `try?` round trip is removed; The public `invoke(_:event: AnyClientEvent, ctx:)` (`LandDefinition.swift:287-293`) stays. The handler holds only its event type and closure, and `invoke` gets no registry or descriptor (:264-293), so the public `init<E>` captures its own decode closure for `E`. `invoke` decodes the event's payload through it (the event's source, or an `AnyCodable` source for a hand-built event), throws the decode error without calling the handler, and otherwise calls the handler. It no longer skips silently | its public init, used by `HandleEvent`, and `invoke`'s signature unchanged; a malformed event now throws from `invoke` |
| `AnyEventDescriptor` (client events, PR 2) | package `decodeClientEvent` closure, captured by `Register<E>` (§2.4) | additive |
| `ActionEnvelope` | package `source`; `payload` becomes computed get-only; `init(typeIdentifier:payload:)` kept | reads compile; `Codable` unchanged |
| `LandKeeper.PendingActionItem` | `action` becomes computed get-only; package `decoded`, `source`, a package init and `with(resolverOutputs:resolvedAtTick:)`; **the public init kept**, non-throwing, decoding at apply as today (§2.4) | reads and the public init compile |
| `LandContext.emitAnyServerEvent(_:to:)` | **removed** in PR 1b (the decision on #521, 2026-11-18). Its only caller, the replay land, emits typed (§4) | source break, with no deprecation: a caller outside the repository stops compiling and moves to `emitEvent(_:to:)` with a typed payload. There is none in the repository after PR 1b (checked at a42b481c; #590's tests move to the transport, §7) |
| `AnyEventDescriptor` (server events) | a package `decodeServerEvent` closure, built at registration (§4) | additive. The public init is unchanged and builds a descriptor without `decodeServerEvent`. The DSL never builds one that way, so a re-emit through it is unreachable from the DSL; a test asserts that every descriptor the builder makes has the closure. A hand-built registry that reaches one gets EV7 |
| `ReevaluationStepResult` | gains `public let replayFrame: ReevaluationReplayFrame?` (init parameter, default nil) and `with(projectedFrame:)`, a copy that keeps every other field (M2) | the field is additive |
| `ReevaluationRunnerProtocol` (behavior) | **a result without `replayFrame`, or with a frame of another `State`, fails the run when the service queues it** (§4). A custom runner calls `ReevaluationReplayFrame.resolve(...)` | **behavior break** for custom runners that build results by hand: their runs fail until they resolve. Listed next to the 2004/2005 switch break |
| `ReevaluationReplayFrame` | new public struct with package storage, made only by `public static func resolve<State: StateFromSnapshotDecodable>(tickId: Int64, snapshot: StateSnapshot, recordedServerEvents: [ReevaluationRecordedServerEvent], emittedServerEvents: [ReevaluationRecordedServerEvent], definition: LandDefinition<State>) throws -> ReevaluationReplayFrame` (throws `ReevaluationReplayResolutionError`). A runner whose `State` isn't `StateFromSnapshotDecodable` calls `resolveEvents(tickId:recordedServerEvents:emittedServerEvents:definition:)`, which builds a frame without a state | additive |
| `ReevaluationReplayResolutionError` | new public error: the tick, sequence, name and error of an event that doesn't resolve, or which read, encode or state decode failed (A9–A11) | additive |
| `ReevaluationRecordMetadata.schemaFingerprint` (PR 1f) | new `String?` field and init parameter (default nil) | additive; Codable reads records without it |
| `ReevaluationReplayCompatibilityError` (PR 1f) | new cases `schemaFingerprintMismatch(recorded:current:)` and `schemaFingerprintMissing(recordedVersion:)`, with error codes 2004 and 2005 | an exhaustive `switch` outside the package must add them: the package isn't built for library evolution |
| `ReevaluationRecordVersion.current` (PR 1f) | becomes F, the fingerprint minor (§4.1); new `fingerprintMinor` and `minimumReplayable` (both F). `minimumSupported` stays for readers | a behavior change: every record below F is refused at replay |
| `SchemaFingerprintError` (PR 1f) | new public error: `unbuildableType(String)` | additive |
| Admin replay-start error codes (PR 1f) | new `code` strings `RECORD_SCHEMA_FINGERPRINT_MISMATCH` and `RECORD_SCHEMA_FINGERPRINT_MISSING`, with the recorded and current values in `details` | additive for clients that pass unknown codes through |
| `ReevaluationSchemaFingerprint` (PR 1f) | new public `compute(for:)` on a `LandDefinition`, for tools and tests | additive |
| Registration refusals (EV1–EV3, A4, A8) | rows in `LandDefinition.validateForRegistration(context:) throws`, shared with #535 (whichever PR merges first adds it). This plan's failures are `PayloadRegistrationError`, one case per row with the type and the reason, all failures in one error. Called at each entry point as §5 lists | new public types; the calling entry points already throw |
| `EventRegistry.eventName(for:)` | kept, the single runtime event rule | unchanged |
| Behavior | a malformed client event gets an error frame (N2); EV1–EV7, A2–A8 | named in the PR and in `docs/core` |

**Docs:** `docs/transport_evolution.md` and `docs/transport_evolution.zh-TW.md` name `encodeAsArray` as the server's serializer (:276 in each). Both are rewritten to the typed writer and the fallback rule in the same commit (bilingual sync). `docs/core/runtime.md` is unaffected (its `AnyCodable` is the action response's box, which stays).

**No record-version step (N3 (b)).** This change adds no version-dependent reading. Readers already branch on the version for other reasons (`ActionRecorder.swift:178-208`, `ReevaluationEngine.swift:211-212`), and nothing here adds a branch: an old or new record with a malformed client event fails replay alike, and the bytes of accepted inputs' records don't change (D8). So `ReevaluationRecordVersion.current` stays as it is.

### 6.1 What goes with `encodeAsArray()` (D13 (b); checked at `main` 9755a625, `git grep encodeAsArray`)

| Where | What | In PR 1a |
|---|---|---|
| `EventPayload.swift:18-21` | the `PayloadCompression` requirement `func encodeAsArray() -> [AnyCodable]` | removed; the new members take its place |
| `EventPayload.swift:37-41` | the default that calls `fatalError` | removed; the default writer throws, and EV1 refuses such a type at registration |
| `PayloadMacro.swift:61-64`, `:241-270` | `generateEncodeAsArray` and its call: the macro stops emitting `encodeAsArray()` | replaced by `_writePayloadFields` |
| `StateTreeBuilder.swift:84` | `named(encodeAsArray)` in `@Payload`'s `names:` list | replaced by the four new names |
| `MessagePackTransportMessageEncoder.swift:251-279` | `encodePayloadAsArray`, called for action responses (:123), actions (:153), client events (:205) and server events (:233) | replaced by the writer at all four sites |
| `TransportMessageEncoder.swift:320-343` | the opcode JSON `encodePayloadAsArray`, called at :192, :222, :274, :302 | the same |
| `PayloadMacroSortingTests.swift:50` | the expected expansion with `encodeAsArray()` | rewritten to the writer's expansion |
| `docs/transport_evolution.md:276`, `docs/transport_evolution.zh-TW.md:276` | the serializer named | rewritten (above) |
| `Notes/protocol/TRANSPORT_PROTOCOL.md:224` | payload compression "through `@Payload`'s `encodeAsArray()`" | rewritten to the writer |

- **Callers:** the eight `encodePayloadAsArray` sites above are the only callers in `Sources`, `Tests` and `Examples` (checked). `sdk/ts`, `Tools/CLI` and `Examples/*/WebClient` never name it; they read field order from the schema, which doesn't change.
- **Conformances:** every `@Payload` type gets the writer from the macro: 24 in `Examples`, 13 in `Sources` and 214 in `Tests` (checked by a scan of the declarations). Eleven test types conform without `@Payload`, and none of them is encoded on a compressed encoding: the `SchemaGenTests` event types (schema only), `QueueIncrementResponse` (`LandKeeperActionQueueTests`, keeper only) and `InvalidPayload` (a macro diagnostics test) (inferred from their tests; checked when PR 1a builds). `Archive/` isn't built by `Package.swift`.
- **Action responses, actions and client events on the compressed encodings** move to the writer with server events, since their positional path is the same function. Responses are the server's own output: their bytes are pinned like events', and a registered action's `Response` type without the writer is EV1. Outgoing actions and client events are what Swift clients, tests and the benchmark's `--inputs-from-wire` send; their bytes are pinned too.
- **No deprecation step.** Nothing in the plan keeps `encodeAsArray()` as a path or an oracle (§7).

## 7. Tests

**Red first, where they can be:**
- the silent client-event skip (A3): a malformed client event gets no error today, and is recorded;
- the replay re-emit of a recorded dictionary on a compressed encoding (N5), with `.projectedWithFallback`: on base (with #590), the replay land ends with `.eventEncode` instead of sending the event; after PR 1b its frame equals the live frame. #590's exit test already covers the old crash;
- `serverEventsMatch` with two unencodable payloads (A6): equal today;
- a hand-written `ServerEventPayload` without `@Payload` on `messagepack` (EV1), as an exit test on base;
- replay loading with a recorded action whose type has no handler, and with a source that throws (A5): the run passes today with the input missing.

**Event frames, differential:** `encodeAsArray()` is removed in PR 1a, so the oracle doesn't use it:
- **Goldens from base:** a first commit of PR 1a, on base, writes the bytes of every fixture below through today's encoders into committed goldens. The switch must then reproduce them.
- **A test-only oracle** for generated values: the fields from `Mirror`, sorted by label (checked first against `getFieldMetadata()`'s names, the macro's order), each boxed in `AnyCodable` and converted by today's per-value path, which stays in the encoders as the fallback.
- **Kinds:** server events, action responses, actions and client events (§6.1), each also through the no-`wireForm` path (M3), with `TransportMessageEncoderTests` unchanged.
- **The `Void` ACK, per encoding:** MessagePack, a byte golden (`[]`); JSON object, today's bytes; compressed opcode JSON, an exit test (`#expect(processExitsWith: .failure)`) if it traps on base, otherwise a golden. The golden-writing commit never encodes it on opcode JSON in-process.
- **Types:** every payload type in the repository (Hero Defense, the reevaluation monitor, the demos), plus fixtures with one field of each leaf type and each fallback kind: `[Int]`, `[String: Int]`, `[PlayerID: Int]`, a nested struct, `AnyCodable` holding a dictionary and an array, `Date`, `Data`, `Decimal` (finite and NaN), `UUID`, `Float`, and unsigned values above `Int.max`.
- **Values:** `Int.min`/`Int.max`, every `Int32` boundary of the math types, `−0.0`, NaN and ±∞ (MessagePack writes them, as today; the JSON encodings expect the encode failure of EV4), empty and non-ASCII strings, NFC and NFD forms.
- **Assertion:** exact bytes, for the 107 body, the standalone frame in each of the three message encodings, the merged 107 frame, and the response, action and client-event frames, typed against the goldens and the oracle. Also with compression off (N10): today's keyed bytes.

**Field forms:** a test lists `_payloadFieldForms` for every payload type in the repository. A new fallback field fails it until it is listed.

**Names:**
- `_payloadWireName` equals `EventRegistry.eventName(for:)`, or the action rule, and the schema ID, for every registered event and action type;
- a generic fixture, a nested-type fixture, a type named `Action`, and a conformance added in an extension (the computed form);
- macro expansion tests for a non-generic, a generic and a nested-in-generic payload, including the `names:` list;
- `PayloadMacroSortingTests` extended to the writer's field order.

**Cross-module compile fixture:** a payload type with `@Payload`, an event and an action, in a module that imports `SwiftStateTree` without `@testable` (a small test-support target). It must build, and its frames must equal the oracle's.

**Action and client-event decode, differential:**
- **Corpus:** each repository action and client-event type × valid payloads, extra keys, an extra key holding NaN, +∞ or −∞ (at the top level and nested two deep, as double and as float), an extra key holding a map with an integer key, missing keys, duplicate keys, wrong types, out-of-range integers, integral and non-integral floats for integer fields, NaN and ±∞ for `Double` and `Float` fields (top level and nested), the largest finite values and subnormals, `−0.0`, strings for numbers, binary for strings, `nil`, nested values, and MessagePack maps with integer keys at depth 1 and 3.
- **Per encoding:** the typed decode against today's path, on accept/reject and on the decoded value (canonical JSON). On the JSON encodings they must agree everywhere. On MessagePack the non-finite and non-string-key cases must agree (refused). Every other disagreement is listed, with its direction (N1, D7).
- **Recording on and off:** the same corpus is accepted and refused identically with and without a recorder (§2.4), the extra-key NaN/±∞ and integer-key fixtures included. With a recorder, `makeRecordPayload()` is the path under test; without one, `validateRecordable()`.

**Handler lookup:**
- **Oracle:** today's scan, kept in the test.
- **Corpus:** for each repository land, exact names, module-qualified names, schema IDs, case variants, `X.AddGold`, `x.addgold`, `addgoldaction`, `AddGoldAction.`, `..AddGoldAction`, `.`, the empty string, and unknown names. The lookup must return the handler the scan returns, or none where it returns none.
- **Generated pairs:** pairs of handler names, including ones that differ only in case and ones where one's schema ID is the other's basename. A pair is refused (A4) exactly when some corpus input matches both under the scan; otherwise the lookup equals the scan on the corpus.
- **Unvalidated:** a keeper built directly on an ambiguous definition returns what the scan returns.
- **Replay:** the replay lookup equals :4110-4124's two predicates on the same corpus.

**`AnyClientEventHandler.invoke` without a registry (M1):** a handler built with the public init, called directly. A valid event runs the handler once. A malformed one throws, doesn't call the handler, and leaves the state unchanged.

**Decode once:** a counting hook on the source shows one decode per live action at intake, none at apply. That holds for an action without resolvers, for one with resolvers across resolver completion and delivery (:2074, :1910), and on a tickless land. An item from the public init decodes once, at apply.

**Records:**
- Action and client-event records are byte-identical to today's for inputs from each encoding.
- The committed record fixtures (`ReevaluationReplayCompatibilityTests`, `ReevaluationRecordVersionTests`, the `SyncOutputGoldens` records), re-recorded at F by PR 1f, replay unchanged. None of them holds a client event the new decode rejects (inferred; asserted in a test by decoding each one's client events through its land's registry).
- An old-version record holding a malformed client event fails replay at that tick, with the sequence and type (N3 (b)).
- No record is built without a recorder or reevaluation mode (a counting hook), and `appliedOrder` still drives the tickless pass record.

**Replay land:**
- the replay land's registry lists the base's event types;
- **typed re-emit:** for every event type in the repository and each leaf and fallback fixture of §7's event frames, a recorded event (written by a live recorder, then read back from its JSON) re-emitted under `.projectedWithFallback` gives a frame byte-identical to the live frame, on `messagepack`, `opcodeJsonArray` and `json`, `.all` and targeted;
- a projected event (the in-process run's typed value) is taken without a round trip (a counting hook on the JSON path);
- **mismatch refused (EV7):** a recorded payload that doesn't decode into its registered type, and an unregistered name, each make `step()` throw `ReevaluationReplayResolutionError` with the tick, sequence, name and error. The run's status is `.failed` with that message, the queue holds only the ticks before it, the replay land sends nothing for that tick or after, and it stays up;
- **every recorded event decoded:** the same mismatch under `.projectedOnly`, on a tick whose projected events would have been chosen, still fails the run;
- **custom runners:** a result without `replayFrame` fails the run when queued;
- **state type (S1):** a factory that returns the other VisibilityTest state fails the run when its first result is queued, with both type names, and nothing is queued;
- **with a projector (M2):** a tick whose passes didn't match keeps `recordedPassMismatch` and `replayFrame` through `processResult`, and sends only its projected events. On main today it falls back to the recorded ones; this test is red first;
- **A9:** a source whose `getServerEvents` throws fails the run, and so does one whose `getStateHash` throws (M2). A source that returns nil for the hash without throwing still passes the tick, as today;
- **A10, A11:** a snapshot encode that throws (a fault hook on the runner's encoder) and a state that doesn't build back (a fault hook on the resolver) each throw from `step()` and fail the run, and the tick sends nothing;
- **the state box:** the land's `as? State` never fails across the repository's replay lands (asserted);

**Schema fingerprint (PR 1f):**
- **deterministic:** the fingerprint of each example land equals a committed golden. The goldens are written on macOS and checked on CI's Linux image, so the two platforms agree. It is the same in two processes, and under `SWIFT_DETERMINISTIC_HASHING` on and off;
- **sensitive:** a fixture land changed by one thing each (a state field added, a field's type, a sync policy, a default value, an event field, an action's response field, a server input's field, a new action, a new optional field) gives a new fingerprint every time;
- **stable:** each of these leaves the fingerprint unchanged:
  - a changed `description`;
  - fields reordered;
  - a property renamed under the same `CodingKey`, in a `@Payload` type.

  A changed `CodingKey` raw value changes it;
- **canonical:** a fixture with a non-empty `Set` default gives the same fingerprint with `SWIFT_DETERMINISTIC_HASHING` on and off, and in two processes;
- **unbuildable (U1, U3):** a payload field whose type has no buildable sample makes the fingerprint throw `unbuildableType`. That land's registration is refused with recording on, and accepted with it off. A field-less action and event, and a field typed `AnyCodable`, fingerprint without error;
- **every land fingerprints (U1):** every land definition in the repository (Sources, Examples, Tools, and the test lands that record) gets a fingerprint without error. That includes hero-defense, with its field-less actions and events, and Demo;
- **the key-list blind spots:** a `@Payload` type with `CodingKeys` in an extension, and one with a custom `encode(to:)`, give the property-name list. A test pins that, so a later macro that sees them changes the test on purpose;
- **refused:**
  - a record whose fingerprint differs is refused before the first step, at each entry point (the admin start, the runner, `ReevaluationEngine.run`), with `schemaFingerprintMismatch` holding both values;
  - a record below F, and an F record without the field, are refused with `schemaFingerprintMissing`;
- **written:** a recorded land's record holds the current fingerprint; a keeper whose schema throws writes none and logs it;
- **fixtures:** the re-recorded example records replay, and pass the E2E replay check;
- **tests that replay pre-F records (S5)**, updated by PR 1f. Each replay below F becomes "refused with `schemaFingerprintMissing`". A check of a version branch that a reader still uses keeps calling that branch directly:
  - `TicklessPassOrdinalTests`: `olderTicklessRecordIsSkipped` (3.3, 3.0); "A 3.4 tickless record's sync outputs and seeds verify against the pass they read after", and "A 3.4 tickless pass without its ordinal is a record error", both re-recorded at F;
  - `TicklessReplayPassTests`: "A 3.0 tickless record without passes still replays…" and "The JSON view keeps a 3.1 record's passes; a 2.x JSON tickless record replays…";
  - `SyncOutputVerifierTests.olderRecordWithNonNFCTextIsNotComparable` (3.3);
  - `NIOAdminRoutesReplayStartTests`: the cases writing 2.5 records;
  - the `current == "3.4"` checks in `FullStateHashTests`, `NFCKeyTests`, `ReevaluationRecordLogTests` and `ReevaluationRecordVersionTests`, and `NFCKeyTests`' old-version loop;
  - if #591 merged first, its `rejectedMinor` gate tests.
- EV1–EV3 on the replay land pass and fail as on the base;
- **the backstop:** #590's `UntypedEventPayloadTests` emitted through `emitAnyServerEvent`. They now hand an untyped `AnyServerEvent` straight to the adapter's `sendEventToTransport(_:to:)`, as a framework bug would, and still expect `.eventEncode` and 4016.

**Error paths** (fault injection through `eventEncodingFaultForTesting`, extended with a target and an event type; holds, not timing):
- **EV4:** with an `.all` target and with a targeted one, the land is stopped (`InTurnSyncResult.landFailed` in-turn, `submitLandFailure` on the legacy flush), its sessions closed with 4016, and another land keeps syncing. Nothing after the failing event in that cycle is sent; events enqueued before it are, on the immediate path and on the legacy flush.
- **EV7:** in the replay land tests above.
- **Legacy flush:** the stop arrives as a turn input with a ticket; a stale ticket (the land restarted under a hold at the flush's await) is ignored.
- **EV1–EV3, A4 and A8:** refused at registration, all failures in one `PayloadRegistrationError`, with the reasons, at each entry point of §5: `register` throws, `getOrCreateLand` throws and creates nothing, the replay engine and runner throw before a keeper exists.
- **A2/A3:** an error frame, the land and session alive, nothing recorded.
- **A5:** each failure kind stops the run failed, with the tick and reason; the staged batch commits nothing for a failed tick.
- **A6.**

**Hybrid config (D10):** events are sent alone, with today's bytes, and no body encode is attempted (a counting hook).

**Unchanged outputs:** `HeroDefenseWireBytesTests`, the sync-output goldens, verify-views, the replay state hash, and the E2E on CI in all three encodings.

**Mutants**, each killed by a named test:
- the writer in declaration order (event frames);
- an `Int` leaf written as `.uint`, or `Float` as `.double` (event frames);
- the fallback through `MessagePackValueEncoder` instead of `encodeAnyCodable` (the top-level `Decimal` fixture);
- a static name that keeps the `Event` or `Action` suffix, or the full nested name (names);
- one merged index for all forms, or `last(input)` looked up against schema IDs (handler lookup: `X.AddGold`);
- the lowercased index keyed on the last component instead of the whole input (handler lookup: `x.addgold`);
- the A4 fold without the schema ID's last component (generated pairs);
- the record check run only when recording (recording on and off);
- non-finite numbers accepted by the MessagePack source, or the walk limited to declared fields (decode differential: the extra-key fixtures);
- a targeted encode failure that closes sessions instead of the land (EV4);
- an old record's malformed client event skipped instead of failing replay (N3);
- a response type without the writer accepted at registration (EV1);
- `makeRecordPayload()` without the walk, as today's `decodeAnyCodable` (recording on: the extra-key NaN fixture);
- `try?` restored on the client-event decode (A3);
- the replay loader's `continue` or swallowed error restored, or a partial batch committed (A5);
- the replay land built without the base's registry (replay land);
- an event encode failure logged and dropped (EV4);
- a failure that closes only sessions, for either target (EV4);
- the replay land re-emitting the recorded payload untyped, as today (typed re-emit: the frame differs, and on a compressed encoding the land ends);
- a payload that doesn't decode forwarded, or skipped with the rest of the tick sent (EV7);
- the state written before the events are resolved (EV7: the tick's state frame goes out);
- only the policy-selected events decoded (`.projectedOnly` mismatch);
- the resolution moved back into the tick (the tick then has to handle a failure: the A11 fault test fails);
- the fingerprint without the server inputs, or with the descriptions (fingerprint sensitivity);
- a missing fingerprint replayed with a warning (refused);
- one of the three entry points left without the check (refused, per entry point);
- `?? []` restored on the recorded-event read, or `try?` on the hash read (A9);
- `try?` restored on the snapshot encode (A10), or the land's silent `return` on a state that doesn't decode (A11);
- the apply-time decode kept, or `decoded` dropped by the copy (decode once);
- records built from the decoded value instead of the source, or built without a recorder (records);
- a 107 body built in a hybrid config (hybrid);
- `?? Data()` restored in `serverEventsMatch` (A6).

## 8. Measurement (host A/B under the off-path instruction gate)

`2026-11-13-off-path-instruction-gate.md` applies. Event encode and input decode are off the sync path in purpose, so this change's work is judged by windowed `instructions:u`, and time is reported.

**Prerequisites, as their own PR on main (PR 0), so both sides have them:**
- **Where event encode runs.** Inferred: inside `syncNow()` under in-turn sync, since the sync phase enqueues the turn's events (TA :2852-2864); on the legacy path, at the tick's flush. Checked first with a counting probe. The perf window gains a mode **`iteration`** (the whole timed iteration, ticks and sync), so the judged span contains the encode wherever it runs.
- **`--inputs-from-wire`:** `--active-players` injection today builds `AnyCodable` by a JSON round trip and calls the keeper (`BenchmarkExecution.swift:62-81`), which skips the wire decode. With the flag, each input is encoded as a client frame in the cell's message encoding, as the TypeScript SDK encodes it (the payload a map, never positional), built outside the timed spans, and handed to `adapter.onMessage`, so it goes through the transport's decoder. Serial runs only.
- **`--actions-per-player N`** on the visibility-test runner: `SetMotionAction(enabled: true)` (`VisibilityTestLand.swift:273`), N per player per iteration, from wire bytes, inside the `nonsync` span. It has a field, and with motion already on it leaves the state unchanged (inferred; checked by the cell's state frames against `vis-tick`; the cell's bytes also hold each action's response). The land has a tick handler, so each action gets the immediate `Void` ACK (`LandKeeper.swift:2799-2801`), which traps on compressed opcode JSON (§2.3, M2). So `vis-actions` runs on `json` and `messagepack` message encodings only, until that is fixed. Hero Defense's only action, `PlayAction`, has no fields, so it isn't used. If a richer typed action is wanted, PR 0 adds a benchmark-only land rather than changing a game's schema.
- **Input counts in the result JSON,** per cell and run, counted in the benchmark (Examples/ only; no keeper counters):
  - **submitted:** frames handed to `adapter.onMessage`;
  - **accepted:** submitted minus rejected, where rejected is the error frames the rooms sent (by message kind, read from the frame's first bytes);
  - **applied:** a per-room `InputProbe` the benchmark registers in the keeper's `LandServices`. The `MoveToEvent` and `SetMotionAction` handlers look it up (`ctx.services.get(InputProbe.self)?.noteApplied()`). GameServer and the load tests register none, so their lookup finds nothing, but the handler code changes for them too.
  - The run requires all three equal to rooms × players × iterations × N on both sides, and exits nonzero otherwise.
- **`--message-encoding json|opcode-json-array|messagepack`:** the benchmark's `opcode-json` formats send JSON object messages (`message: .json`, `BenchmarkConfig.swift:44-49`); only their state updates are opcode arrays. So their event frames, responses and client frames are uncompressed, and they never reach the positional opcode JSON encode. The flag overrides the format's message encoding (default: the format's own), and each result records `messageEncoding`.
- **The perf window's `iteration` mode** (`ENCODING_BENCHMARK_PERF_WINDOW=iteration`) brackets the whole timed iteration in both serial runners. `nonsync` and `ticks` keep today's spans, code for code, in runs without `--inputs-from-wire`: the runners choose the wire branch before any window opens. With inputs, `nonsync` also covers their submission.
- Defaults unchanged. The window's refusals (`--parallel true`, the single-room path) still apply.

**Cells** (2000 iterations, `--parallel false`, as #527's; `--format messagepack-pathhash` unless named):

| Cell | Command | Judged (`instructions:u`) | Expected |
|---|---|---|---|
| `cap100-events` | `--game-type hero-defense --rooms 1 --monster-cap 100` | `iteration` window | GAIN (event encode) |
| `cap100-noevents` | the same with `--no-server-events` | `iteration` window, control | within the bar |
| `cap100-moves` | `cap100-events` with `--active-players --inputs-from-wire` | `nonsync` window | GAIN (client-event decode, `MoveToEvent`) |
| `vis-actions` | `--game-type visibility-test --rooms 10 --players-per-room 5 --actions-per-player 1 --inputs-from-wire` | `nonsync` window | GAIN (action decode) |
| `vis-tick` | `--game-type visibility-test --rooms 10 --players-per-room 5` (no server events, inferred) | `ticks` window, control | within the bar |

- **The sync gate stays beside the iteration window.** `cap100-events` and `cap100-noevents` also run the standing on-path gate on `syncMs` (time, the old bar), since the `iteration` window contains the sync. A sync REGRESSION fails the set even when the window shows a GAIN.
- **Bar:** the gate plan's REGRESSION at max(0.5 %, 3 × base's spread), and GAIN below base's min. Time is reported beside it with the old bar, and "layout move (#517)" is printed where time moves but instructions don't.
- **Bytes and digests:** identical in every cell, base = base again = head, with the committed `capture-digest.py`. One extra capture pass runs `cap100-events`, `cap100-moves` and `vis-actions` with `--format json-object`, and `cap100-events` and `cap100-moves` with `--format opcode-json-pathhash --message-encoding opcode-json-array`, so the JSON event frames and decode paths, positional opcode JSON included, are covered too (reported, not timed). `vis-actions` isn't run on opcode JSON (the `Void` ACK, above).
- **Repeats:** ABBA, a warm-up pair and 5 pairs per cell, for the timed set and the perf set. `SWIFT_DETERMINISTIC_HASHING=1` and the FIFO window in the perf set, in the standing container scope.
- **Before the host:** a Mac direction check on `cap100-events`, ABAB. macOS has no `perf` window, so the check is time plus a `sample` profile of §0's buckets. If the buckets don't shrink, stop and report.
- **The profile after:** a user-only `perf record` per side on `cap100-events`. The §0 buckets (a)–(c) are expected near zero for typed fields.

## 9. Steps

1. **PR 0, on main first:** the benchmark knobs, the input counts and the `iteration` window (§8); the §0 profile posted on #521.
2. **PR 1a, the writer, with `encodeAsArray()` removed** (D13 (b)):
   - the goldens from base, as its first commit, and the red tests (§7);
   - core: `_PayloadFieldWriter`, `_PayloadWireLeaf` and leaf conformances (core and DeterministicMath), `_PayloadFieldForm`, the shared action-name function; the `encodeAsArray()` requirement and default removed;
   - the macro: `_payloadWireName`, `_payloadHasTypedWriter`, `_writePayloadFields`, `_payloadFieldForms`, the `names:` list, `generateEncodeAsArray` removed, expansion tests (`PayloadMacroSortingTests` rewritten), and the cross-module fixture;
   - the MessagePack writer and the JSON wrapper; `AnyServerEvent.wireForm`; all eight positional sites switched (§6.1), each with the no-`wireForm` path (M3) and MessagePack's `Void` branch kept (M2);
   - EV1 in `validateForRegistration` (events and response types), since a type without the writer would otherwise fail at its first send;
   - the docs, both languages. No `docs/core/failure-handling.md` row flips in PR 1a.
   - **Size (inferred, from the parts listed; the PR states the real count):** about +1,200 / −200 lines, half of it tests and goldens.
3. **PR 1f, the record's schema fingerprint (D15, §4.1), before PR 1b:**
   - the fingerprint, written by the recorder;
   - checked at the three entry points;
   - record format F (the next minor, §4.1), `minimumReplayable = F`, with records lacking a fingerprint refused;
   - the canonical input: sorted `required`, wire keys (`@Payload`'s key list), `Set` defaults, the unbuildable refusal from the converter's failed-sample branch, refused at registration when recording is on (U1, U3);
   - the tests that replay pre-F records, updated (§7);
   - **the body lists every record PR 1f makes unreplayable** (§4.1);
   - the two new error cases;
   - the re-recorded fixtures;
   - the docs, both languages:
     - the record format section of the reevaluation docs;
     - `docs/core/failure-handling.md` and its `.zh-TW.md`, a row "A record whose schema fingerprint differs from the code, or that has none";
   - **Size:** about +400 lines plus the re-recorded fixtures (inferred).
4. **PR 1b, events around the writer** (rev 10; cut from `main` after #590, 85c9c297, and after PR 1f):
   - the hybrid decision at init (D10);
   - EV2 and EV3 in `validateForRegistration`;
   - the replay land's registry (M5), `PayloadDecodingSource` with its `AnyCodable` source, the descriptors' `decodeServerEvent`, and the typed re-emit (N5);
   - `ReevaluationReplayFrame` resolved in the runner's `step()`, with every recorded event decoded (D14 (a′)): the mismatch (EV7), the source reads (A9), the snapshot encode (A10) and the state decode (A11) fail the run there;
   - `emitAnyServerEvent` removed, with #590's tests moved to the transport;
   - `serverEventsMatch` (A6).
   - **Docs, both languages:** in `docs/core/failure-handling.md` the re-emit row ("The replay land re-emits a recorded event…", #538) becomes current: typed, byte-identical, and a mismatch fails the run. #590's untyped-event row becomes "no API; a framework bug meets the encoder's refusal". The `UntypedPayloadError` doc drops its mention of `AnyServerEvent(type:payload:)` as a land's path. PR 1b closes #538.
   - **Size:** about +700 lines (inferred).
5. **PR 2, decode:**
   - decode sources, with the record check and the non-finite rule;
   - the three-index lookup, with A4 and A8 in `validateForRegistration`;
   - decode once, through `PendingActionItem`'s package init and copy;
   - client events (D2, N2, N3 (b)), with #593's client-event decode failure item;
   - records built from the intake tree, only when read;
   - the replay staged batch (A5);
   - `docs/core/failure-handling.md` and `.zh-TW.md`: the client-event row ("A client event whose payload doesn't decode…", #537) and the replay-loading row ("Replay can't load or match a recorded input") flip to current;
   - the differential tests.
   - **The N3 scan: dropped (rev 11).** D15 refuses every record from before PR 1f, so no record the scan would read can replay. N3's intake rule and the refused-below-F test stay.
6. **PR 3: folded (rev 8).** #535's mechanism merged first (#580), and EV4 is current. EV7 is PR 1b's run failure. No PR 3.
7. **Host A/B** per PR (1a and 1b together if they merge close together), base = main at run time, head = the PR merged with it. PR 0's knobs are on both sides.
8. **Solutions:**
   - "the positional event payload is name-sorted, not declaration order", if the review agrees it is a trap (#521's text had it the other way);
   - "a lookup that replaces a predicate scan needs one index per predicate, keyed by what the predicate compares" (M1's trap);
   - another entry if the work finds a reusable lesson about encoders that must reproduce a cast chain's per-type forms.

### 9.1 PR 2's scope after 2026-11-19 (rev 13)

Read at `main` 353c296a. As above, each fact is marked **checked** or **inferred**.

**PR 1b isn't built (checked: no branch or PR for it).** PR 2 needs `PayloadDecodingSource` and its `AnyCodable` source, which §4 gave to PR 1b. Apart from that, the two PRs don't overlap:
- PR 1b covers server events and the replay runner;
- PR 2 covers client input at intake.

So **PR 2 adds the protocol and both sources**, and PR 1b, whenever it is built, uses them for `decodeServerEvent`. The order of PR 1b and PR 2 is then free. As queued (2026-11-19), PR 1b follows PR 2. §4's "What PR 1b adds" moves the protocol to whichever of the two merges first.

**Three things folded in by the decisions of 2026-11-19:**

1. **#616's "check the depth once" goes into the typed path, without a proof type.** #616 is parked: its proof type cost more than the walk it saved (`Notes/solutions/2026-11-19-a-cross-module-generic-wrapper-runs-unspecialized.md`). PR 2 doesn't need one, because on each encoding the one walk an input gets already does other work:
   - **MessagePack:** the frame is unpacked at `PayloadNesting.clientFrameMaxDepth` (checked: `MessagePackTransportCodec.swift:26`). The source then holds the payload's `MessagePackValue` (opcode 101 and 103, `MessagePackDirectDecoder.swift:81-115`, today `decodeAnyCodable`). Two walks follow, and neither is extra:
     - `validateRecordable()` (§2.4) walks the whole tree for string keys and finite numbers. It is required anyway, and it also checks the depth, so the depth check costs no walk of its own. `InboundPayloadDecoding`'s `PayloadNesting.check` isn't run on this source.
     - The typed decode reads the declared fields only.
     So a live MessagePack action gets one whole-tree walk and no `Any` tree. Main builds the tree (`decodeAnyCodable`), walks it again (`PayloadNesting.check`), then re-encodes it with `JSONEncoder` and parses it with `JSONDecoder` (checked: `InboundPayloadDecoding.swift`, `LandKeeper.swift:2765`, :3365).
   - **Opcode JSON and JSON object:** today's semantics (§2.4). The source holds the `AnyCodable` tree, and `decode` is today's `InboundPayloadDecoding.decode`: one `PayloadNesting.check`, then the round trip. That is main's cost on these encodings, so PR 2 moves nothing there.
   - **Recorded input in replay:** an `AnyCodable` source, the same rule as the JSON encodings.
   - **The hot-path rules from the lesson:**
     - No small generic struct is built in one module and read in another on the input path. The source is a protocol existential, and the pending item stores `decoded: (any ActionPayload)?` and `source: (any PayloadDecodingSource)?` as existentials. A generic helper that the transport and the keeper both call is `@inlinable` or isn't generic.
     - The source's kind is fixed by the decoder that builds the envelope: the MessagePack decoder builds a MessagePack source, and the JSON decoders build an `AnyCodable` one. No step tests a codec's or a source's concrete type per input.
     - The payload is stored once per item. When nothing records, the item holds `decoded` and `source`, and no tree. `action` (public, computed) is built from the source when it is read; the intake's `validateRecordable()` guarantees that the build can't fail.
   - **The walk counter** (`PayloadNesting.walks`, a task-local bound only by tests, from #616's branch) comes into PR 2. It counts the whole-tree walks an input gets, and pins one per input on every encoding: the recordability walk on MessagePack, and `PayloadNesting.check` on the JSON encodings. This is where #616's two review points land:
     - **r4622519525:** the job path gets a positive control, a case that expects its walks to be counted (a nonzero count on the job's apply, as the live cases have). If the apply ever moves to a detached task, or to one created before the binding, the counting tests then fail instead of passing at 0.
     - **r4622519396:** any text-matching tripwire PR 2 adds says only "it matches text", with the cases that get past it (a name built by reflection, a call outside `Sources/`). It doesn't claim that a split line gets past it.

2. **#606's strict decode and #611 go to a PR 2c, after PR 2 (recommended).** PR 2's acceptance contract is "the accepted inputs are today's, and the differential test names each difference" (§2.4, N1, D7). Strict decode breaks that on purpose:
   - Extra fields are refused, on every encoding, so clients sending extra keys get errors. It is a wire-behavior change, and the SDK and the E2E scenarios have to be checked first (inferred: the TypeScript SDK sends the declared fields only, `protocol.ts:156-166`, to be checked).
   - #606 also asks for the JSON encodings to decode from the bytes, without the tree. That needs the frame decoders to keep the payload's byte range, which PR 2 doesn't touch.
   - #611, refusing `let x = <initializer>` in `@Payload`, is a macro diagnostic and a source break. It names #606's change as its home.

   PR 2c therefore holds: strict decode on all encodings, the JSON decode from bytes, #611's diagnostic with its macro test, and the docs row for "a client payload with undeclared fields". PR 2's MessagePack source is written so that strict mode is a switch on its decoder (the `@Payload` wire-key list is already there, `_payloadFieldForms`), not a second path. If Review prefers #611 earlier, it is small enough to be its own PR at any time: it touches only `PayloadMacro.swift` and the macro tests.

3. **#616's review points:** covered in 1 above.

**What PR 2 ships (the measured path; §9 step 5 otherwise unchanged):**
- `PayloadDecodingSource`, with the `AnyCodable` source and the MessagePack source. The record check and the non-finite rule run in `validateRecordable()`, and that walk is also the depth check (1 above).
- Decode once: `PendingActionItem`'s package init and its `with(resolverOutputs:resolvedAtTick:)`. The apply step decodes nothing.
- Client events (D2, N2), `decodeClientEvent` at intake, and the A3 rejection with an error frame (#537, with #593's client-event decode-failure item). Closes #537.
- Records built from the intake tree, only when something reads them.
- The walk counter and its tests, including r4622519525's positive control.
- The differential tests (§7) and the `failure-handling` row for the client event (#537), in both languages.

**What moves to a PR 2b (off the measured path):**
- The three-index lookup, with A4 and A8 in `validateForRegistration`.
- The replay staged batch (A5), with its `failure-handling` row "Replay can't load or match a recorded input".

The lookup replaces a linear scan of a land's few handlers. Its gain is small, and it adds registration refusals of its own (N9), which are reviewed better on their own. The staged batch is replay-only. Both are independent of the decode source.

**Gates for PR 2:**
- Review, and the Codex second track at medium effort.
- **A host A/B** on `vis-act-mp` and `vis-act-json`, the cells ab-616 used, in the `nonsync` window, against main (with #605) at run time.
  - Expected: a GAIN on `vis-act-mp`, since one whole-tree walk, the `Any` tree, `JSONEncoder` and `JSONDecoder` all go.
  - `vis-act-json` within the bar, since that path is unchanged.
- Before the host: a symbol diff, base against head, on `vis-act-mp` (`perf record`, DWARF callchains, in the throwaway container). If a value-witness or metadata-cache symbol rises, as in #616's A/B, PR 2 stops and reports it before the host run.

## 10. Decisions

**Settled by review (2026-11-13), as (a):**
- **D2, client events in scope:** (a) yes, the same decode mechanism; it removes the silent skip (A3).
- **D3, where the typed form lives:** (a) `AnyServerEvent` keeps its public shape and carries a package `wireForm` (as `any ServerEventPayload`, M6).
- **D4, the static name for generic payloads:** (a) a computed static calling the runtime rule.
- **D5, fields without a typed form:** (a) the `Codable` fallback, chosen at compile time, listed and logged.
- **D6, the JSON encodings:** (a) `JSONEncoder` with a typed wrapper.
- **D8, what an action record holds:** (a) the wire payload, as today.
- **D10, hybrid configs:** (a) decided at init; events go alone.
- **D11, a positional action wire form:** (a) not in this plan.
- **D12, action responses:** (a) a follow-up issue, **narrowed by D13 (b):** the response's encode step on the compressed encodings moves to the writer in PR 1a (§6.1); the response's `AnyCodable` box in `LandDSL` and the rest stay a follow-up.

**Decided by the maintainer (2026-11-13):**
- **D1 (a): no stop rule.** The work goes ahead whatever §0's profile shows; the profile is reported, not a gate.
- **D7 (a): the exact typed decode.** Today's whole-tree refusals (non-finite numbers, non-string keys) are kept; every other difference is listed in N1.
- **D9 (b): an event encode failure always ends the land**, whatever the target, at the first throw. No per-session close and no bound for event encode.
- **D13 (b): `encodeAsArray()` is removed now,** not deprecated (§6.1, PR 1a).
- **N3 (b): old records holding a malformed client event are refused:** their replay fails. This change adds no version-dependent reading and no record-version step. Since rev 11 the case can't be reached by replay (D15), and the scan is dropped (§4.1).
- **N7: settled by D13 (b).** A hand-written `encodeAsArray()` is an unused method; a type without the writer (`_writePayloadFields` and `_payloadHasTypedWriter = true`) is refused at registration (EV1).
- **N8 (a):** a registered event missing from `eventHashes` is refused at registration (EV3).
- **N9: yes.** Lands that are ambiguous today are refused at registration (A4).
- **N10 (a):** compression off keeps today's keyed `Codable` path.

**Decided on #521 (2026-11-18):**
- **N5 typed:** the replay land re-emits recorded server events typed, through the land definition's registry. A payload that doesn't decode is a record/code mismatch: it is reported and fails fast, never forwarded.
- **`emitAnyServerEvent` removed** in PR 1b, with no deprecation: its only caller is the replay land.
- **#590's refusal** stays as a backstop for framework bugs only.

- **D14 = (a′), every recorded event decoded.** Rev 8 offered (a), a tick that fails the run through the service with a ticket, and (b), ending the replay land too. Review's (a′) was chosen instead: the runner resolves in its async `step()`, and a mismatch fails the run through the existing catch (§4). A record with any event that doesn't decode fails even under `.projectedOnly`.
- **D15 = a strict schema fingerprint** in the record (§4.1, PR 1f). The per-event decode stays as the last guard.

**Chosen in rev 10, for review:**
- **Records without a fingerprint are refused,** not replayed with a warning (§4.1 gives the reasons).
- **PR 1f is its own PR, before PR 1b** (§4.1).

**Settled in review of rev 10:** the N3 scan is dropped from PR 2 (§4.1).

## 11. Related issues

- **#535:** the failure rule and its scope decision; EV4 and EV7 use its stop path. Its sweep gains `serverEventsMatch` (A6), the client-event skip (A3) and replay input loading (A5).
- **#537** (the client-event skip) and **#538** (the replay re-emit crash) are filed on their own, so they are tracked if this plan's PRs move. PR 2 closes #537. #590 ends the crash, and PR 1b closes #538 with the typed re-emit.
- **#590:** the encoders' refusal of a value that isn't a payload type; a backstop after PR 1b.
- **#586 (#591):** handler results constrained to `A.Response`.
- **#593:** the client-event decode failure, in PR 2.
- **A follow-up issue** (filed with PR 1f): remove the pre-F replay branches that D15 makes unreachable from replay, #591's `rejectedMinor` gate included if it merged first.
- **#532:** a per-session frame failure, as EV6.
- **#517:** the off-path gate this measurement uses.
- **#519, #520 (#527):** done; the order #521 asks for.
- **#387:** server inputs keep `AnyCodable` (out of scope).
- **#87:** a handler that throws after writing is #535's land-state row; unrelated to decode, which now happens before any handler runs.
