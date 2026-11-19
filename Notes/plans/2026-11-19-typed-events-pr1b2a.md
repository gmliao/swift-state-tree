# #521 PR 1b-2a: hybrid events go alone, decided at init (D10)

**Status:** rev 1, plan only (the code follows on this branch once the plan is reviewed). This is D10 of #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md), §2.3's encoding table, the hybrid row). It was split out after that plan's rev 18. EV2 and EV3 follow in PR 1b-2b; they don't touch `TransportAdapter`. Read at `main` b7da92fb.

**Ordering:** this PR changes `TransportAdapter`'s event path, so it lands before the golden captures for the adapter's rewrite are recorded. Frames and records don't change (below), so the captures are the same whether they are recorded before or after it.

## Today (checked by reading)

The merged frame (opcode 107) is on when state updates are encoded as `opcodeMessagePack` (`TransportAdapter.swift:814`). `enqueueEventSynchronously` (:2684) handles each event:

1. It encodes a merged body (`EncodingPipeline.encodeServerEventBody`, :247).
2. If the body encodes, the event is queued for the next merged frame: the outcome is `.queued`, or `.noRecipient` when the target is empty.
3. If the body fails, the event is encoded again as its own frame (`sendEventImmediately`, :2868). The outcome is `.sentAlone` when that succeeds, or when the target is stale. It is `.lost` when that fails too.
4. A lost event ends the land (#535 row 17; :2776-2786, and `sendEvent` :2666).

Each sequence is recorded by its outcome: `.sentAlone` events under the output's `eventsNotMerged.sentAlone`, `.lost` events under `.lost`. The verifier marks that output's events unverifiable (`SyncOutputVerifier.swift:486-498`).

There are two kinds of configuration, and the body behaves differently in each:

- **Messages in `messagepack`.**
  - The body is `encodeToArray` → `anyCodableToMessagePackValue` (`MessagePackTransportMessageEncoder.swift:52-63`). The event's own frame is the same two steps, then `pack` (:36-44).
  - So a body that fails means a frame that fails the same way. The second encode only repeats the failure on the way to `.lost`.
  - `.sentAlone` is reached here only through the test hook's `.mergedBody` fault (:209-212).
- **Hybrid: messages in `json` or `opcodeJsonArray`, state updates in `opcodeMessagePack`.**
  - The body is the JSON frame unpacked as MessagePack (`EncodingPipeline.swift:252-256`). That never yields an array, so it returns nil (the doc comment at :2652-2665 says so).
  - Every event pays a full JSON encode that is thrown away, then encodes again as its own frame.

## Change

Decide once in `TransportAdapter.init` whether events can merge: `eventsMerge = useStateUpdateWithEvents && messageEncoder is MessagePackTransportMessageEncoder`. Both encoders are `let`s (:332-333), so the answer can't change later. In `enqueueEventSynchronously`:

| Configuration | Today | After |
|---|---|---|
| Opcode 107 off | its own frame: `.immediate` or `.lost` | unchanged |
| Hybrid (107 on, messages not MessagePack) | body attempt (fails), then its own frame: `.sentAlone` (also for a stale target) or `.lost` | its own frame, with no body attempt: `.sentAlone` or `.lost`, as today |
| 107 on, messages in MessagePack | body: `.queued` or `.noRecipient`; on failure, its own frame: `.sentAlone` or `.lost` | body: `.queued` or `.noRecipient`; on failure, `.lost` at once, after one encode |

- **Nothing on the wire or in the record changes:**
  - hybrid events go out with today's bytes, in today's order, under today's outcome;
  - an event that doesn't encode is still lost and ends the land with `eventEncode`.
- **The fault hook:** `EventEncodingFault.mergedBody` goes away, since a body failure now means the event is lost. `.all` stays. The two tests that used `.mergedBody` to get a sent-alone event (`SyncOutputVerifierTests.swift:1209`, `TransportAdapterSyncPhaseTests.swift:823`) get one from a hybrid fixture instead.
- **Docs:**
  - the doc comment on `sendEvent` (:2652-2665) says the hybrid decision is made at init, and that a MessagePack body failure is a loss;
  - `EventEnqueueOutcome.sentAlone` (:2722-2723) becomes "sent as its own frame (a hybrid configuration)";
  - `ReevaluationUnmergedEvents.sentAlone` (`ReevaluationSyncStream.swift:174`) becomes "sent as their own frame: in a hybrid configuration every event; otherwise none, since an event that doesn't encode is lost".
- **The public `ReevaluationUnmergedEvents.sentAlone` stays.** A hybrid record still lists every event there, so the verifier's reading of old and new records is the same. There is no record format change and no API change.

**Prior art:** this is the Strategy pattern bound once at construction (Gamma et al., *Design Patterns*, 1994), in the way Netty builds a channel's encoder pipeline in `initChannel` instead of choosing a codec per message. The configuration can't change after init, so a per-call choice only repeats a failure that is known in advance.

## Tests

- **Hybrid (`json` and `opcodeJsonArray` messages):**
  - every event's outcome is `.sentAlone`;
  - a counting hook on the body encode sees zero calls;
  - the frames equal today's (the existing hybrid goldens, or new ones captured on `main` before the change);
  - the record's `eventsNotMerged.sentAlone` lists every event, and the verifier's verdict and counts are as before.
- **MessagePack:** an event whose payload doesn't encode is `.lost` after one encode (the counting hook sees one call), and the land ends with `eventEncode`.
- **The moved tests** pass on a hybrid fixture with the same assertions.
- **Mutants:**
  - the init decision ignored, so the body is attempted in hybrid (the count test fails);
  - the second encode put back for MessagePack (the count is 2);
  - `eventsMerge` inverted (merged frames break).
- **Runs:** the touched suites; the full `swift test` in its three modes, since the adapter is core; and both E2E scripts on CI.
