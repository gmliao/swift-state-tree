# Typed server events and client actions, without AnyCodable (#521)

**Status:** rev 1, for review. No code before this plan is reviewed.
- Read at `main` 882cabe7. Each fact is marked **checked** (read in the code or run) or **inferred** (reasoned, to be pinned by a test in the PR).
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

**No stop rule (D1).** #521 gives the main reason as type information that is known at compile time and thrown away; the cost is secondary. The profile sets the expected size of the A/B, and is posted on #521.

## 1. Where AnyCodable sits today

### 1.1 Server events: emit to wire

| Step | Where (checked) | What it does |
|---|---|---|
| Emit | `LandContext.emitEvent` (`LandContext.swift:231-234`) | `AnyServerEvent(event)` |
| Name | `AnyServerEvent.init(_:)` (`EventPayload.swift:135-139`), `eventName(for:)` (:145-163) | `String(describing: type(of:))`, split on `.`, drop an `Event` suffix, on every emit |
| Box | the same init, :137 | `payload = AnyCodable(event)`: the event as `Any` |
| Queue and flush | `LandKeeper.flushOutputs` (`LandKeeper.swift:480-528`); in-turn, `runSyncPhaseInTurnIsolated` (`TransportAdapter.swift:2852-2864`) | each event goes to `enqueueEventSynchronously` (:2782-2808) |
| Opcode 107 body | `encodeServerEventBody` (TA :3075) → `EncodingPipeline.encodeServerEventBody` (`EncodingPipeline.swift:122-135`) → `MessagePackTransportMessageEncoder.encodeServerEventBody` (`MessagePackTransportMessageEncoder.swift:52-63`) | builds `[AnyCodable]` (`encodeEvent`, :191-247), then converts each element with `MessagePackValueEncoder` (:283-286) |
| Positional payload | `encodePayloadAsArray` (MessagePack :251-279, opcode JSON `TransportMessageEncoder.swift:320-343`) | unwraps `payload.base`, casts it to `any PayloadCompression`, calls `encodeAsArray()` and boxes the result again. A payload type without `@Payload` reaches the default `encodeAsArray()`'s `fatalError` (EventPayload :37-41); a payload that isn't a `PayloadCompression` at all (a dictionary) reaches the encoder's own (MessagePack :273, opcode JSON :336) |
| Per field | `encodeAsArray()` (macro, `PayloadMacro.swift:243-270`) | `[AnyCodable(self.a), AnyCodable(self.b), …]`: each field boxed, its static type lost |
| Per value, MessagePack | `MessagePackValueEncoder.box` (:11-90) | 20 `as?` checks, then `as? AnyCodable` hands the field to `encodeAnyCodable` (:264-340), about 30 more cases; a struct field (`Position2`) falls through to `any Encodable` and re-enters `box` for each nested value |
| Per value, opcode JSON | `OpcodeTransportMessageEncoder.encode` (`TransportMessageEncoder.swift:127-130`) | `JSONEncoder` over `[AnyCodable]`; each `AnyCodable.encode` runs its own cast switch (`AnyCodable.swift:39-80`) |
| JSON object | `JSONTransportMessageEncoder` (`TransportMessageEncoder.swift:68-84`) | the synthesized `Codable` of `AnyServerEvent`, whose payload is `AnyCodable(event)`: one `any Encodable` hop into the event's own `Codable` |
| Type number | `encodeEvent` (MessagePack :224, opcode JSON :293) | `eventHashes?[serverEvent.type]`: a string-keyed lookup per event; the per-land table comes from the schema through the host configuration (`NIOLandServer.swift:60`) |
| Non-107 send | `sendEventImmediately` (TA :2946-3033) → `EventSendingPipeline.prepareImmediateSend` (`EventSendingPipeline.swift:88-`) | `messageEncoder.encode(.event(…))`: the same paths as above, one encode per event |

Each event is encoded once, before fan-out, on every path (checked: the 107 body is queued as a `MessagePackValue`, `EventSendingPipeline.swift:42-77`; the immediate path encodes once and enqueues the same `Data` to every session).

**Four copies of the name rule (checked):** `AnyClientEvent.eventName` (EventPayload :89-108), `AnyServerEvent.eventName` (:145-164), `EventRegistry.eventName(for:)` (`EventRegistry.swift:166-185`), `SchemaExtractor.generateEventID` (`SchemaExtractor.swift:235-255`). The schema's event IDs, and so its `eventHashes` (ranks of the sorted IDs, :165-180), come from the last one.

### 1.2 Client actions: wire to handler

