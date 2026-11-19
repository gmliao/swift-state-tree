# #521 PR 1b-2a: hybrid events go alone, decided at init (D10)

**Status:** rev 2, plan only (the code follows on this branch once the plan is reviewed). Rev 2 folds in the review of rev 1 (#638 at 7beeb822: NOT GO, 2 must-fix, 2 should, 1 nit): the tests count both encodes, the verifier test keeps its mixed coverage, a raw hybrid golden is captured on `main` first, a non-deterministic encode is named, and the 107 decision is stored once. This is D10 of #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md), §2.3's encoding table, the hybrid row). It was split out after that plan's rev 18. EV2 and EV3 follow in PR 1b-2b; they don't touch `TransportAdapter`. Read at `main` b7da92fb.

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
  - So a body that fails means a frame that fails the same way. The second encode only repeats the failure on the way to `.lost`. `prepareImmediateSend` encodes before it checks the target (`EventSendingPipeline.swift`), so a stale target doesn't change that, and `pack` only adds checks.
  - **One exception (rev 2):** a payload whose own `Encodable`, or positional writer, throws on the first call and succeeds on the second. Today it is sent alone; after D10 it is lost, and the land ends with `eventEncode`. That is the fail-fast rule for sync errors: an encode that fails is a failure, and a retry that happens to succeed hides an encoder that isn't deterministic. The behaviour change is stated in the PR.
  - `.sentAlone` is reached here only through the test hook's `.mergedBody` fault (:209-212).
- **Hybrid: messages in `json` or `opcodeJsonArray`, state updates in `opcodeMessagePack`.**
  - The body is the JSON frame unpacked as MessagePack (`EncodingPipeline.swift:252-256`). That never yields an array, so it returns nil (the doc comment at :2652-2665 says so).
  - Every event pays a full JSON encode that is thrown away, then encodes again as its own frame.

## Change

Decide once in `TransportAdapter.init`:
- `useStateUpdateWithEvents` becomes a stored `let`, set from the state update encoder's encoding at init. Today it is computed on each read from an injected `any StateUpdateEncoder` (:814). The sync path's 107 decision and the event path's decision then read one value and can't disagree.
- `eventsMerge = useStateUpdateWithEvents && messageEncoder is MessagePackTransportMessageEncoder`.

Both encoders are `let`s (:332-333), so neither answer can change later. In `enqueueEventSynchronously`:

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
  - the fallback comments in `EncodingPipeline.encodeServerEventBody` (:239-246) and in `EventSendingPipeline` say the adapter no longer calls the body encode in a hybrid configuration, and that a nil body there is a loss;
  - `EventEnqueueOutcome.sentAlone` (:2722-2723) becomes "sent as its own frame (a hybrid configuration)";
  - `ReevaluationUnmergedEvents.sentAlone` (`ReevaluationSyncStream.swift:174`) becomes "sent as their own frame: in a hybrid configuration every event; otherwise none, since an event that doesn't encode is lost".
- **The public `ReevaluationUnmergedEvents.sentAlone` stays.** A hybrid record still lists every event there, so the verifier's reading of old and new records is the same. There is no record format change and no API change.

**Prior art:** this is the Strategy pattern bound once at construction (Gamma et al., *Design Patterns*, 1994), in the way Netty builds a channel's encoder pipeline in `initChannel` instead of choosing a codec per message. The configuration can't change after init, so a per-call choice only repeats a failure that is known in advance.

## Tests

**First, on `main`, before any D10 code (rev 2):** no hybrid golden exists (`git grep` finds no hybrid capture under `Tests/`), and the differential harness compares decoded output, not bytes. So the order is:
1. Capture, in a commit on this branch made from `main`'s code, the raw frames a hybrid land sends (`json` and `opcodeJsonArray` messages, `opcodeMessagePack` state updates), and its record's `eventsNotMerged`. Use a small land: one tick emits to `.all`, to `.players([])` and to one player.
2. Verify D10 against those captures, byte for byte.
3. Merge D10 before the adapter rewrite records its freeze captures. If a freeze capture is already taken, compare D10 with it and name any delta in the PR.

**Counting both encodes (rev 2).** A package counting hook counts the two entry points separately: the merged body (`encodeServerEventBody`) and the event's own frame (`prepareImmediateSend`'s encode). The tests assert the pair:
- **hybrid** (both message encodings): `(body, ownFrame) == (0, 1)` per event. The outcome is `.sentAlone`, and the frames equal the captures above;
- **MessagePack, a payload that really fails conversion:** an untyped dictionary through the package hook `emitAnyServerEventForTesting` (the positional writer throws `UntypedPayloadError`). The pair is `(1, 0)`, the outcome `.lost`, and the land ends with `eventEncode`. The test hook's `.all` can't drive this case: it throws before either encoder runs (`failsEncoding`);
- **MessagePack, an event that merges:** `(1, 0)` with the outcome `.queued`, and the event is in the next merged frame (opcode 107). This pins the routing for the inversion mutant;
- **the merged-frame pack fault test stays:** packing the batch can still fail after every body converted, and that path is unchanged.

**The moved tests (rev 2):**
- `SyncOutputVerifierTests.unmergedEventIsUnverifiable` (:1204). Its land emits three events every tick (:117-119), and today's fault is on for the middle tick only. That gives `[0, 3, 0]` unmerged, `events.compared == 2` and `unverifiable == 1`. On a hybrid fixture every tick's events go alone. So the hybrid version gates the land's emission to the middle tick, and the outputs before and after it emit nothing and stay compared. It then asserts the same mix: one unverifiable output between two compared ones.
- `TransportAdapterSyncPhaseTests` (:823) keeps two arms:
  - the sent-alone arm runs on a hybrid fixture;
  - the loss arm runs on real MessagePack with the dictionary payload above, instead of the `.mergedBody` fault.

**Old records:** a hybrid record written before the change (the capture above) reads and verifies with the same verdict and counts.

**Mutants:**
- the init decision ignored, so the body is attempted in hybrid: the pair becomes (1, 1);
- the second encode put back for MessagePack: the pair becomes (1, 1);
- `eventsMerge` inverted: the merge test fails;
- `useStateUpdateWithEvents` computed per call again: no test can see it while the encoders are `let`s, so it is a review item, not a mutant.

**Runs:**
- the touched suites;
- the full `swift test` in its three modes, since the adapter is core;
- both E2E scripts on CI.
