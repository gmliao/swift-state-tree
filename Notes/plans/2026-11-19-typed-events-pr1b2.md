# #521 PR 1b-2: the hybrid event path decided at init, and the event name checks (D10, EV2, EV3)

**Status:** rev 1, plan only. Split out of #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md)) at its rev 18: PR 1b (#632) is the replay closure only. That plan's D10 row (§2.3, the encoding table), EV2 and EV3 (§5's table, N8) and their tests (§7) are the design. This note settles what rev 18 left open and corrects one of its statements. Read at `main` b7da92fb.

## Scope

- **D10:** in a hybrid configuration, server events go alone, decided once when the adapter is built. No merged body is attempted per event.
- **EV2:** for each registered server event type, the wire name (`_payloadWireName`, `EventPayload.swift:25`, overridable) equals the registry's name, which is the schema ID (`payloadEventName`, `SchemaExtractor.swift:218`). It is refused at registration otherwise.
  - **Two types under one event name** (found in #632's review). The registry maps a name to its descriptor, and a later registration of the same name replaces the earlier one (`EventRegistry`'s name index). So the replay decodes into the last type, and the live wire sends both under one name, which a client can't tell apart. EV2 also refuses a name that two registered types share, naming both types.
- **EV3:** when the host passes `eventHashes`, a registered server event missing from it is refused at registration (N8 (a)). Today it is sent with its string name (`MessagePackTransportMessageEncoder.swift:224`, `TransportMessageEncoder.swift:293`), which a client built from that schema doesn't know.

EV2 and EV3 are rows in `LandDefinition.validateForRegistration(context:)`, reported in `PayloadRegistrationError`, at §5's entry points. EV3 needs the host's `eventHashes` in `LandRegistrationContext`. None of this touches replay or the record codec.

## Where events go alone today (checked by reading)

The merged frame (opcode 107) is on when the state update encoding is `opcodeMessagePack` (`TransportAdapter.swift:814`). Each event first tries a merged body (`EncodingPipeline.encodeServerEventBody`, :247). If that fails, it tries its own frame: `.sentAlone` when that succeeds, `.lost` otherwise, and a lost event ends the land (#535 row 17; `TransportAdapter.swift:2696-2709`, :2776-2786).

- **Messages in `messagepack`.** The body is `encodeToArray` → `anyCodableToMessagePackValue` (`MessagePackTransportMessageEncoder.swift:52-63`). The event's own frame is the same two steps, then `pack` (:36-44). A body that fails therefore means a frame that fails the same way, and the second try only repeats the failure on the way to `.lost`. `.sentAlone` is reached here only through the test hook's `.mergedBody` fault (`TransportAdapter.swift:209-212`).
- **Hybrid (messages in `json` or `opcodeJsonArray`, state updates in `opcodeMessagePack`).** The body is the JSON frame unpacked as MessagePack (`EncodingPipeline.swift:252-256`). The first byte, `[` or `{`, is a positive fixint, so the unpack never yields an array and the body always fails. Every event then goes alone, and the record lists every one of them under `eventsNotMerged.sentAlone`.

## The three questions

### 1. Does the fail-fast rule make "tried alone" dead?

**Partly.** It removes the retry, but not the alone path.

- **With `messagepack` messages,** the retry is dead. A body failure is the event's encode failure, which already ends the land, so the retry adds nothing but a second encode.
- **In a hybrid configuration,** going alone is the only path an event has. What dies there is the body attempt, which can never succeed.

**Recommendation:** decide once at adapter init.
- Hybrid: every event is sent as its own frame, with no body attempt. The outcome stays `.sentAlone`, so the bytes, the order and the record are as today.
- Otherwise: a body that fails is `.lost` at once, with no second encode. The land ends as it does today, one encode sooner.
- The test hook's `.mergedBody` fault goes away. Its two users (`SyncOutputVerifierTests.swift:1209`, `TransportAdapterSyncPhaseTests.swift:823`) get their sent-alone events from a hybrid fixture instead.
- A counting hook pins that no body encode is attempted in hybrid (plan §7, "Hybrid config (D10)").

### 2. What do old records' `sentAlone` entries mean to the verifier?

**The same as in new records: events sent as their own frame, so missing from that output's merged frame.** The verifier counts them (`eventsSentAlone`, `SyncOutputVerifier.swift:488`), removes them from the pending events, and marks that output's events unverifiable (:496-498), which makes the verdict `partial`.

- **In an old record from a hybrid run,** they are every event, as in a new one. Its outputs read and verify as before.
- **In an old record from a `messagepack` run,** they appear only if a test's fault produced them, and they keep that meaning.

So no reader changes. The record format version doesn't change either: the outcomes recorded under D10 are the outcomes recorded today.

### 3. Does the public `ReevaluationUnmergedEvents.sentAlone` stay or go?

**Recommendation: it stays, and it isn't always empty.** Rev 18 of #521's plan said D10 would leave it empty in every new record (its "PR 1b is the replay closure only" bullet, following §2.3's "the per-event `.sentAlone` outcome goes away"). That is wrong. A hybrid run still sends every event alone and records each one there. What goes away is the failed body attempt per event, not the outcome. Removing the field would drop a hybrid record's only account of its events, so nothing goes to the maintainer and nothing in the API breaks.

The field's doc comment should say which configuration fills it: "Sent as their own frame: in a hybrid configuration every event; otherwise none, since an event that doesn't encode is lost."

## Not in scope

- **Verifying a hybrid run's events.** Its outputs' events stay unverifiable (verdict `partial`), as today. The recorder could digest the alone-sent events in order and compare them. That would change what a record holds and needs its own plan.
- The verifier's false mismatch (#633) and the value-type redesign (#637).

## Tests

These are #521's plan §7 for D10, EV2 and EV3, plus:

- **Hybrid:**
  - every event's outcome is `.sentAlone`;
  - the counting hook sees no body encode;
  - the frames are byte-identical to today's (goldens);
  - the record's `eventsNotMerged.sentAlone` lists every event, as before.
- **`messagepack`:** an event whose payload doesn't encode is `.lost` after one encode (the counting hook sees one), and the land ends with `eventEncode`.
- **Old records:** a hybrid record written before the change reads and verifies with the same verdict and counts.
- **Mutants:**
  - the hybrid decision ignored, so a body is attempted (the counting test fails);
  - the second encode put back (the count is 2);
  - each of EV2 and EV3 switched off.