| Step | Where (checked) | What it does |
|---|---|---|
| Wire, MessagePack | `MessagePackDirectDecoder` opcode 101 (`MessagePackDirectDecoder.swift:81-89`), `decodeAnyCodable(from:)` (:485-524) | the payload `MessagePackValue` becomes a tree of `Any` in an `AnyCodable` |
| Wire, opcode JSON | `TransportMessageDecoder.decodeAction` (`TransportMessageDecoder.swift:121-152`) | `JSONSerialization` tree wrapped in `AnyCodable`; an array payload is accepted here as an array |
| Wire, JSON object | `ActionEnvelope`'s `Codable` (`TransportMessage.swift:4-12`) | `AnyCodable.init(from:)` (`AnyCodable.swift:15-37`) |
| Handler match | `LandKeeper.submit` (`LandKeeper.swift:2683-2711`), `generateActionIDForMatching` (:2808-) | a linear scan of the land's handlers; per handler, up to four string comparisons (type name, last `.` component, schema ID, case-insensitive schema ID), each building strings with `String(describing:)` and splits. The first handler that matches any form wins |
| Decode at intake | `LandKeeper.swift:2719-2721` | `JSONEncoder().encode(envelope.payload)`, then `JSONDecoder().decode(actionType, from:)`: a JSON round trip |
| Queue | `PendingActionItem` (`LandKeeper.swift:189-197`) | keeps `action: AnyCodable` (the wire tree), not the decoded value |
| Decode at apply | `LandKeeper.swift:3412-3415` | the same round trip again, inside the turn |
| Record | `ReevaluationRecordedAction` (`ActionRecorder.swift:652-`), built at `LandKeeper.swift:3434-3445` | `payload: actionItem.action`: the wire tree as received |

**Clients send action payloads as objects (checked).** The TypeScript SDK writes `[101, requestID, typeIdentifier, payload(object)]` (`sdk/ts/src/core/protocol.ts:156-166`). Its `actionFieldOrder` table is filled from the schema but not used to send. An array payload reaches the keeper as an array and fails the round trip's keyed decode (inferred; pinned by a test, §7).

### 1.3 Client events: wire to handler

- Wire: as actions (opcode 103), into `AnyClientEvent.payload: AnyCodable` (MessagePack :103-115, opcode JSON :174-230). Checked.
- Intake: `handleClientEvent` (`LandKeeper.swift:2850-`) looks up the descriptor by name (a dictionary) and queues the `AnyClientEvent` undecoded.
- Apply: `AnyClientEventHandler` (`LandDefinition.swift:273-279`) runs the JSON round trip with `try?`. **A payload that doesn't decode silently skips the handler**: no error to the client, no log, and the event is still recorded (checked). That is an absorb path under #535's rule.

### 1.4 Other consumers of the boxed payload

| Consumer | Where (checked) | Needs |
|---|---|---|
| Server event records | `LandKeeper.swift:495-505`, `ReevaluationRecordedServerEvent` (`ActionRecorder.swift:744`) | `payload: AnyCodable` of the event, written to the record as the event's keyed JSON |
| Replay comparison | `ReevaluationEngine.serverEventsMatch` (`ReevaluationEngine.swift:389-410`) | sorted-key JSON of recorded vs emitted payloads. An encode failure becomes `Data()` on both sides, so two unencodable payloads compare equal |
| Replay re-emit | `GenericReplayLand` (`GenericReplayLand.swift:126-129`) → `emitAnyServerEvent` | `AnyServerEvent(type:payload:)` from a record: the payload is the concrete event (emitted by the replay run) or a decoded dictionary (a recorded event, under the fallback policy). A dictionary under a compressed encoding reaches `encodePayloadAsArray`'s `fatalError` (inferred; pinned by a red test, §7) |
| Sync-stream digest | `TransportAdapter.canonicalEvent` (:3988-3992), `SyncOutputVerifier.addEvents` (`SyncOutputVerifier.swift:292-299`) | `SnapshotValue.make(from: payload.base)`, only when the keeper records the sync stream |
| Schema | `SchemaExtractor.swift:106-143` | event types and names only; no payload values |

