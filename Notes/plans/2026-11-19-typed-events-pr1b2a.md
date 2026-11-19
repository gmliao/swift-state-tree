# #521 PR 1b-2a: hybrid events go alone, decided at init (D10)

**Status:** rev 4, plan only (the code follows once the plan is reviewed). Rev 4 folds in the review of rev 3 (#638 at 075a70b0: NOT GO, 1 must-fix, 4 should, 1 nit): a real pre-D10 record is committed and replayed, the golden pins typed leaf values and waits for its joins by event, the capture's text is corrected, and the reason for the stored decision is restated. Rev 3 folded in the review of rev 2 (#638 at 3fd95d38: NOT GO, 3 must-fix, 3 should, 1 nit): the order after #632, a dedicated land for the gated verifier test, the record header's 107 decision read from the stored value, the counters' places, the capture window, and the parity claim scoped to deterministic encoders. Rev 2 folded in the review of rev 1 (#638 at 7beeb822: NOT GO, 2 must-fix, 2 should, 1 nit): the tests count both encodes, the verifier test keeps its mixed coverage, a raw hybrid golden is captured on `main` first, a non-deterministic encode is named, and the 107 decision is stored once. This is D10 of #521's plan ([`2026-11-13-typed-events-actions.md`](2026-11-13-typed-events-actions.md), §2.3's encoding table, the hybrid row). It was split out after that plan's rev 18. EV2 and EV3 follow in PR 1b-2b; they don't touch `TransportAdapter`. Read at `main` b7da92fb.

**Ordering (rev 3):**
- **After #632.** The MessagePack loss test uses #632's package hook `emitAnyServerEventForTesting`, which replaces the public `LandContext.emitAnyServerEvent` (`main`'s `LandContext.swift:245`). So D10's code branches from `main` after #632 merges. The capture commit below holds no D10 code and is carried over.
- **Before the adapter rewrite's goldens.** This PR changes `TransportAdapter`'s event path, so it lands before the golden captures for the adapter's rewrite are recorded. Frames and records don't change (below), so the captures are the same whether they are recorded before or after it.

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
- `useStateUpdateWithEvents` becomes a stored `nonisolated let`, set from the state update encoder's encoding at init. Today it is computed on each read from an injected `any StateUpdateEncoder` (:814).
- `syncConfigForRecord` (:86-88) reads it too (rev 3). Today it computes `stateUpdateEncoder.encoding == .opcodeMessagePack` live, and sets the record's `mergedBroadcastFrame`, which the verifier reads. So the record header, the sync path and the event path read one value and can't disagree.
- `eventsMerge = useStateUpdateWithEvents && messageEncoder is MessagePackTransportMessageEncoder`.

Both encoders are `let`s (:332-333), so neither answer can change later. In `enqueueEventSynchronously`:

| Configuration | Today | After |
|---|---|---|
| Opcode 107 off | its own frame: `.immediate` or `.lost` | unchanged |
| Hybrid (107 on, messages not MessagePack) | body attempt (fails), then its own frame: `.sentAlone` (also for a stale target) or `.lost` | its own frame, with no body attempt: `.sentAlone` or `.lost`, as today |
| 107 on, messages in MessagePack | body: `.queued` or `.noRecipient`; on failure, its own frame: `.sentAlone` or `.lost` | body: `.queued` or `.noRecipient`; on failure, `.lost` at once, after one encode |

- **Nothing on the wire or in the record changes, for an encoder that gives the same result each time** (rev 3):
  - hybrid events go out with today's bytes, in today's order, under today's outcome. Hybrid goes from two encodes per event to one, so an encoder with state (one that counts its calls, say) could give other bytes or another outcome once the discarded body attempt is gone. The framework's encoders have no such state;
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
1. Capture, in a commit made from `main`'s code, the raw frames a hybrid land sends (`json` and `opcodeJsonArray` messages, `opcodeMessagePack` state updates), and its record's `eventsNotMerged`. Done (rev 3): `HybridEventFrameGoldenTests` and `Fixtures/HybridEventFrames/`, one file per sync path (in-turn and legacy, run under CI's three settings), recorded at `main` b7da92fb with no D10 code. The window:
   - **Land:** each tick sets its state (`ticks += 1`) and emits to `.all`, to `.players([])` and to `.player(p1)`, then requests a sync. `OnInitialize` emits nothing.
   - **Cells:** `json` and `opcodeJsonArray` messages, each with event hashes off and on. Session, client and player IDs are pinned (`s1`/`c1`/`p1`, `s2`/`c2`/`p2`). The environment's sync options are given, not read: sync tables on, per-player tables off, and (rev 4) typed leaf values on, since an explicit `TransportEnvConfig` still inherits `TYPED_LEAF_VALUES` (the sync-tables-off CI job sets it to false).
   - **Steps:** both players join (their first sync frames are in the capture), two ticks, then one `sendEvent` to `c1` from outside a turn. After each step the test waits for the outbound writer by its event (`waitForOutboundIdleForTesting`); rev 4: the joins too, with `simulateRouterJoin`'s steps inlined, since that helper polls.
   - **Captured per session, in send order.** The order between sessions follows a dictionary and isn't stable, so it isn't recorded.
   - **Expected, and seen:** for each tick, `s1` gets the `.all` frame and the `.player(p1)` frame alone, in emission order, then the 107 frame with an empty event array. `s2` gets the `.all` frame, then the 107 frame. `.players([])` is the second emission: it has no frame, and its sequence is in the tick's `sentAlone` list at index 1 (`[0, 1, 2]`), then 4 (`[3, 4, 5]`) (rev 4). **The record part holds for the in-turn path only:** the legacy path's file has `eventsNotMerged: []` for every output, so it covers the frames.
   - **Stable:** a second recording in the same process gives the same bytes (a test), on both sync paths under CI's three settings.
2. Verify D10 against those captures, byte for byte.
3. Merge D10 before the adapter rewrite records its freeze captures. If a freeze capture is already taken, compare D10 with it and name any delta in the PR.

**Counting both encodes (rev 2).** A package counting hook counts the two entry points separately (rev 3, where each counter sits):
- the body: at the entry of `EncodingPipeline.encodeServerEventBody` (:247), before it dispatches. The MessagePack encoder's method of the same name never sees a hybrid attempt, so a counter there would miss one;
- the event's own frame: immediately before `messageEncoder.encode` in `EventSendingPipeline.prepareImmediateSend`, so an encode that throws still counts.

The tests assert the pair:
- **hybrid** (both message encodings): `(body, ownFrame) == (0, 1)` per event. The outcome is `.sentAlone`, and the frames equal the captures above;
- **MessagePack, a payload that really fails conversion:** an untyped dictionary through #632's package hook `emitAnyServerEventForTesting`, on a fixture with payload compression on. The bare encoder init defaults it off and the `.messagepack` config turns it on (`MessagePackTransportMessageEncoder.swift:32, 277-280`; `TransportEncodingConfig.swift:56, 286`). With it on, the body path throws `UntypedPayloadError` at the `PayloadCompression` cast. The pair is `(1, 0)`, the outcome `.lost`, and the land ends with `eventEncode`. The test hook's `.all` can't drive this case: it throws before either encoder runs (`failsEncoding`). The outside-turn arm passes the same `AnyServerEvent` to `adapter.sendEvent`, so its `.eventFlush` assertion stays;
- **MessagePack, an event that merges:** `(1, 0)` with the outcome `.queued`, and the event is in the next merged frame (opcode 107). This pins the routing for the inversion mutant;
- **the merged-frame pack fault test stays:** packing the batch can still fail after every body converted, and that path is unchanged.

**The moved tests (rev 2):**
- `SyncOutputVerifierTests.unmergedEventIsUnverifiable` (:1204). Its land emits three events every tick (:117-119), and today's fault is on for the middle tick only. That gives `[0, 3, 0]` unmerged, `events.compared == 2` and `unverifiable == 1`. On a hybrid fixture every tick's events go alone, so the hybrid version keeps the mix another way.
  - **Its own land definition (rev 3), used both to record and to replay.** The replay helper rebuilds `makeVerifierLand()` (:423; :194 builds the recording fixture), which emits on every tick and in `OnInitialize` (:99-103). In a hybrid configuration that init event goes alone too, and adds an unverifiable output.
  - The dedicated land emits only when the recorded state says so (`ticks == 2`), emits nothing in `OnInitialize`, and keeps the sync request on all three ticks. `makeVerifierLand()` is unchanged for the other tests.
  - An output with no events still gets an events hash (`commitSyncPhase` records `hash([])` when `useStateUpdateWithEvents`, `TransportAdapter.swift:4046-4053`, :3781), and the verifier compares it (`SyncOutputVerifier.swift:485-503`). So the test asserts compared, unverifiable, compared: `events.compared == 2`, `unverifiable == 1`.
- `TransportAdapterSyncPhaseTests` (:818-829) keeps two arms. Today the sent-alone arm uses the `.mergedBody` fault, and the outside-turn loss arm uses `.all` (rev 3: rev 2 had these swapped):
  - the sent-alone arm runs on a hybrid fixture, with no fault;
  - the loss arm runs on real MessagePack with the dictionary payload above, instead of `.all`.

**Old records (rev 4):** a real record written by `main`'s code, before D10, is committed as `Fixtures/HybridEventFrames/hybrid-record.sstr`. It is the golden land's in-turn run, `json` messages, event hashes off; the `opcodeJsonArray` cell writes the same bytes, since a record doesn't hold the message encoding. Its bytes aren't compared: a test replays it (`ReevaluationEngine.run`), and today gives:
- ticks 0 and 1, with every recorded state hash matched and no server event mismatch;
- `eventsSentAlone == 6`, `eventsLost == 0`;
- the sync output verdict `partial`, with events `compared 0 / unverifiable 2 / skipped 0` (each tick's events went alone).

After D10 the same test must pass unchanged on the same file.

**Mutants:**
- the init decision ignored, so the body is attempted in hybrid: the pair becomes (1, 1);
- the second encode put back for MessagePack: the pair becomes (1, 1);
- `eventsMerge` inverted: the merge test gives (0, 1) with no merged event, and fails;
- `syncConfigForRecord` computed live again: the framework's state update encoders return a constant `encoding`, so no test sees a difference;
- `useStateUpdateWithEvents` computed per call again: the same. These two are review items, not mutants (rev 4). A `let` existential fixes which encoder is used, but `StateUpdateEncoder.encoding` is a protocol getter that a conformer could compute. The stored value is right because it pins the decision once, whatever that getter does.

**Runs:**
- the touched suites;
- the full `swift test` in its three modes, since the adapter is core;
- both E2E scripts on CI.