**Not in this plan** (they use `AnyCodable` for other reasons): action responses (`LandDSL.swift:872/916/943`, `TransportActionResponsePayload`), server inputs (#387, `ServerInput.swift`), resolver outputs, join metadata, error details, admin and monitor DTOs. Action responses take the same writer later (D12).

## 2. The typed design

### 2.1 A static wire name per payload type

`@Payload` emits the name the schema uses (`SchemaExtractor.generateEventID`'s rule for events, `generateActionID`'s for actions), computed at expansion from the struct's name:

```swift
public static let _payloadWireName: String = "PlayerShoot"
```

- **Generic or nested-in-generic types** take a computed static that calls `EventRegistry.eventName(for: Self.self)`, with the lexical-context predicate #527 introduced for `_syncPolicy_` (`2026-11-12-sync-policy-per-type.md` §3). No generic payload type exists outside tests (inferred; checked in the PR).
- **`AnyServerEvent.init(_:)`** and `AnyClientEvent.init(_:)` read `E._payloadWireName` instead of deriving the name.
- **One derivation left.** The two private copies in `EventPayload.swift` are removed. `EventRegistry.eventName(for:)` stays as the runtime rule: the fallback for types without the macro, and the schema's.
- **Checked at registration:** for each registered event and action type, `_payloadWireName` equals the schema's ID. A mismatch is refused at land registration (a type error knowable there). It can happen only for a hand-written conformance.

### 2.2 A typed field writer

The macro emits a writer beside `encodeAsArray()`, fields in the same name-sorted order:

```swift
public func _writePayloadFields<W: _PayloadFieldWriter>(into w: inout W) throws {
    try w.field(self.from)
    try w.field(self.playerID)
    try w.field(self.to)
}
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

**The rule for a type without a typed form (D5):**
- **Typed leaves:** `Bool`; `Int`, `Int8`–`Int64`; `UInt`, `UInt8`–`UInt64`; `Float`; `Double`; `String`; `PlayerID`, `ClientID`, `SessionID`, `LandID`; and, in `SwiftStateTreeDeterministicMath`, `IVec2`, `IVec3`, `Position2`, `Velocity2`, `Acceleration2`, `Angle`. These are the `SyncLeafWritable` types plus `Float` and the unsigned types. Each leaf writes exactly the MessagePack value today's top-level path gives that type. That is `encodeAnyCodable`'s case for scalars and IDs, and the `Codable` form for the math types (`Position2` → `{"v": {"x": Int32, "y": Int32}}`, `Angle` → `{"degrees": Int32}`).
- **The `SyncLeafWritable` conversions aren't reused as they are.** Their target is `SnapshotValue`, whose forms differ from the wire's for `Float` (widened to double) and for `UInt`/`UInt64` above `Int.max` (decimal strings). The leaves share their structure: one conformance file per module, as `SyncLeafWritable+DeterministicMath.swift`.
- **Everything else is a fallback field:** arrays, dictionaries, optionals (which `@Payload` refuses anyway, :109-116), nested structs, `AnyCodable`, `Date`, `Data`, `Decimal`, enums. Typed arrays of leaves are a later extension.
- **Visible, not silent.** The macro also emits `static let _payloadFieldForms: [_PayloadFieldForm]`. It is built from the same two overloads (`_payloadFieldForm(of: T.self)` → `.typed` / `.codable`), so it can't disagree with the writer. Land registration logs each registered payload type's fallback fields once, at info level. A test pins the list for every payload type in the repository (§7). The choice is per declared field type, fixed at compile time, never per message.

**In the repository today (checked):** the Hero Defense events and client events are all typed (`PlayerID`, `Int`, `Position2`, `Angle`). The reevaluation monitor's events have fallback fields: `expectedState`/`actualState: AnyCodable` and `mismatches: [TickMismatch]` (`ReevaluationMonitorEvents.swift:37-38, 63-64, 102`).

### 2.3 How it reaches each encoding

`shouldEncodePayloadAsArray` is true for `opcodeJsonArray` and `messagepack` message encodings (`TransportEncodingConfig.swift:56`, checked).

| Encoding | Today | Typed |
|---|---|---|
| `messagepack` (the default config), and the 107 body | `[AnyCodable]` → `MessagePackValueEncoder` per element (§1.1) | A `_PayloadFieldWriter` that appends `MessagePackValue`s: the body is `.array([.int(1), typeValue, .array(fields)])`, as `encodeServerEventBody` builds it after `dropFirst()`. `rawBody` is nil for a typed event. A standalone frame packs `[103, 1, typeValue, fields]`. Building bytes directly, without `MessagePackValue`, is a later step |
| `opcodeJsonArray` | `JSONEncoder` over `[AnyCodable]` | `JSONEncoder` over the same outer array, whose payload element is a typed `Encodable` wrapper: its `encode(to:)` opens an unkeyed container and runs the macro's writer through an adapter (`field` → `container.encode(v)` for a leaf, `container.encode(AnyCodable(v))` for a fallback) (D6) |
| `json` (object) | `JSONEncoder` of the whole `TransportMessage`; the payload is `AnyCodable(event)` → the event's synthesized `Codable` | unchanged, except the static name. This is the debugging encoding; the boxing here is one existential hop |
| 107 merged frame | the queued bodies (`PendingEventManager`) are merged into the frame by `EncodingPipeline` (:78, :107) | unchanged: it merges the typed bodies |
| Hybrid (`message: json/opcodeJsonArray`, `stateUpdate: opcodeMessagePack`) | every event first tries a body (JSON bytes unpacked as MessagePack, which fails), then is sent alone (TA :2794-2804) | decided once at adapter init: in a hybrid config every event is sent alone, as today's bytes show, and no body is attempted (D10). The per-event `.sentAlone` outcome goes away |

**`AnyServerEvent` carries the typed form (D3).** `init<E>(_:)` stores, beside `payload`, a package-level `wireForm: any PayloadCompression` (the same event value), when `E._payloadHasTypedWriter` is true. The encoders use `wireForm` when it is present. `AnyServerEvent(type:payload:)`, the hand-built and replay form, has none; it is resolved once at emit (§4, replay re-emit).

**The type number** stays a dictionary lookup by the static name. An `ObjectIdentifier`-keyed table per adapter is a follow-up if the profile shows the lookup.

### 2.4 Typed action decode

**A decode source instead of an `Any` tree.** A core protocol:

```swift
package protocol PayloadDecodingSource: Sendable {
    func decode<T: Decodable>(_ type: T.Type) throws -> T
    var anyCodable: AnyCodable { get }   // built on demand, for records
}
```

`ActionEnvelope` and `AnyClientEvent` gain a package-level `source`. Their public `payload` stays readable, as a computed property over `source.anyCodable`, and their `Codable` forms are unchanged (the source is excluded).
- **MessagePack** (the default): the payload's `MessagePackValue`, decoded with `MessagePackValueDecoder`. No `Any` tree, no JSON.
- **Opcode JSON and JSON object:** today's semantics, unchanged: the source holds the `AnyCodable` tree and decodes it with today's round trip. The accepted inputs are then identical by construction on the JSON encodings (D7).
- **Hand-built envelopes** (tests, benchmarks, `ActionEnvelope(typeIdentifier:payload:)`): an `AnyCodable` source, as above.

**Decode once.** The intake decodes (`LandKeeper.swift:2719-2721`, from the source), and `PendingActionItem` keeps the decoded value (`package let decoded: any ActionPayload`). The apply step (:3412-3415) calls `invokeErased` with it. Live mode decodes nothing inside the turn.

**A handler table, built at land definition.** One dictionary from every form today's scan accepts (type name, its last `.` component, schema ID, lowercased schema ID) to the handler.
- Today's scan takes the first handler, in declaration order, that matches **any** form. A table keyed by the forms reproduces that only when no two handlers share a form, including lowercased.
- So **two handlers whose forms collide are refused at land registration** (A4, a type error knowable there). With no collision, at most one handler matches any ID, and the lookup equals the scan.
- The lookup is the exact ID, then its last `.` component, then its lowercased form, each one hash lookup.

**Client events** take the same source and decode, at intake, through a decode closure the registry captures at `Register<E>` (D2). The handler receives the typed value. A payload that doesn't decode is rejected at intake with an error to the client, as for an action. Today it is silently skipped at apply (§1.3).

**Not in this plan: a positional action wire form (D11).** #521 suggests a typed positional decoder for actions, but clients send objects (§1.2). A positional form would be a new wire form with an SDK change.

## 3. The byte-identity contract

**Holds** for every registered payload type, in every encoding, for every value, when nothing fails (§5):
- **Event frames:** the 107 bodies, the standalone event frames, and the merged frames are byte-identical to today's, per session. Field order is the same name-sorted list; leaves write today's top-level values; fallback fields run today's path.
- **Event names and numbers:** the static name equals today's derived name for every type (pinned, and checked at registration). The numbers come from the same schema table.
- **Schema:** `SchemaGen` output is unchanged (no change to metadata or IDs). Each example's output is byte-identical, base against head, with its sha256 recorded. Records carry the schema hash, so a change would also show there.
- **Records:**
  - Server event records: unchanged (`payload` is still the event).
  - Action and client-event records: unchanged. `payload` is computed from the source, and for MessagePack that is today's `decodeAnyCodable(from:)` of the same value, so the record JSON is the same (D8).
- **Actions:** the same handler is chosen for every ID (with no collision, §2.4). On the JSON encodings the same inputs are accepted and decode to the same values.

**Can't hold, by design (named, each pinned):**
- **(N1) MessagePack action and client-event decode tightens (D7).** `MessagePackValueDecoder` is exact. It refuses an integer field sent as a float (`decodeInteger` takes only `.int`/`.uint`, `MessagePackValueDecoder.swift:431-445`). Today's round trip can accept such an input, depending on how `JSONEncoder` writes the double (inferred). The TypeScript SDK sends integers as MessagePack integers, so SDK clients are unaffected (inferred, pinned by the E2E). The differential test (§7) lists every difference, and the PR names each one.
- **(N2) A malformed client event is rejected with an error,** and not recorded. Today it is accepted, recorded and silently not applied (§1.3).
- **(N3) Records written before this change** that hold a malformed client event replay as they ran: skipped. That is gated on the record's version (`ReevaluationRecordVersionTests`), so an old record still verifies. A record of the new version never holds one.
- **(N4) Types that crash today are refused instead.** A registered event type with no typed writer (no `@Payload`), on a compressed message encoding, is refused at land registration. Today the process hits `fatalError` at that type's first send.
- **(N5) Replay re-emit of a recorded event as a dictionary** works on compressed encodings (§4). Today it is a `fatalError` (inferred).
- **(N6) The failure outputs** change as §5 says.

## 4. Replay and reevaluation

- **Recording:** unchanged on all three input kinds (§3). Server events keep `payload = AnyCodable(event)`. Actions and client events record `source.anyCodable`, built only when a recorder or sink reads it (`PendingActionItem.action` becomes a computed property).
- **Replay input decode:** a recorded action or client event is decoded once, when the source is read (`LandKeeper.swift:4103-4160`), through an `AnyCodable` source, which is today's semantics. Matching uses the handler table.
  - A recorded payload that doesn't decode fails the replay with an error naming the sequence and type. It doesn't skip.
  - The exception is a malformed client event in an old-version record (N3).
- **`serverEventsMatch`:** compares as today, sorted-key JSON of both payloads. Under #535's rule, an encode failure on either side is a mismatch with its error as the reason, not `Data()` on both sides (§1.4).
- **Replay re-emit (`GenericReplayLand`):** `emitAnyServerEvent` resolves an untyped event once, at emit:
  - If its payload is a concrete payload value, it is cast once to `any PayloadCompression` and written typed.
  - If it is a dictionary, it is looked up by name in the land's `ServerEvents` registry, decoded into that type, then written typed.
  - A name the registry doesn't know, or a dictionary that doesn't decode, is a land error (§5 EV7).
- **Sync-stream digests** (`canonicalEvent`, `SyncOutputVerifier.addEvents`): unchanged. They read `payload.base`, which is still the event.

## 5. Error paths under #535's scope rule

| # | Failure | Today (checked) | Under this plan | Unit that ends |
|---|---|---|---|---|
| EV1 | A registered event type has no typed writer (`_payloadHasTypedWriter` is false), on `opcodeJsonArray`/`messagepack` | `fatalError` at its first send | refused at land registration | registration (type knowable) |
| EV2 | A registered type's static name differs from the schema ID | the client can't map the event | refused at land registration | registration |
| EV3 | The host passes `eventHashes` and a registered event type is missing from it | sent with its string name | refused at land registration (the table and the land disagree) | registration |
| EV4 | An event's value fails to encode (a fallback field that throws; a non-finite `Double` under `JSONEncoder`), target `.all` | 107: no body, then the standalone frame fails too: logged, `.lost`. Otherwise logged and dropped (TA :3026-3032) | the cycle's frames aren't sent; the land is stopped through #535's path | **the land**: every recipient's output is wrong (D9) |
| EV5 | The same, target one or more players, a client or a session | as EV4 | each targeted session is closed with #535's per-session code; the land keeps running; #535's bound escalates to the land if the same player fails again right after rejoining | **the targeted sessions** (D9) |
| EV6 | The merged 107 broadcast frame, or a per-session frame carrying targeted events, fails to encode | #535's classes 2–3 | as #535 decides | #535's |
| EV7 | An untyped event (`emitAnyServerEvent`) whose name isn't registered or whose dictionary doesn't decode | a dictionary payload on a compressed encoding: `fatalError` (inferred) | treated as EV4/EV5 by its target | land or targeted sessions |
| A1 | An unknown action or client-event name | `actionNotRegistered` / `eventNotRegistered` thrown, an error frame to the client | unchanged | the input (rejected) |
| A2 | A malformed action payload | the round trip throws at intake, an error frame (the catch in `handleActionRequest`, TA :5912-5921, and `handleActionError`, :6079) | the typed decode throws at intake, the same error frame | the input (rejected) |
| A3 | A malformed client-event payload | silently skipped at apply, recorded (§1.3) | rejected at intake with an error frame, not recorded (N2) | the input (rejected) |
| A4 | Two action handlers share an accepted name form | the first in declaration order wins, silently | refused at land registration | registration |
| A5 | A recorded action or client event doesn't decode in replay | the apply-time round trip throws inside the replayed turn (inferred) | the replay fails with that error (except N3) | the replay run |
| A6 | `serverEventsMatch` can't encode a payload | `Data()` on both sides: equal | a mismatch, with the error | the verification (fails) |
| A7 | The typed value's cast to the handler's type fails | not reachable today (the round trip decodes the handler's own type) | can't fail by construction (the descriptor and the handler share `E`); if it does, the land is closed as an internal invariant, never skipped | the land |

**How EV4/EV5 stop things (depends on #535).** The encode happens in the sync phase (in-turn) or at flush (legacy). Both are inside a keeper turn or the adapter's phase, so a stop is a request that goes out, not an await (#535's design point and the reentrancy rule). Until #535's stop and session-close paths exist, this plan's PRs keep today's EV4/EV5 handling unchanged: they add no new absorb path, and they remove the hybrid per-event fallback (D10). The EV4/EV5 rows land with #535's mechanism (§9, PR 3).

**Logs and counters** follow #535's fields: land type and ID, class (`eventEncode` / `actionDecode`), event or action name, target, error text, sync sequence. A malformed client input (A2, A3) is counted per land type and logged at debug, so a flood of bad inputs doesn't flood the log.

## 6. Public API changes

| API | Change | Compatibility |
|---|---|---|
| `PayloadCompression` | gains `_payloadWireName`, `_payloadHasTypedWriter`, `_writePayloadFields(into:)`, `_payloadFieldForms`. The defaults: the runtime name, `false`, a writer that throws, and an empty list | `@Payload` emits them; a hand-written conformance compiles and is refused at registration only where EV1 applies |
| `PayloadCompression.encodeAsArray()` | deprecated; still emitted by the macro and still the path of a payload without the writer (D13) | source compatible, with a deprecation warning at call sites outside the macro |
| `_PayloadFieldWriter`, `_PayloadPrimitiveWriter`, `_PayloadWireLeaf`, `_PayloadFieldForm` | new, public and underscored: the macro's expansion in user modules calls them, and `SwiftStateTreeDeterministicMath` conforms its types | additive |
| `AnyServerEvent`, `AnyClientEvent` | no signature change; package `wireForm` / `source`; `AnyClientEvent.payload` becomes a computed get-only property | reads compile; the `Codable` forms are unchanged |
| `ActionEnvelope` | package `source`; `payload` becomes computed get-only; `init(typeIdentifier:payload:)` kept | reads compile; `Codable` unchanged |
| `LandKeeper.PendingActionItem` | `action` becomes computed get-only; package `decoded`; the public init kept | reads compile |
| `EventRegistry.eventName(for:)` | kept, the single runtime rule | unchanged |
| Behavior | a malformed client event gets an error frame (N2); EV1–EV5, A4–A6 | named in the PR and in `docs/core` |

**Docs:** `docs/transport_evolution.md` and its zh-TW companion describe `encodeAsArray` as the server's serializer (:276). They are updated to the typed writer and the fallback rule, in the same commit. `docs/core/runtime.md` is unaffected (its `AnyCodable` is the action response).

## 7. Tests

**Red first, where they can be:**
- the silent client-event skip (A3): a malformed client event gets no error today;
- the replay re-emit of a recorded dictionary on a compressed encoding (N5), as an exit test (`#expect(processExitsWith: .failure)`) on base;
- `serverEventsMatch` with two unencodable payloads (A6): equal today;
- a hand-written `ServerEventPayload` without `@Payload` on `messagepack` (EV1), as an exit test on base.

**Event frames, differential:** today's encoders stay callable (the compatibility path for payloads without the writer), so they are the oracle.
- **Types:** every payload type in the repository (Hero Defense, the reevaluation monitor, the demos), plus fixtures with one field of each leaf type and each fallback kind: `[Int]`, `[String: Int]`, `[PlayerID: Int]`, a nested struct, `AnyCodable` holding a dictionary and an array, `Date`, `Data`, `Decimal` (finite and NaN), `UUID`, `Float`, and unsigned values above `Int.max`.
- **Values:** `Int.min`/`Int.max`, every `Int32` boundary of the math types, `−0.0`, NaN and ±∞ (MessagePack; JSON expects the encode failure of EV4), empty and non-ASCII strings, NFC and NFD forms.
- **Assertion:** exact bytes, for the 107 body, the standalone frame in each of the three message encodings, and the merged 107 frame, typed against the oracle.

**Field forms:** a test lists `_payloadFieldForms` for every payload type in the repository. A new fallback field fails it until it is listed.

**Names:**
- `_payloadWireName` equals `EventRegistry.eventName(for:)` and the schema ID for every registered event and action type;
- a generic fixture and a nested-type fixture;
- macro expansion tests for a non-generic, a generic and a nested-in-generic payload;
- `PayloadMacroSortingTests` extended to the writer's field order.

**Action and client-event decode, differential:**
- **Corpus:** each repository action and client-event type × valid payloads, extra keys, missing keys, wrong types, out-of-range integers, integral and non-integral floats for integer fields, NaN, strings for numbers, `nil`, nested values.
- **Per encoding:** the typed decode against today's round trip, on accept/reject and on the decoded value (canonical JSON). On the JSON encodings they must agree everywhere. On MessagePack every disagreement is listed (D7).
- **Handler table:** for a corpus of IDs (exact, module-qualified, schema ID, case variants, unknown), the table returns the handler today's scan returns. Today's scan is kept in the test as the oracle. A land with colliding forms is refused (A4).
- **Decode once:** a counting hook shows one decode per live action at intake and none at apply.
- **Records:** action and client-event records are byte-identical to today's for inputs from each encoding. The committed record fixtures (`ReevaluationReplayCompatibilityTests`, `ReevaluationRecordVersionTests`) replay unchanged, the old-version malformed-client-event case included (N3).

**Error paths** (fault injection through `eventEncodingFaultForTesting`, extended with a target; no timing):
- EV4: the land is stopped, its sessions closed with #535's code, nothing of that cycle sent, and another land keeps syncing;
- EV5: only the targeted sessions are closed, the land keeps running, and the second failure after rejoin escalates;
- EV1–EV3 and A4: refused at registration, with the reason;
- A2/A3: an error frame, the land and session alive, nothing recorded for A3;
- A5 and A6.

**Hybrid config (D10):** events are sent alone, with today's bytes, and no body encode is attempted (a counting hook).

**Unchanged outputs:** `HeroDefenseWireBytesTests`, the sync-output goldens, verify-views, the replay state hash, and the E2E on CI in all three encodings.

**Mutants**, each killed by a named test:
- the writer in declaration order (event frames);
- an `Int` leaf written as `.uint`, or `Float` as `.double` (event frames);
- the fallback through `MessagePackValueEncoder` instead of `encodeAnyCodable` (the top-level `Decimal` fixture);
- a static name that keeps the `Event` suffix, or the full nested name (names);
- the handler table last-wins, or without the lowercase form (handler table);
- `try?` restored on the client-event decode (A3);
- an event encode failure logged and dropped (EV4, EV5);
- a broadcast failure that closes only sessions (EV4);
- the apply-time decode kept (decode once);
- records built from the decoded value instead of the source (records);
- a 107 body built in a hybrid config (hybrid);
- `?? Data()` restored in `serverEventsMatch` (A6).

## 8. Measurement (host A/B under the off-path instruction gate)

`2026-11-13-off-path-instruction-gate.md` applies. Events and action decode are off the sync path, so this change's work is judged by windowed `instructions:u`, and time is reported.

**Prerequisites, as their own PR on main (PR 0), so both sides have them:**
- **Where event encode runs.** Inferred: inside `syncNow()` under in-turn sync, since the sync phase enqueues the turn's events (TA :2852-2864); on the legacy path, at the tick's flush. Checked first with a counting probe. The perf window gains a mode **`iteration`** (the whole timed iteration, ticks and sync), so the judged span contains the encode wherever it runs.
- **`--inputs-from-wire`:** `--active-players` injection today builds `AnyCodable` by a JSON round trip and calls the keeper (`BenchmarkExecution.swift:62-81`), which skips the wire decode. With the flag, each move is encoded as a client frame in the cell's encoding and goes through the transport's decoder.
- **`--actions-per-player N`:** Hero Defense's `PlayAction` (`HeroDefenseLand.swift:258`), N per player per iteration, from wire bytes, inside the `nonsync` span.
- Defaults unchanged. The window's refusals (`--parallel true`, the single-room path) still apply.

**Cells** (messagepack-pathhash, 2000 iterations, `--parallel false`, as #527's):

| Cell | Command | Judged (`instructions:u`) | Expected |
|---|---|---|---|
| `cap100-events` | `--game-type hero-defense --rooms 1 --monster-cap 100` | `iteration` window | GAIN (event encode) |
| `cap100-noevents` | the same with `--no-server-events` | `iteration` window, control | within the bar |
| `cap100-actions` | `cap100-events` with `--actions-per-player 1 --inputs-from-wire` | `nonsync` window | GAIN (action decode) |
| `cap100-moves` | `cap100-events` with `--active-players --inputs-from-wire` | `nonsync` window | GAIN (client-event decode, D2) |
| `vis-tick` | `--game-type visibility-test --rooms 10 --players-per-room 5` (no server events, inferred) | `ticks` window, control | within the bar |

- **Bar:** the gate plan's REGRESSION at max(0.5 %, 3 × base's spread), and GAIN below base's min. Time is reported beside it with the old bar, and "layout move (#517)" is printed where time moves but instructions don't.
- **Bytes and digests:** identical in every cell, base = base again = head, with the committed `capture-digest.py`. One extra capture pass runs `cap100-events` and `cap100-actions` with `--format opcode-json-pathhash` and `--format json-object`, so the JSON event frames are covered too (reported, not timed; PR 0 checks that those formats set the message encoding as named).
- **Repeats:** ABBA, a warm-up pair and 5 pairs per cell, for the timed set and the perf set. `SWIFT_DETERMINISTIC_HASHING=1` and the FIFO window in the perf set, in the standing container scope.
- **Before the host:** a Mac direction check on `cap100-events`, ABAB. macOS has no `perf` window, so the check is time plus a `sample` profile of §0's buckets. If the buckets don't shrink, stop and report.
- **The profile after:** a user-only `perf record` per side on `cap100-events`. The §0 buckets (a)–(c) are expected near zero for typed fields.

## 9. Steps

1. **PR 0, on main first:** the benchmark knobs and the `iteration` window (§8); the §0 profile posted on #521.
2. **PR 1, events:**
   - red tests (§7) and the oracle;
   - core: `_PayloadFieldWriter`, `_PayloadWireLeaf` and leaf conformances (core and DeterministicMath), `_PayloadFieldForm`;
   - the macro: `_payloadWireName`, `_writePayloadFields`, `_payloadFieldForms`, and expansion tests;
   - the MessagePack writer and the JSON wrapper; `AnyServerEvent.wireForm`; the encoders switched;
   - the hybrid decision at init (D10); registration checks EV1–EV3; the replay re-emit resolution (N5); `serverEventsMatch` (A6);
   - the docs.
3. **PR 2, decode:** decode sources; the handler table and A4; decode once; client events (D2, N2, N3); records through the source; the differential tests.
4. **PR 3, failure units:** EV4, EV5, EV7 on #535's stop and session-close paths, after #535's mechanism merges. If #535 merges first, this folds into PRs 1 and 2.
5. **Host A/B** per PR, base = main at run time, head = the PR merged with it. PR 0's knobs are on both sides.
6. **Solutions:** an entry on "the positional event payload is name-sorted, not declaration order" if the review agrees it is a trap (#521's text had it the other way). Another entry if the work finds a reusable lesson about encoders that must reproduce a cast chain's per-type forms.

## 10. Open decisions (options and a recommendation each)

- **D1, a stop rule after §0.** (a) None: the reason is architectural (#521). (b) Stop if (a)+(b)+(c) is under some share. **Recommend (a).**
- **D2, client events in scope.** (a) Yes: the same decode mechanism, and it removes the silent skip (A3). (b) Actions only; client events later. **Recommend (a).**
- **D3, where the typed form lives.** (a) `AnyServerEvent` keeps its public shape and carries a package `wireForm`; records and replay are untouched. (b) A typed event value through the whole emit pipeline (`LandContext`, the output collector, the adapter), replacing `AnyServerEvent`: a public break, for one existential box saved. **Recommend (a).**
- **D4, the static name for generic payloads.** (a) A computed static calling the runtime rule (string work per send, generic types only). (b) A per-type cache keyed by `ObjectIdentifier`, behind a lock. **Recommend (a):** there are no generic payloads outside tests.
- **D5, fields without a typed form.** (a) The `Codable` fallback, chosen at compile time, listed in `_payloadFieldForms`, logged at registration. (b) Refuse them, which breaks the monitor's `AnyCodable` and `[TickMismatch]` fields. (c) (a), plus an opt-in strict registration that refuses fallback fields. **Recommend (a);** (c) later if wanted.
- **D6, the JSON encodings.** (a) Keep `JSONEncoder` with a typed wrapper: identical bytes by construction. (b) A hand-written JSON writer: faster, but it must reproduce `JSONEncoder`'s number formatting. **Recommend (a):** the JSON encodings are for debugging and compatibility.
- **D7, MessagePack decode strictness.** (a) The exact typed decode, with every difference from today named (N1). (b) Shims that reproduce the round trip's leniency (an integral float into an integer field, and whatever else the differential finds). **Recommend (a):** it follows `2026-11-09-wire-fed-integer-conversions-must-be-exact-and-throwing.md`, and SDK clients are unaffected.
- **D8, what an action record holds.** (a) The wire payload, as today, built from the source only when recording. (b) The decoded value's `Codable` form, which changes the record bytes for inputs with extra keys or other numeric forms. **Recommend (a):** records stay byte-identical.
- **D9, the unit for an event encode failure.** (a) By target: `.all` closes the land; targeted events close the targeted sessions, with #535's rejoin bound. (b) Always the land, since the failing value comes from the land's own code and a rejoin doesn't bring a missed event back. **Recommend (a),** as #535's scope rule reads; (b) is the simpler alternative if the maintainer considers a missed event uncorrectable by a rejoin.
- **D10, hybrid configs.** (a) Decided at init: events go alone, as their bytes show today. (b) Build 107 bodies with the typed MessagePack writer whatever the message encoder is, which moves those configs' events into the merged frame (a wire change). **Recommend (a).**
- **D11, a positional action wire form.** (a) Not in this plan; a follow-up with the SDK. (b) Accept it now as an alternative form. **Recommend (a).**
- **D12, action responses.** (a) A follow-up issue: the same writer applies to `ResponsePayload`, with its own byte-identity pins. (b) In PR 1. **Recommend (a).**
- **D13, `encodeAsArray()`.** (a) Deprecated, still emitted, removed in a later change. (b) Removed now. **Recommend (a):** it is the oracle for the byte-identity tests and the path of hand-written conformances.

## 11. Related issues

- **#535:** the failure rule and its scope decision; EV4, EV5 and EV7 use its stop and session-close paths. Its sweep gains `serverEventsMatch` (A6) and the client-event skip (A3).
- **#532:** a per-session frame failure, as EV6.
- **#517:** the off-path gate this measurement uses.
- **#519, #520 (#527):** done; the order #521 asks for.
- **#387:** server inputs keep `AnyCodable` (out of scope).
- **#87:** a handler that throws after writing is #535's land-state row; unrelated to decode, which now happens before any handler runs.
