# Replay on typed inputs and the keeper's turns (#612, with #550)

**Status:** rev 4, design for review.
- **S0 is done:** GO at rev 2, merged as #675 (4fbe76c6). §6 S0 records what it did.
- **Rev 4** answers rev 3's review: 6 must-fix, 12 should and 3 nits, in #612 issuecomment-7026974327. What changed is in §14. Rev 3's changes are in §13.
- **Every statement about today's code** was checked again at 4fbe76c6 for rev 4. `Sources/` and `Examples/` haven't changed since then on `main`.
- **No code** for S1–S6 until this plan is GO, the maintainer has answered §9, and each step's prerequisites (§8) have merged.

**Issue:** #612. #550 is folded in (maintainer, 2026-11-20). This plan answers #550's question and #546 L2's group 5 ("reevaluation keepers: in-turn, or a replay-only cycle"). S0 settled group 5: no adapter is bound to a reevaluation keeper.

**Base:** `main` at 4fbe76c6, which includes S0. Line pointers are at that SHA unless marked.
- "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.
- "LM" is `Sources/SwiftStateTreeTransport/LandManager.swift`.
- "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`.
- "RF" is `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`.
- "RL" is `Sources/SwiftStateTree/Runtime/ReevaluationRecordLog.swift`.
- "SV" is `Sources/SwiftStateTree/Runtime/SyncOutputVerifier.swift`.

**Inputs read:**
- #612 and the issues it names, and #550;
- #521 and its plan (`2026-11-13-typed-events-actions.md`, rev 20);
- #606 with its strict-decode decision (2026-11-18);
- #546's plan, rev 13 (`2026-11-19-adapter-turn-core-rewrite.md`): §3.2 L1, L2 with groups 2a–2e, the standalone initial sync "outside L2", and B2 decision 5;
- the turn core plan (`2026-11-18-swift-state-turns-core.md`);
- #387's plan (`2026-11-09-server-turn-inputs.md`).

**Ownership with #546 (Main, 2026-11-20).** These are #546's, and this plan lists them as dependencies, not as its steps (§8):
- keepers with no port, live: L2 group 2e;
- live keepers with fake transports: L2 group 2d;
- the standalone initial sync: B2's `.initialSyncCommit`, then B3.

#546 rev 13 says the same (L2 2e; "Outside L2: the standalone initial sync").

**Solutions consulted:** `Notes/solutions/` has no entry for replay identity, record readers or mode flags. The reentrancy rule in CLAUDE.md and `2026-11-05-reentrancy-helpers.md` applies to the run's step and to the run service (§3.4, §5.4). `2026-11-09-an-id-a-client-can-build-is-not-an-authorization.md` applies to the replay ticket (§5.5).

## 1. Goal

Replay feeds the recorded inputs into the same keeper turn a live land runs, in recorded order and at the recorded boundaries. Each run sends the turn's outputs where it needs them.

- **One machine.** A replaying keeper runs one synchronous turn entry point (§3.3), the one a live keeper runs too. There's no `LandMode`, and no apply-path branch on being a replay.
- **One input source per keeper,** chosen at construction: live intake (transport, router, server inputs), or replay, whose intake is closed and whose batches `ReplayRun` reads from its record cursor.
- **Outputs:**
  - the sync phase runs through a transport port when one is attached;
  - observers read each turn's outcome: the recorder, the turn comparator and the sync-output check.
- **No second land type:** no `-replay` suffix, no alias in `LandTypeRegistry`, and no keeper mode resolver beyond the ticket gate.

What this plan doesn't change:
- the live path's behaviour and its bytes to clients;
- the record as the only source of a replay's inputs;
- the rule that game logic reads time only as a tick ID (`LandContext.swift:99`);
- the record's byte identity (#327, §5.1).

## 2. Today (after S0)

### 2.1 Recording (live)

- **When it records.** The recorder exists when `mode == .live && enableLiveStateHashRecording` (LK init).
- **Turn records.** The keeper's tick turn (`runTickTurn`, LK:4705) builds a `ReevaluationTickRecord` (`makeTurnRecord`) on every tick turn, recorder or not. It submits it after the turn (LK:4796). The input drain does the same per batch (`runInputDrain`, LK:5381–5393). The legacy path records from `processPendingActions` and `flushOutputs`.
- **The state hash** of a turn is computed when `enableLiveStateHashRecording && reevaluationRecorder != nil`. The in-turn tick sets it at LK:4741, the legacy tick at :4555 and the single-input turn at :2713. The initialize record (`makeInitializeRecord`, built only with a recorder, LK:1196–1199) hashes under `enableLiveStateHashRecording` (:4844). None of these depends on where the sync runs.
- **The sync stream** is recorded when `recordsSyncStream` holds: `mode == .live && reevaluationRecorder != nil && usesInTurnSync` (LK:4881).
- **Sync stream.** The adapter submits it as drafts, and only with in-turn sync.
- **Metadata.**
  - The land ID enters the keeper's init (LM:623). `setLandID` at LM:628 sets it again.
  - The recorder's metadata is set in `LandManager.buildLand` after the adapter exists (`setMetadata`, LM:703), with `recordsSyncStream` and `syncConfig` from the adapter.
  - Then `holds.at(.wiring)` and `setTransport` run (LM:715–716).
  - A later header replaces an earlier one (RL).
- **Payloads.** Inputs are recorded as `AnyCodable` (`ActionRecorder.swift`), and so are resolver outputs. A join records `PlayerSession` fields and `metadata: [String: String]` (`ActionRecorder.swift:400–412`). Server inputs pass through `ServerInputCodec.recordedForm` even when nothing records (LK:3104), as their canonicalization and size check.
- **Format.** 3.6 by the metadata version, but the preamble writes `(3, 5)`. The encoding is canonical MessagePack.
- **The reader** takes the whole file (RL:240–347):
  - it assembles late entries under older ticks;
  - it drops the newest tick when the footer is missing or `complete == false`, which it learns only at EOF;
  - it cuts the sync stream to its dense prefix.

### 2.2 Headless verification (CLI runner and monitor)

Two near-copies drive a `.reevaluation` keeper without a transport:
- `ReevaluationEngine.run` (`ReevaluationEngine.swift:200–432`), used by the example `ReevaluationRunner` executables;
- `ConcreteReevaluationRunner` (`ReevaluationRunnerImpl.swift:94–523`), stepped by `ReevaluationRunnerService` for the monitor land.

How a run goes:
- Both runners read the max tick, the whole sync stream, completeness and the land failure before tick 0.
- They call `stepTickOnce()` per recorded tick. The keeper pulls that tick's inputs from its `ReevaluationSource` through several per-tick getters (`ActionSource.swift:6–67`), and the verifier queries the same tick again.
- The keeper treats a failed max-tick read as EOF. It logs a failed tick read and goes on.
- OnInitialize is intercepted by `replayInitializeBeforeTickZero`. Without that, the keeper's init starts initialization eagerly (`Task { try? await self.ensureInitialized() }`, LK:988–991).
- With no transport, `usesInTurnSync` (LK:672) is false, so the run takes the off path: `processPendingActions` or `replayRecordedPasses`.
- Sync outputs are verified by a shadow `SyncEngine` (SV), which re-plans each recorded output from the replayed state and the record's ordered seed and clear markers. A skipped scope makes the verdict `.partial` (SV:850).

The monitor land reads the service's status under a lock on a 100 ms tick (`ReevaluationMonitorLand.swift:28–71`), the mailbox exception named in CLAUDE.md.

### 2.3 Replay viewing

- **`registerWithGenericReplay`** (RF) is the only registration since S0. GameServer uses it (`main.swift:171`, :194, :225).
- The replay land is `GenericReplayLand` (`GenericReplayLand.swift:50–133`), a live keeper of a separate definition, registered as `<type>-replay`.
- Its services start a headless run. Each tick it pops one result, assigns the decoded state (state → `fullStateSnapshot` → JSON → `init(fromBroadcastSnapshot:)`), requests a broadcast-only sync and re-emits the recorded events typed (#632).
- Viewers get the broadcast view only.
- Its ticket gate is `injectingGenericReplayKeeperModeResolver`, through `replayTicketGatedResolver`.

### 2.4 Who reaches the keeper's off path, and who owns each

| Caller | Owner |
|---|---|
| The two headless runners (`.reevaluation`, no transport) | #612 S2 (`ReplayRun`) |
| Keeper-side tests that attach a fake transport to a `.reevaluation` keeper: `ReplaySequenceWatermarkTests`, `ServerInputTests`, `ShutdownTurnTests`, `TicklessReplayPassTests`, `LandKeeperReevaluationOutputModeTests`, and the others among the 9 keeper-side `.reevaluation` files | #612 S2 (converted to `.record` keepers) |
| Live keepers with no port: `ReevaluationRunner/main.swift:452` (a live recording keeper), `HashCostBenchmark.swift:50`, about 19 core test files | #546 L2 group 2e |
| Live keepers with fake transports (19 files, `MockLandKeeperTransport` included) | #546 L2 group 2d |
| Live keepers with `IN_TURN_SYNC=false` | #546 L1 |
| The adapter's own cycle on live lands (`syncNow`, the follow-up, the backlog retry, the lag timer, the freeze) | #546 L2 groups 2a–2c |

**The standalone initial sync** (`_syncStateForNewPlayer`, a `runSyncPhase(isSyncCycle: false)` commit) uses no `beginSync`/`endSync`, so it isn't the keeper's off path. It is #546's: B2's `.initialSyncCommit`, then B3. Rev 2 called it an L2 item, which was wrong.

## 3. Shape

```
             ┌──────────────── input source (exactly one) ─────────────────┐
             │ live intake: transport, router, submitServerInput           │
             │ replay: ReplayRun's record cursor, validated, in order      │
             └──────────────────────────┬──────────────────────────────────┘
                                        │ TurnBatch (§3.1)
                                        ▼
       ┌───────────────────── LandKeeper.runTurn(batch) ─────────────────────┐
       │ synchronous, in this order (§3.3): W1, deltas, inputs, W2,          │
       │ tick handler, committed tick and hash, sync phase through the port  │
       │ (if attached), outcome. No waiter is resumed here.                  │
       └───────────┬──────────────────────────────────┬──────────────────────┘
                   │ sync phase (port)                │ TurnOutcome (final)
                   ▼                                  ▼
          TransportAdapter (clients)        drain: record submit, then waiters (live)
          or no port                        observers: recorder (live)
                                                       TurnComparator (replay)
                                                       SyncOutputCheck (replay)
```

### 3.1 The input source and the record cursor

A keeper is built with an `InputSource`:
- **`.live`:** today's intake: `submitAction`, client events, joins and leaves through the router, and `submitServerInput` (#387).
- **`.replay`:** the public intake is closed. Every live entry point refuses with one reason, `.replaying`. That covers `join`/`joinReportingAdmission`, actions, client events, server inputs and leaves. It replaces #387's `.notLive` and the mode checks in the client-event, action and server-input intake. The keeper doesn't start initialization (§3.3), and it holds no cursor.

**One owner for the cursor.** `ReplayRun` owns the `RecordCursor`. It reads and validates each boundary and hands the batch to the keeper's `runTurn` (§3.3, §3.4). The keeper never reads the record.

**The cursor yields boundaries, and each boundary is a `TurnBatch`:**

| Kind | Carries | Today's counterpart |
|---|---|---|
| `.initialize` (only when the land has OnInitialize) | the recorded resolver outputs for OnInitialize, and its outputs (events, state hash) | the initialize entry. A land with no `onInitialize` writes none (LK `performInitialization`) |
| `.tick(id)` | its membership deltas, its inputs in applied order (lifecycle items among them), the watermarks W1 (read at turn start) and W2 (read after the inputs), and the recorded outcome (rejected inputs, failure position, events, state hash) | one tick turn record |
| `.pass(tick, ordinal)` | a tickless land's membership deltas and inputs for one pass, its watermark and its outcome. A tickless land records every pass under tick 0 (`executingTickIdForPendingItems` moves `nextTickId` to 1 once, LK:3384–3397), so one tick usually holds the whole run. The ordinal is land-wide | #325's passes |
| `.syncOnly(observedTick, afterPass, readPosition)` | no inputs; the recorded sync outputs it produced. `afterPass` and the read position place it between two passes of one tick | sync-only turns, stream `turnKind .syncOnly` (`ReevaluationSyncStream.swift:16`) |

**Not boundaries:**
- **Shutdown** is a lifecycle input in its tick or pass, as today's record has it: on a tick land in its own tick, on a tickless land in its own pass.
- **`.legacyCycle` sync entries** are adapter cycles committed outside a turn: `syncNow` cycles until #546 L2, the freeze settle, and the standalone initial sync until B3 (`ReevaluationSyncStream.swift:17–19`). The keeper runs nothing for them. The cursor hands each one to the sync check at its read position (`afterPass`, sequence), between the boundaries around it.

**Membership deltas and lifecycle inputs are two things.**
- **On live, `players` changes outside the turn,** before the resolvers are awaited:
  - an insert on join (LK:1581, :1803), or a replace when a reconnect replaces the entry;
  - a remove on leave (:2499);
  - a rollback of a join that didn't complete: a drain during its resolvers (:1628, :1856) or a failed OnJoin resolver (:5586).
- **The OnJoin/OnLeave handler is a lifecycle item:** a sequenced input queued after the change, with its resolver outputs. It runs inside `applyInputs` in `(resolvedAtTick, sequence)` order, among the actions (LK:3950–3966). So a change and its handler can land in different batches, and an action that resolved earlier runs before the handler in the same batch. Some changes queue no lifecycle item: no handler, a replace, a rollback.
- **Recording a delta.** Every `players` change is a `MembershipDelta`: its operation (insert, replace, remove, rollback) and the entry's fields. It names no handler. A batch carries the deltas made since the previous batch started, in change order. Replay applies them at the batch's start, before its first input, which is the `players` the live turn saw.
- **Recording a lifecycle item:** unchanged in place. It stays a sequenced input in the batch's ordered stream, with its resolver outputs.
- **Fields.**
  - A delta carries the player ID and what `InternalPlayerSession` holds: client ID, last session ID, device ID, guest flag and metadata (LK:5803–5817). `PlayerSession` (`JoinTypes.swift:22–31`) has no client or session ID, so it isn't the schema.
  - A lifecycle item carries what its handler's `LandContext` reads (player, client, session, device, guest flag, metadata), as today's record does (`ActionRecorder.swift:400–412`).
  - S1's PR pins both against those types.
- **Services.** An entry's `LandServices` aren't recorded. On replay every entry gets the services `ReplayRun`'s caller gives for the land, as today's runners take them (`ConcreteReevaluationRunner(services:)`, `GameReevaluationFactory.swift:19–23`). A handler whose services answer differently on replay is the land's bug, as with config (§5.2, Q8).
- **On live nothing moves.** The change happens outside the turn as today, and `runTurn` applies no deltas (`membership: .alreadyApplied`). Lifecycle items run where they run today. When #588 moves the join into its turn, both sides use `.applyInTurn`.

**Structural validation, before apply.** The cursor checks each boundary before handing it out. A violation ends the run with `recordInvalid(position, rule)`, before anything of that batch applies. These are the invariants a live record actually has:
- every input's sequence is unique in the record. One counter numbers every kind (LK:1595), and the pending queue, the pass index and the waiter map are keyed by sequence alone (LK:3412–3417, :4080–4086, :5461–5467);
- within a batch, the inputs' `(resolvedAtTick, sequence)` doesn't decrease. That is execution order (`readyPendingItemsInOrder`, LK:3400–3409). Sequences alone may go down: an input whose resolver finished a tick later runs after one with a higher sequence, and so does a frozen server input applied after a later join;
- the recorded W1 doesn't decrease across batches, and neither does W2. A batch's W2 isn't below its W1;
- tick IDs don't decrease;
- the pass ordinal is consecutive land-wide;
- `.initialize`, if present, comes first;
- a failure position is well formed (`LandFailurePosition`, `LandFailure.swift:48–82`):
  - `.input` names an input of its batch;
  - `.syncPhase` names the batch's sync phase, with no failing input;
  - `.eventFlush` is the legacy flush after a turn, on a keeper with no port until #546 L2 2e;
  - `.actionResponse` is reported by the transport, so it reaches the keeper as a `.landFailure` input (LK:3951). It ends its batch, with `endsInputs` set;
  - `.tickHandler` is reserved and not produced today.

**Divergence, while applying.** The watermarks are compared with what the replay counted, each at its own stage:
- W1 before the inputs, and W2 after the inputs and before the tick handler (which moves the counter as it emits).
- At either stage the counter moves forward to the recorded watermark when it's behind, as today's restore does (`restoreSequenceWatermark`, LK:4216–4231). It never moves back.
- A counter above the recorded watermark is `mismatch(.watermark, stage)`. The batch goes on, so its later fields are still compared, and so does the run. Today this is a logged warning.

Rev 2 also had "the watermark is at or below its batch's first sequence" and "sequences strictly increase". Both were wrong: inputs take their sequence at intake (LK:1591, :1817, :2512, :2654), and W1 is read at turn start, after them. Stronger rules can be added in S1's PR only with a test that runs them against live recordings.

**Typed inputs.** The cursor decodes each payload once, with the land definition's registries and the codec of its kind (§5.1). A payload that doesn't decode ends the run with its tick, sequence and type (#521's rev 8 rule). For client input that's the strict decode of #606's 2026-11-18 decision.

### 3.2 Time

Game logic reads time only as `tickId`. A replay reads no clock:
- **Boundaries** come from the record (tick IDs, pass ordinals, sync-only entries), not from a clock.
- **Outcomes that depended on time** are recorded as their outcome, never re-derived: an action job's deadline, a resolver timeout, a join that timed out, a sync-lag pause (`rejected`, `landFailure`, resolver outputs, the adapter's recorded dispositions).
- **No turn instant is recorded in 4.0.**
  - A wall-clock instant per turn would break the record's byte identity (§5.1, #327).
  - Q6 is deferred until keeper deadlines or timers move into turns.
  - Then the instant comes from the keeper's injected clock, stored as an offset from a land-relative origin, never as a raw `TurnInstant`. That type is process-relative (`Values.swift`) and means nothing in another process.
  - The stepped clock is set inside the serialized step, before the batch's first read. It is monotonic, and ties are allowed.
- **Viewer pacing** uses its own clock. A tick land paces by the definition's tick interval. A tickless land steps at a fixed rate the viewer sets.

A replay arms no timer and makes no holding request (turn core plan, §3.3–3.4, rule 18).

### 3.3 The keeper's turn entry point

S2 adds one synchronous entry point:

```swift
// Not async: a batch applies without a suspension point.
func runTurn(_ batch: TurnBatch, wants: OutcomeRequest) -> TurnOutcome
```

**Two predicates, not one.** Today `usesInTurnSync` (LK:672) decides two things at once: whether a turn runs at all, and whether the sync phase runs in it. S2 splits it at each site:
- **`routesThroughTurn`:** whether inputs go through `runTurn`. It is true for a `.record` keeper, and for a live keeper wherever `usesInTurnSync` holds today. After #546 L2 group 2e it is true for every live keeper too. Then it is a constant, and S6 deletes it.
- **`syncsInTurn`:** whether the sync phase runs in the turn: a port is attached and opts in (`runsSyncPhaseInTurn(of:)`). It has no mode term.

The sites, by what they decide:
- **Routing only** (`routesThroughTurn`): join :1651 and :1889; actions :2202 and :2657; leave :2585; client events :2909 and :3046; server input :3153; the tick loop :4250.
- **Port output only** (`syncsInTurn`): :637 (a tick's leftover sync requests), :5442 (an input turn's events and sync), :5062 (`runSyncOnlyTurnIfInTurn`).
- **Both, split in the plan:**
  - :1193, initialize: whether OnInitialize is a turn (routing) and whether its events and sync go out through the port and its marker is recorded (port output, LK:1193–1210);
  - :4300, the tick turn: routing, tied today to a port and a tick handler. It becomes routing for the turn, and port output for its outputs step;
  - :5539, the scheduled sync path: whether a due sync folds into the next turn (routing) or runs as a sync-only turn through the port (port output);
  - :1903–1924, transport admission and the join flips: routing decides whether a join waits for a turn, port output whether a sync-only turn flips it.
- **Neither:** :859 is a test accessor. :4881 is `recordsSyncStream`, which becomes `reevaluationRecorder != nil && syncsInTurn`.

**What `runTurn` does, in order.** This is the order `runTickTurn` has today (LK:4705–4773), kept.
1. **W1.** It sets W1. On replay it checks the recorded W1 against the outcome counter, as #72's restore does.
2. **Membership deltas, on replay only.** It applies the batch's deltas to `players` (§3.1). No handler runs here. On live there are none, since the change already happened outside the turn.
3. **Inputs.** It applies the inputs in the batch's order (`applyInputs`), lifecycle items among them, where they run today. A failing input fails alone.
4. **A land failure in the inputs** stops the batch at its position (#535). The outcome is the failed prefix, kept as today (LK:4715–4725, :5422–5456):
   - a failed tick still commits `lastCommittedTickId`, and takes and drops the collected events and sync requests;
   - a failed pass keeps its ordinal and its consumed prefix;
   - there is no W2, no state hash, no events and no sync. The turn goes to step 9.
5. **W2.** It sets W2, and replay checks it.
6. **Tick handler.** For `.tick` it runs the tick handler.
7. **Committed tick and hash.** It commits the tick. It computes the state hash only when `wants.stateHash` is set.
   - On live that is today's gate: `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555, :2713). It doesn't depend on a port, so a live keeper with no port, such as the recording runner (`ReevaluationRunner/main.swift:452`), keeps hashing after #546 2e moves it onto `runTurn`.
   - The initialize record keeps its rule: built when a recorder is attached (LK:1196–1199), hashed under `enableLiveStateHashRecording` (:4844).
   - On replay the comparator sets `wants.stateHash` when the record holds hashes.
8. **Outputs.**
   - **With a port** (`syncsInTurn`), it calls the port with the events and the sync request (`runTurnOutputs`). The port can fail the land, and it routes the events: `includeSync == false` sends events without a sync. So nothing is final before this call.
   - **With no port,** it takes the events and the sync request into the outcome. Nothing is left in the output collector for a later flush. Today's no-port input turn leaves them for `flushOutputs` (LK:5437–5446, :4104–4117). That stays for live keepers with no port until #546 2e.
9. **Outcome.** It builds `TurnOutcome` after step 8: the applied inputs with a result per input, the rejected inputs, the events, the failure position (including a sync-stage failure from step 8), the watermarks, and the hash. On live it also stores each input's result in `inputTurnResults` in the same segment, as today (LK:5447–5449).

**After `runTurn`, outside it.** The caller that ran the turn does the rest, as today:
- **live:** it submits the record (`await submitTurnRecord`). Only then does it resume the waiters with each input's result (`resumeInputTurnWaiters`, LK:5381–5393). So a caller sees its result only after its record is submitted. The same holds for `ticklessJobTurns`. The results stay in `inputTurnResults` across the submission's `await`, not only in the outcome, because a server input's waiter registers late. `awaitInputTurn` returns at once when the sequence is neither pending nor in `inputTurnResults` (LK:5355–5366);
- **replay:** `ReplayRun` gives the outcome to the observers. There are no waiters.

`runTurn` never resumes a waiter itself.

**OnInitialize on replay.** A keeper built with `.record` doesn't start initialization, so there's no eager start to race (LK:988–991). `ReplayRun`'s first step does this:
- it takes the cursor's `.initialize` batch, if there is one;
- it calls `runTurn`, which runs OnInitialize synchronously with the recorded resolver outputs. No resolver is awaited. Today's interception, `replayInitializeBeforeTickZero`, goes.

**The registration backstop is kept.** Skipping `performInitialization` would also skip its check of `SyncRegistration.cachedProblems` and `duplicateHandlers` (LK:1103–1109). `ReplayRun` runs that check and `validateForRegistration` (`ReevaluationEngine.swift:212`) before the first step (§5.2).

**Live keepers with no port** keep their path until #546 L2 group 2e: `routesThroughTurn` is false for them in S2. That is #546's work (§2.4), and this plan lists it as a dependency of S6.

### 3.4 The observers and the run

**`TurnOutcome` observers:**
- **The recorder** (live): today's submission, behind a `TurnRecordSink` protocol. Typed encoding and the state hash run only when a recorder is attached (§7 cost). #275's bound and #526's levels attach here later.
- **`TurnComparator`** (replay): it compares each replayed outcome with the batch's recorded one, field by field: state hash, events (typed value, then encoded bytes), watermarks, rejected inputs, failure position. Its verdict per batch is `match`, `mismatch(field, detail)` or `notVerified(reason)`, with tick, sequence and output index. The CLI, the monitor and tests share it (#478).
- **`SyncOutputCheck`** (replay): §5.3.

**How a batch's verdict aggregates:**
- `mismatch` if any compared field mismatches;
- otherwise `notVerified(reasons)` if any field or scope was not compared (not recorded, skipped by a disposition, truncated, a hash unavailable);
- otherwise `match`.

The run's verdict aggregates its batches' verdicts the same way. Today's `.partial` (SV:850) maps to `notVerified`.

**`ReplayRun`** replaces `ReevaluationEngine.run` and `ConcreteReevaluationRunner`, with their duplicated setup and their two `CapturingSink`s:
- It opens the record once (§5.1) and runs the checks before the first step (§5.2).
- It owns the cursor (§3.1). It builds the keeper with `.replay` and attaches the observers the caller asked for, plus a port for a viewer (§5.5).
- `step()` reads and validates the next boundary from its cursor, hands the batch to the keeper's `runTurn`, and returns the verdicts. `runToEnd()` loops it.
- **One step in flight.** It is an actor-isolated flag:
  - `step()` checks the flag and sets it in one segment, before the cursor's async read;
  - a second call while the flag is set returns `.busy` at once;
  - a `defer` clears the flag on every exit: success, a read error, cancellation, and supersession by a newer run.

  This isn't `SingleFlight`: `SingleFlight.flight(for:start:)` gives a second caller the task already in flight (`SingleFlight.swift:46–58`), and never returns `.busy`. Reentrancy during the read can't start a second step (#100's step race).
- **A batch that was read is applied, or the run ends.** No batch is skipped:
  - the cursor advances only when it returns a batch. A read that throws, cancellation included, ends the run (`ended(.readFailed)` or `ended(.cancelled)`), and its position doesn't matter after that;
  - after a read returns, the step checks nothing more before the apply. It hops to the keeper, and `runTurn` is synchronous there. So a cancellation that arrives between the read and the apply is seen at the next `step()`, which ends the run before reading;
  - supersession by a newer run (§5.4) drops this run and its keeper. Its results are dropped by their ticket, and no pending batch survives it.
- It owns its keeper. The keeper is single-use and dropped at the end of the run.

**Today's runner contract stays until S5.** S2 replaces `ConcreteReevaluationRunner`'s engine, not its type. Its public init, `ReevaluationRunnerProtocol` and `ReevaluationStepResult` (with `replayFrame`) stay as a wrapper over `ReplayRun`. These callers build it or read it:
- GameDemo's factories (`GameReevaluationFactory.swift:19`, :33, :40) and `GameServer/main.swift`;
- `HeroDefenseReplayStateParityTests` and `E2EStateSnapshotDiffTests`;
- `GenericReplayLand`, which reads `replayFrame` (`GenericReplayLand.swift:67–127`).

The wrapper maps each batch's outcome to today's step result: the state, the hashes and `isMatch` from the verdict (`match` only). The generic viewer E2E (`reevaluation-replay-e2e-game.ts`) must pass at S2's merge. S5 deletes the wrapper with `GenericReplayLand`.

## 4. What goes away

| Today | Fate | Step |
|---|---|---|
| `LandKeeperModeConfig.reevaluation`, `LandManager`'s `.reevaluation` branch, the adapter flag's `!isReevaluationKeeper` term, `registerWithReevaluationSameLand`, `registerWithReevaluation` and their resolvers | Deleted. The adapter refuses a non-live keeper | S0 (done, #675) |
| `LandMode`, `ReevaluationOutputMode` (LK:32–43) | Deleted. The input source and the observers replace them | S2 |
| The keeper's mode branches | Each becomes intake closed, cursor validation, a `runTurn` step, an observer, or nothing (viewers aren't players, §5.5). S2's PR lists each site with its fate | S2 |
| `runTick`'s replay pull and `replayInitializeBeforeTickZero` | Replaced by the cursor and `runTurn` | S2 |
| The keeper's off path: `processPendingActions`, `replayRecordedPasses`, `deliverLegacyPass`, the legacy `runSync` loop, `syncNowFromTransport`, `beginSync`/`endSync` | Unreachable after S2 and #546 L2; deleted after S6's reachability check | S6 |
| `ReevaluationEngine`, `CapturingSink`, `ConcreteReevaluationRunner`'s engine | Replaced by `ReplayRun` and `TurnComparator`. `ConcreteReevaluationRunner`'s type and contract stay as a wrapper (§3.4) | S2 |
| The runner wrapper: `ConcreteReevaluationRunner`, `ReevaluationRunnerProtocol`, `ReevaluationStepResult.replayFrame` | Deleted with its last users | S5 |
| `SyncOutputReplayDriver` (the shadow's driver) | Replaced by `SyncOutputCheck`'s driver on the shared planner (§5.3) | S3 |
| `GenericReplayLand`, `ReevaluationReplayProjector` (the hard-coded "hero-defense" projector), `DecodeReplayState`, the replay use of `fromBroadcastSnapshot`, `registerWithGenericReplay`, `replayLandSuffix` (configuration, `NIOLandServer`, `LandTypeRegistry`, `NIOAdminRoutes`), `ReevaluationReplaySessionDescriptor`, `/admin/reevaluation/replay/start` | Replaced by replay sessions (§5.5) | S5 |
| The 3.x replay readers and their compatibility branches (#211, #607) | Deleted when 4.0 is the written format and the checked-in records are regenerated | S1 |
| The S1 bridge (`MaterializedRecordSource`, §6 S1) | Deleted when the runners move to `ReplayRun` | S2 |

## 5. The parts in detail

### 5.1 Record format 4.0

**Why a new major:** input payloads change form, the header is written once, and the version authority changes.

**Version authority.** The preamble's `(major, minor)` is the one authority. The header carries no separate version, so the 3.5/3.6 disagreement can't recur.
- A reader refuses a different major.
- For a newer minor of 4, replay refuses (`recordNewerThanReader`), and a reader that lists records shows the record as not replayable.
- A preamble that is missing or malformed refuses the file.
- Admin maps all of these to 409 `RECORD_VERSION_MISMATCH` (#213).

**Byte identity stays.** With in-turn sync, two recordings of one input are byte-identical (#327, `RecordTurnBoundaryLiveTests.swift:195`). 4.0 records no wall time per turn. The header keeps `createdAt` and `hardwareInfo`, which tests pin through `LandManager`'s record test pins (LM:128–137) as today. So that test and the differential harness's record goldens keep working. Their bytes change once, in S1.

**One codec per payload kind.**

| Kind | Stored as | Decoded by | On failure |
|---|---|---|---|
| Client action, client event | canonical MessagePack written by the `@Payload` typed writer, positional in declaration order (#521 PR 1a), under the static wire name (#521 EV2) | the definition's registry and #606's strict typed decode | the run ends (record/code mismatch) |
| Membership delta (§3.1) | `MembershipDelta`, a `Codable` struct: operation (insert, replace, remove, rollback), player ID, and the `InternalPlayerSession` fields (client ID, last session ID, device ID, guest flag, `metadata: [String: String]`). Canonical MessagePack, named keys | synthesized `Codable` | the run ends |
| Lifecycle item (OnJoin, OnLeave, shutdown) | a sequenced input, as today: its kind and the context fields its handler reads (`ActionRecorder.swift:400–412`), with its resolver outputs. There is no `@Payload` join payload | synthesized `Codable` | the run ends |
| Server input (`ServerInputPayload: Codable`, #387) | canonical MessagePack of its `Codable` encoding, named keys. It stays `Codable` (#387's plan, outside #521) | `serverInputRegistry` by its type identifier, synthesized `Codable` | the run ends |
| Resolver output (`Codable & Sendable`, `ResolverOutput.swift:23`) | canonical MessagePack of its `Codable` encoding, named keys, keyed by its scope (the item's sequence, or OnInitialize) and its resolver key. An output that is absent on purpose (a resolver that didn't run, or returned nothing) is recorded as `absent`, not left out | through a definition API S1 adds: a handler-scoped resolver descriptor with its key, its output decoder and the duplicate-key rule, usable without executing. Today's `AnyResolverExecutor` only executes (`Resolver/ResolverExecutor.swift`) | the run ends; an output with no declared type is `recordInvalid` |
| Server event (an output, compared) | the typed writer's bytes (#521) | decoded to check that it resolves; compared as bytes | `mismatch` |

**Canonical encoding from the typed value, not the client's wire bytes.** Wire bytes depend on the client's encoding (JSON key order, whitespace, number forms), so two recordings of one input could differ. The cost is one encode per recorded input, and it runs only on a recording land (§7).

**Live server-input intake.** It canonicalizes and preflights every server input through the 3.x framed record, even with recording off (LK:3104, `ServerInput.swift:181–202`). S1 moves that check to 4.0's framing and frame limit. It stays on every live land, recording or not.

**The header: one, complete at keeper init, written before the first turn record, never replaced.**
- **Everything is known at init.** S1 adds a `RecordingSetup` parameter to the keeper's init. It holds:
  - the land ID (#575: no `setLandID` afterwards; LM:628 goes);
  - the caller's metadata, `createdAt` and `hardwareInfo`;
  - the sync stream part: `.recorded(syncConfig)` or `.notRecorded`.
- **The keeper adds what it holds:** land type, the RNG seed (#575), the schema fingerprint (#604), the effective-config fingerprint (§5.2, Q8), and the initial-state hash (the state before OnInitialize).
- **The race this removes.** Today the keeper starts initialization eagerly in its init (LK:988–991), and `LandManager` sets the metadata (LM:703) and attaches the port (LM:715–716) after awaits. With the header complete at init, OnInitialize's record can't come before the header, and nothing is attached later that changes it.
- **Where the sync part comes from: one resolved configuration.** Today the adapter's sync configuration comes from the in-turn switch, the environment strategy and the encoder pairing (TA:95–100, :971–1058). `LandManager` resolves it once, before building the keeper, with a static `TransportAdapter.resolveSyncConfiguration(…)`. It passes the same value to the header's sync part and to the adapter's init. Today's instance property `syncConfigForRecord` goes.
- **"No port, ever" vs. "port not attached yet."** These are told apart by the init parameter, not by timing: `.notRecorded` is "no sync stream". The headless runner and keepers with no port pass it.
- **Both directions are checked** when a port is attached, by `setTransport` or, later, at init:
  - a port whose sync config differs from a `.recorded(syncConfig)` header is refused with a precondition (a wiring bug);
  - a recording port attached to a `.notRecorded` header is refused the same way;
  - a `.recorded` header whose port is never attached (the land ends during wiring) is a valid record with an empty sync stream.
- **OnInitialize before the port.** Today the keeper starts initialization in its init (LK:989), and the port comes later (LM:715–716). Initialize's marker and its phase depend on `usesInTurnSync` (LK:1193–1210). With a `.recorded` header the keeper starts initialization when its port is attached, not in its init, so the marker and the phase always see the port. With `.notRecorded`, it starts in its init as today. This changes live timing only on recording lands, by the wiring time, and S1 tests it with the `.wiring` hold.
- **Direct metadata setters move to `RecordingSetup`** in S1:
  - the headless runner's `setLandID` and `setMetadata` (`ReevaluationRunner/main.swift:459–471`);
  - EncodingBenchmark's setter (`EncodingBenchmarkMain.swift:149–159`).
- **A second header** is a format violation, and the reader refuses it. Today a later header replaces the earlier one.

**The cursor (streaming): when a batch is final.**
- **The file has two streams in one handle.** Turn frames are written in their turn, in order: one frame per boundary (a pass is a frame of its own, not an entry of a tick frame as in 3.x). Sync frames are the sync stream, read in `streamIndex` order.
- **Lookahead: one boundary.** A boundary is final when the cursor has read the next boundary's first frame, or the footer. Only then does the cursor hand it out, so it never hands out a batch it might later withhold. This is per boundary, not per tick: a tickless land records every pass under tick 0 (LK:3384–3397), and a per-tick rule would hold its whole run until EOF.
- **Truncation.** A file without its footer, or with `complete == false`:
  - only the newest boundary is withheld. Today's reader withholds the newest tick, which on a tickless land is the whole run;
  - the boundaries before it are final;
  - the verdicts for the withheld boundary and everything after are `notVerified(.truncated)`.
- **When a sync entry is final.** Each sync entry names its read position (tick, `afterPass`, sequence). It is handed out when both are true:
  - its `streamIndex` is the next one expected;
  - the boundary at its read position is final, or the entry is a `.legacyCycle` read between two final boundaries.

  So a handed-out entry never disappears later. Today's reader computes the dense prefix after it drops the newest tick, which can drop an entry it would otherwise have kept (RL:302–345).
- **Sync stream errors:**
  - a duplicate `streamIndex` is `recordInvalid`;
  - at a complete footer, a missing `streamIndex` is `recordInvalid`;
  - at truncation, the sync stream ends at its dense prefix among final entries, and the outputs after it are `notVerified(.truncated)`.
- **Bounded read-ahead, with matching bounds on both sides.** Filling a sync-stream gap reads forward, past turn frames that aren't due yet. Those frames, and the sync frames that wait for their boundary, are buffered.
  - The reader's bound is `RecordCursor.maxReadAhead`: a frame count and a byte count over both buffers together. Above it the record is refused.
  - The writer measures the same thing. For each sync draft not yet written, it counts the frames and bytes it has written since that draft's boundary frame, which is what the reader buffers for it. It keeps both counts under `ReevaluationRecorder.maxReorder`, which is below the reader's bound by a fixed margin.
  - **Past its bound, the writer closes the valid prefix.** It writes the footer with `complete = false`, the reason, and the last boundary whose sync drafts are all written. Then it stops recording that land, and logs it. A reader of that file sees a truncated record, not one it refuses.
  - S1 tests the bounds with a hold that delays one draft, not with timing. A long tickless run, with more passes than `maxReadAhead`, is a control that must pass.
- **Frame size:** each frame is bounded by a reader limit, and refused above it.
- **Opening.** The path is resolved once to its real absolute form: symlinks, and a relative `REEVALUATION_RECORDS_DIR`. Containment is checked on the resolved path, and the file is opened once. The run keeps that handle (#366 items 1–3). Reads are async (#275).
- **A header-only open.** `RecordCursor.readHeader(filePath:)` resolves the path the same way and reads the preamble and the header only. It needs no definition and decodes no payload. Its callers read the metadata before they have a definition:
  - the admin start's compatibility check (`NIOAdminRoutes.swift:675`);
  - the GameDemo CLI, which finds the land type from the metadata (`ReevaluationRunner/main.swift:123–132`);
  - VisibilityTest's factory, which checks the record's settings before it picks a definition (`GameReevaluationFactory.swift:25–43`);
  - Q2's record listing.

### 5.2 Checks before the first step

In this order, each refusing with its own code:
1. version (at open);
2. schema fingerprint (#604);
3. effective config (#441);
4. land type registered on this host;
5. registration: `validateForRegistration` and the sync registration check (§3.3);
6. initial-state hash.

The engine no longer takes an initial state from its caller. It builds the state the way the live land did, from the same definition, and the hash check catches a custom initial state that the record didn't carry. The seed comes from the header. A record without a sync stream runs no `SyncOutputCheck`, and its sync verdicts are `notVerified(.notRecorded)`.

### 5.3 `SyncOutputCheck`: what it takes as fact, and what it checks

**What it is.** It replaces the shadow's driver. It doesn't pose as a transport. After each batch that the record says synced, it reads the replaying keeper's state, the same read today's shadow makes.

**What it compares:** for each recorded output, the broadcast hash, the per-player hashes and the event hashes, in recorded order.

**What it takes as fact.** These recorded facts are conditions for a hash check. The check doesn't confirm that they should exist, or their order: a recorded fact can't verify itself.

**Today's rules, kept.** Each row below is what `SyncOutputVerifier` does today (`seed` and `clear`, SV:307–342; `output(_:observedTickId:state:)`, SV:344–520). S3 moves these rules onto the shared planner. It doesn't change them, and S3's PR checks each row against its tests.

| Recorded fact | What the check does with it |
|---|---|
| Seed marker | It plans the joiner's late-join view from the replayed state, stages and applies it, and apply-checks it. With a `viewHash`, the hash is compared, and the player leaves the unverifiable and diverged sets. Without one, the player is an unverifiable view: the seed counts unverifiable (SV:307–333) |
| Clear marker | It drops the player's caches and its seeded, diverged and unverifiable-view state. Resends still pending are counted as not seen (SV:335–342) |
| Seed and clear order | who is planned at each output: a player from its seed to its clear. The adapter can emit a clear before a resync output and a seed after it, so the order is taken as recorded |
| `extractionDrops[scope]` | the scope's dropped keys keep their cached values in the replayed snapshot (`substituting`), for broadcast (SV:348–352) and per player (:421–425). The hash is compared |
| No recorded hash for a scope (`broadcastHash`, `perPlayerHash` and `eventsHash` are optional) | broadcast: `skip(.broadcastNotCommitted)`, and its staged cache is dropped, so its baseline doesn't move (SV:391–394). No per-player hash: nothing per player is planned or staged for that output. No events hash: `skip(.eventsHashMissing)` |
| `encodeDropScopes` | broadcast: the hash is compared and counted unverifiable, and its baseline moves (SV:385–390). A joiner that isn't seeded: `skip(.viewNotSent)`, and it stays pending until its seed (SV:376–383). A seeded player: it becomes diverged, so its per-player output is unverifiable until a seed with a `viewHash` clears that (SV:460–468, :318–319). The events scope: the events are unverifiable (SV:497) |
| `perPlayerUnverified` | Two cases. A player not addressed (withheld, or its sessions ended before its clear) is neither compared nor staged: its view doesn't advance (SV:405–418). A player whose seed had no `viewHash` is planned, apply-checked and staged; only its hash is left out, counted unverifiable (SV:456–459) |
| `perPlayerUncommitted` | The player is planned and apply-checked, then its staged per-player cache is dropped: its baseline doesn't move (SV:443–444). With a merged broadcast frame: `skip(.perPlayerResent)`, and a resend is pending. Without one, the combined update carried broadcast changes the client missed, so the player becomes diverged (SV:445–454). Its hash isn't in the combined per-player hash |
| `resetsKeyScopes` | counted (`keyScopeResets`) after the combined per-player hash matched (SV:482). Today's check doesn't plan with it |
| `eventsNotQueued` | those sequences are left out of the expected events. The events hash stays comparable (SV:485–491) |
| `eventsNotMerged` | those sequences are left out too, the ones sent alone and the lost ones are counted, and the output's events are unverifiable (SV:492–498) |

Each "unverifiable" and "skip" above is `notVerified(reason)` in the batch's verdict, never `match`. A diverged or pending player stays `notVerified` for every later output until the record re-seeds it.

**What it can check:** the content of broadcast and per-player diffs, and how each scope's baseline evolves, given the recorded markers and dispositions. It also checks event order. It can't check:
- whether a marker or a disposition should exist;
- what lag, ceilings, backpressure or the socket decided.

**The planner: option (b), shared, and narrower than the phase.** S3 takes the patch-planning half of B2's routine (decision 5's `planAndCommit`) into a deterministic function that the adapter's machine and the check both call. Three things are kept apart:
- **Logical patch planning, with its staged caches: shared.** Its input:

  ```swift
  struct SyncPatchPlanInput {
      let state: LocatedStateRead        // the keeper's state after the batch
      let planned: [PlayerID]            // the players planned at this output (adapter: its eligible recipients; check: seeds to clears)
      let extractionDrops: [String: Set<String>]  // per scope; empty when nothing was dropped
      let layout: SyncFrameLayout        // merged broadcast frame vs combined update
      let cachePolicy: SyncCachePolicy   // full, broadcast-only, resync with key-scope resets
      let eventWindow: SyncEventWindow   // the events this output carries (through which sequence)
  }
  func plan(_ input: SyncPatchPlanInput, caches: SyncEngine.Caches) -> (SyncPatchPlan, SyncEngine.StagedCaches)
  ```

  These are what today's plan reads (TA:4404–4436). #546 B0/B2 moves the layout tables into `CommitTools`, and S3 takes them from there.
- **Live delivery decisions: the adapter's machine only** (#546 B2). Sessions, lag, ceilings, backpressure, the writer, and what commits. The check never sees them.
- **Facts only the check uses:** uncommitted players, encode drops, unverified players and the events dispositions (the table above). They decide what is compared and what is staged after the plan. They never enter it.

S3's PR fixes the final names against B2's code.

**Rejected:** option (a), recording the phase's full inputs (recipients, sessions, lag state, joins, scratch). It grows every recorded turn on the live path to replay something the record already states as outcomes.

**#554 is closed.** It extracted the stateless encoding and frame building, not `planAndCommit`. S3 needs B2's routine (§8).

**Until S3,** S2's `ReplayRun` drives today's `SyncOutputVerifier` through its existing driver, as an observer. That is the sync verifier §7's S2 gate compares against.

**Viewer runs.** In S5 a viewer's observer sessions aren't the recorded players. When a viewer run verifies per-player output, the check runs beside the viewer's port, on the recorded membership, never on the observers.

### 5.4 The monitor and the run service

- **Runs and tickets.** `ReevaluationRunnerService` keeps runs keyed by a run ticket (a `GenerationTable`). A new run supersedes the old one, and a stale run's results are dropped by its ticket (#100).
- **Results as server inputs.** The run reports through `submitServerInput` (#387): `RunProgress` and `TurnVerdict`, each carrying the run ticket. The monitor's handlers keep the current ticket in state and drop an input from another run. The monitor's tick no longer reads the service, so CLAUDE.md's monitor exception and #522's item go.
- **The bound is land-wide.** `serverInputMaxInFlight` is one cap for the land (LK:379, :3113), shared by `RunProgress` and `TurnVerdict`. #387's submit refuses at the cap at once (`.overCap`). The run then waits for capacity through a new keeper call, `awaitServerInputCapacity()`:
  - **check and register in one segment:** if the land-wide count is under the cap, it returns at once. Otherwise it registers its waiter in that same actor segment, so a release between the check and the registration can't be missed;
  - **any release wakes it:** applying a server input of any type, or dropping one in a drain, frees a slot and resumes one waiter. An intake refusal never took a slot (LK:3093–3121, :3130), so it frees none;
  - **termination wakes it:** the land draining, failing or stopping resumes every waiter with `.landEnded`. A land that has already ended returns `.landEnded` at once;
  - **no cap:** with `serverInputMaxInFlight == 0` (unlimited) it returns at once;
  - **cancellation removes it:** the waiter is registered with a cancellation handler. The service cancels a superseded or cancelled run's task, and the handler removes the parked waiter in the keeper, so a land that stays full can't strand it;
  - **the run's loop retries the submit only while its run ticket is current.** A superseded run stops.

  Nothing else holds results, so `resultsQueue`'s unbounded growth goes (`ReevaluationRunnerService.swift:301`).
- **`TickProcessedEvent`** (`ReevaluationMonitorEvents.swift:61–68`, emitted at `ReevaluationMonitorLand.swift:59–68`):
  - `expectedHash` stays the recorded state hash (`"?"` when the record has none).
  - `expectedState` today is the replayed state: the emitter passes `actualState` to both fields. A recorded snapshot exists only when the live land recorded snapshots (`EnvKeys.Runtime.stateSnapshotRecording`). S4 sets `expectedState` to the recorded snapshot when there is one, and to the replayed state otherwise, as today. It adds `hasRecordedState: Bool` so the monitor can tell the two apart.
  - `isMatch: Bool` stays, and is true only for `match`. S4 adds `verdict` (`match`, `mismatch`, `notVerified`) with its reasons. The summary's `correctTicks` counts `match` and `mismatchedTicks` counts `mismatch`. A new `notVerifiedTicks` counts the rest. The monitor's WebClient changes with it.
  - The batch's verdict is the aggregate of §3.4, which combines the comparator and the sync check: `mismatch` if either says mismatch, otherwise `notVerified` if either says notVerified, otherwise `match`.

### 5.5 Replay viewing

A replay session is a `ReplayRun` with a real `TransportAdapter` as its port, paced in wall time (§3.2).

- **Addressing.** `POST /admin/replay/start` (record path, land type) opens and checks the record (§5.1–5.2) and creates the session. It returns a replay ticket and a WebSocket path.
  - The ticket is HMAC-signed with the session ID inside.
  - No record path is in the ticket, the instance ID or any client message (#366 items 4–6).
  - The session isn't a land of a `-replay` type. A `ReplaySessions` component on the host owns it, outside `LandManager`'s type registry (§9 Q4).
- **Readiness.** The start call returns after the session's keeper has run `.initialize` and its adapter accepts observers. A viewer that connects with the ticket can't race the creation. S5 adds a test for that, held at the point where the start returns.
- **Viewers are observers, not players.** The adapter's join calls `keeper.joinReportingAdmission` (TA:2245, LK:1704), the player membership path, which a `.record` keeper refuses with `.replaying`. So observers get their own operations, in B3's membership model (S5 needs B3):
  - **admission:** `admitObserver(session:)`. It adds the session to the adapter's membership as an observer: no keeper call, no `PlayerID` in the land's state, no OnJoin;
  - **first sync:** a standalone first-sync commit for the observer, through B3's initial-sync path. Its baseline is the planner's view at the session's current state: broadcast by default (Q3);
  - **a view of a recorded player** (only if Q3 allows it): the per-player baseline comes from the planner on the replaying keeper's current state, for the player the ticket names. It never comes from recorded hashes, and the observer never becomes that player;
  - **disconnect:** the observer is removed from the adapter's membership only. There is no keeper leave and no OnLeave.

  Today's viewer joins the live `GenericReplayLand` as a player, which goes with that land. S5's own plan PR details these against B3's code.
- **Inputs S5's own plan must answer:**
  - **The adapter's precondition.** S0's `precondition(keeper.isLive)` (TA:968) reads `LandMode`, which S2 deletes. In S2 it becomes `keeper.inputSource == .live`. S5 replaces it for an adapter that serves observers of a `.replay` keeper: an observer-only adapter, whose ordinary join stays closed (the keeper refuses it with `.replaying` anyway).
  - **The observer's first sync** starts from an empty client view, on each supported encoding. B3's inherited standalone planner takes a `PlayerID` and refuses row addressing (TA:5681–5708). An observer needs:
    - a per-session baseline;
    - key-scope ownership;
    - a fence against the next replay batch, so the driver doesn't step while an observer's first sync reads;
    - a cleanup that leaves other observers of the same recorded player intact.
- **Pacing.** A driver task steps the run on the viewer's clock (§3.2), with a speed factor (1× by default), pause, and seek-forward. Seek-backward needs snapshots (#526) and isn't in scope.
- **Same definition.** The session's keeper is built from the registered `LandDefinition` of the recorded land type, so its path hashes, event hashes and fingerprint are the live land's.
- **Moved in S5 with it:**
  - the admin routes and the monitor WebClient's routes;
  - `verify-replay-record.ts`, a replay client over HTTP, not a record reader;
  - the CLI replay E2E (`reevaluation-replay-e2e-game.ts`) and its `test-e2e-game.sh` wiring;
  - `docs/core/reevaluation.md` and `docs/transport/auth.md`, with their zh-TW companions.

### 5.6 Recording

- **The recorder is an observer** (`TurnRecordSink`) on a live keeper. The host-level setting is today's `enableLiveStateHashRecording` (`NIOLandServerConfiguration`). It attaches the recorder (LK init) and turns on the state hash, as today: `wants.stateHash` on live is that flag with a recorder attached (§3.3 step 7). Nothing widens or narrows that gate.
- **The sync stream** is recorded through the port as today: drafts come back in the phase's output (#553).
- **`ReevaluationRecordSaver.saveOnShutdown`** stays the land's call. #526's production stream is out of scope; the sink protocol is where it attaches.

## 6. Steps

Each step is its own PR to `main` (core paths).

**S0: done (#675, merged as 4fbe76c6).**
- **Removed:**
  - `LandKeeperModeConfig.reevaluation(recordFilePath:)`, `LandManager`'s `.reevaluation` branch and its package `replayLandSuffix` parameter, and the flag's `!isReevaluationKeeper` term;
  - `registerWithReevaluationSameLand` and `registerWithReevaluation`, with `injectingReevaluationKeeperModeResolver` and `injectingReplayTicketGate`;
  - `checkRecord(_:against:replayLandSuffix:)` and `compute(for:keyedAs:)`.
- **The adapter's refusal:** `LandKeeper.mode` is a `let`, with `isLive`, and `TransportAdapter.init` has the precondition `keeper.isLive`. `TransportAdapterBenchmarkHandle.init(keeper:)` documents it.
- **Tests:**
  - `LandManagerKeeperModeTests` keeps the live-manager tests, including the recording manager's fingerprint gate;
  - `ReplayTicketJoinTests` stayed and moved to the generic path;
  - the reevaluation arms in the adapter and manager suites went.
- **Left for later:** `NIOAdminRoutes.swift:720–721`'s comment and `LandTypeRegistry:51`'s fixed `-replay` go with S5's suffix removal. The "same-land replay" strings in `Examples/GameDemo/Sources/SchemaGen/main.swift:14` and `Tools/CLI/src/reevaluation-replay-e2e-game.ts:186` get a direct change.
- **What it gave #546:** no adapter is bound to a `.reevaluation` keeper, so L2 needs no replay-only cycle (#546 rev 13).

**S1: format 4.0, writer and reader, with today's runners on a bridge.**
- **The writer** writes 4.0 (§5.1):
  - typed inputs by codec kind;
  - membership deltas for every `players` change, apart from the lifecycle items;
  - one header, complete at keeper init (`RecordingSetup`);
  - the preamble as the version;
  - the writer's reorder bound.
- **The cursor** reads 4.0 (§5.1, §3.1 validation).
- **The bridge.** Today's runners address the record by tick: the max tick, the whole sync stream, completeness and the land failure before tick 0, then several getters per tick, with the verifier querying the same tick again. A forward-only cursor can't serve that. S1 adds `MaterializedRecordSource: ReevaluationSource`:
  - **at open,** it reads the whole 4.0 file through the cursor, so validation and decoding happen once;
  - **an index** by tick serves every getter, and `getSyncStream()` serves the materialized sync stream;
  - **the definition** reaches it through `openSource(filePath:definition:)`, which gains the definition parameter. 4.0's positional client payloads need the definition to decode;
  - **conversion to today's DTOs:** each decoded typed value is converted back to the DTO today's keeper decodes (`ReevaluationRecordedAction` and the others, with `AnyCodable` payloads), through the value's `Encodable` form;
  - **what it maps beyond payloads:**
    - passes become today's `getPasses` entries, from the per-boundary frames;
    - `.initialize` becomes `getInitializeRecord`, and the terminal failure `getLandFailure`;
    - lifecycle items become today's lifecycle entries;
    - membership deltas have no 3.x counterpart, so the bridge drops them. Through S1, replay keeps today's membership handling, and S2 is the first reader of deltas;
  - **errors:** a cursor error fails the open, so the run is refused before its first step. The keeper's two error paths can't be reached through the bridge: it treats a failed max-tick read as EOF, and it logs a failed tick read and goes on. S1 adds a test that a corrupt 4.0 file fails at open;
  - **its users** are `ReevaluationEngine` and `ConcreteReevaluationRunner` (and through it `GenericReplayLand`'s run), until S2 moves them to `ReplayRun`.
- **The header-only open** (§5.1) replaces `openSource(...).getMetadata()` in the callers that have no definition yet.
- **The checked-in 3.x records are regenerated with the 4.0 writer in S1's PR,** with the command for each in the PR:
  - `Examples/GameDemo/reevaluation-records/{1,2,3}-hero-defense.sstr`. `verify-replay-record.ts:85` defaults to `3-hero-defense.sstr`, and `test-e2e-game.sh:293` calls it without a record path; `HeroDefenseReplayStateParityTests.swift` reads them;
  - `Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/*.reeval.sstr` (five files);
  - `Tests/SwiftStateTreeTransportTests/Fixtures/HybridEventFrames/hybrid-record.sstr`.

  Keeping the 3.x reader until those consumers move is the alternative. It is rejected: it keeps #211's branches alive through S5.
- **Checking a regenerated record.** S1's PR has two commits for this:
  - the first adds the 4.0 writer and reader, the regenerated files, and an equivalence test. For each regenerated file, the test compares its decoded content field by field with its 3.x original, through both readers: inputs, outcomes, hashes and sync entries, wherever 4.0 has the field. CI runs it on that commit;
  - the second deletes the 3.x reader, the originals and the equivalence test.

  So a writer bug can't hide in a regeneration.
- **The fixtures' tests.**
  - `SyncOutputGoldenTests.swift:182–205` opens the five 2.6 JSON copies and casts the new side to today's log type. The 2.6 JSON comparisons retire with the 3.x reader. The verdicts they pinned are pinned again on the regenerated files.
  - `HybridEventFrameGoldenTests.swift:223–249` pins a historical fixture, exact event sequences and a partial verdict. The historical version pin retires. The event sequences and the partial verdict are pinned again on the regenerated file.
- **The 3.x replay readers** and their branches are deleted (#211, #213, #607).
- **Live server-input intake** moves to 4.0's framing and limits (§5.1).
- **The game E2E's separate-process `--verify`** (`reevaluation-e2e-game.ts:96–97`) runs on 4.0 from this step on, through the bridge.
- It also covers #575 and the header part of #441.

**S2: the turn entry point, the cursor's batches and `ReplayRun`** (§3.1, §3.3, §3.4).
- **`runTurn`** takes replay batches and the live turns that run in-turn today:
  - the predicate is split at each listed site (§3.3);
  - the order is the one §3.3 gives;
  - waiters are resumed by the drain after the record's submission;
  - the failed-input prefix is kept.
- **`InputSource`** comes in, and `LandMode` and `ReevaluationOutputMode` are deleted, with each mode branch's fate listed.
- **The runners:** the CLI runner and the monitor's runner move to `ReplayRun` and `TurnComparator`. `ConcreteReevaluationRunner` stays as a wrapper over `ReplayRun`, so GameDemo's factories, the parity tests and `GenericReplayLand` keep working until S5 (§3.4). The generic viewer E2E passes at S2's merge. The S1 bridge is deleted.
- **The sync observer until S3** is today's `SyncOutputVerifier`, driven as today: its driver loads the whole sync stream and its completeness before the first step (SV:744–817). `ReplayRun` gives it that preload from the cursor's sync stream, read once at open. Its per-output results become each batch's sync verdict, and its run result (`.passed` / `.partial`) becomes `match` / `notVerified` for the run. The E2E's per-scope `passed` assertions stay (`sync-output-verdict.ts:64–94`).
- **The adapter's precondition** becomes `keeper.inputSource == .live`, since `LandMode` goes (TA:968).
- **Tests:** the keeper-side tests that used `.reevaluation` with fake transports are converted to `.record` keepers.
- **Not in S2:** live keepers with no port, and live keepers with fake transports, keep `routesThroughTurn == false`. They are #546 L2 groups 2e and 2d.
- It covers #324, #342 and #478.

**S3: `SyncOutputCheck` on the shared planner** (§5.3). It needs S2 (`ReplayRun` drives it) and B2 (the planner's source). It deletes `SyncOutputReplayDriver`.

**S4: the run service and the monitor** (§5.4). It needs S2 and #387 PR 2, or does that migration itself. It covers #100 and #522's monitor item.

**S5: replay viewing** (§5.5). It needs S2, S3, and #546 B3 (observer membership is new membership, and the initial sync is B3's). It gets its own plan PR first, which answers §5.5's inputs.
- It deletes `GenericReplayLand`, the projector, `registerWithGenericReplay`, every suffix site and the runner wrapper (§3.4).
- It moves the clients and docs listed in §5.5.
- It covers #366 items 4–6.

**S6: the deletion.** It needs S2 and #546 L2, including groups 2d and 2e. It doesn't need S3–S5.
- **Who deletes what.** #546 deletes its own parts first: L1 the `IN_TURN_SYNC` switch and its code (#677), L2 `beginSync`/`endSync`, `syncNowFromTransport` and the adapter's own cycle (#546 rev 13). This plan deletes the keeper's off path:
  - `processPendingActions`, `replayRecordedPasses` and `deliverLegacyPass`;
  - the keeper's legacy `runSync` loop, if L2 left it;
  - `routesThroughTurn`, by then a constant.

  S6's PR lists what L1 and L2 already deleted, from their merged code, and traps and deletes only the rest.
- **Exit check first, in the same PR.** S6's first commit turns each entry it will delete into `preconditionFailure("off path reached: <name>")`. The full matrix must be green on that commit: `swift test` in every CI variant, the differential harness with every cell, the live fake transports, E2E in all three encodings, and the benchmarks' smoke runs. A trap that fires names the caller still to move, and S6 stops there.
- **Then the deletion,** in the second commit.
- This is #550's outcome and #522's "legacy tick path" item.

## 7. Verification

**Determinism, before and after S1/S2.** The scenarios are those under `Tools/CLI/scenarios/game/`, a tickless land with several passes under one tick and a sync-only phase between them, and the Demo counter land. The gate:
- recording with S1 and verifying with the bridged runner, then with S2's `ReplayRun`, gives the same verdicts turn for turn;
- verdicts aggregate as §3.4 says. `match` is required where the record has the field and the scope was compared. Today's verifier also reports unavailable hashes and scope-level skips, and these come out as `notVerified(reason)` per scope, with the same reasons on both sides;
- the E2E keeps its requirement that comparable scopes actually ran (`reevaluation-e2e-game.ts:103–107`), and its per-scope `passed` assertions (`sync-output-verdict.ts:64–94`);
- the live client frames are compared by the differential harness's goldens (#555). The record bytes are compared on their own: their goldens change once in S1 and are deterministic (no wall time), and `RecordTurnBoundaryLiveTests`' byte identity holds;
- S2's gate also runs live keepers with no port, unchanged (they keep their path until 2e). This pins that S2 didn't move them.

**Mutants.** Each must fail with its own verdict or error:
- a replayed input applied in another order, and a dropped recorded input;
- a wrong seed, a changed config value, a stale fingerprint, and an initial-state hash that doesn't match;
- a pass ordinal skipped (land-wide);
- a W1 or W2 lower than the previous batch's, and a W2 below its own batch's W1;
- a duplicate sequence, across two kinds;
- a membership delta moved to a later batch, and a lifecycle item moved ahead of an action that resolved earlier in its batch;
- a replayed counter above a recorded watermark (`mismatch(.watermark)`, the run goes on);
- a batch whose `(resolvedAtTick, sequence)` decreases;
- an `.initialize` that isn't first;
- a second header, and a malformed or unsupported preamble;
- a sync-stream gap at a complete footer, and a duplicate `streamIndex`;
- a truncated tickless record: only the newest pass is withheld.

Controls that must pass:
- a live record whose sequences go down within a batch (a resolver finished a tick late);
- one whose W1 is above every input sequence in its batch. Rev 2's rules would have refused both;
- a long tickless run, with more passes than `maxReadAhead`;
- a live keeper with no port that records with hashes (the recording runner's shape): the hashes are there.

A recorded client payload with an extra field must fail the run (#606 strict).

**Interleavings by holds, not time:**
- a second `step()` during the cursor's read returns `.busy`;
- the step flag is cleared after a read error and after cancellation, and the run has ended;
- a cancellation between a read and its apply: the batch is applied, and the next `step()` ends the run;
- a parked capacity waiter whose run is cancelled is removed;
- a run superseded during a step;
- a viewer that connects before readiness;
- the monitor at the land-wide cap: released by a `TurnVerdict`, released before the wait registers, and woken by a land stop;
- a sync draft delayed past the writer's reorder bound marks the record incomplete.

**Separate-process verify (#51).** The game E2E's `--verify` runs in a new process (`reevaluation-e2e-game.ts:96–97`) in the `e2e-game-tests` job.
- Check against #51's acceptance criterion that the job runs on every PR that touches replay. `e2e-tests.yml` ignores `*.md`, `docs/**`, `Notes/**`, `.devcontainer/**` and `README*` (:7–21). Then close #51.
- S2 adds a tickless land to that run.

**Cost and A/B, per step:**

| Step | What changes on the live path | Tier |
|---|---|---|
| S0 | nothing measured | none (done) |
| S1 | record bytes and the recording path; wire bytes don't change | a Mac output check plus the record goldens. Release builds with recording off and on, base against change: ServerLoadTest (`config.record`) and EncodingBenchmark (`records`). ws-loadtest runs with `ENABLE_REEVALUATION=false` (`run-ws-loadtest.sh:376`) |
| S2 | `runTurn` rewrites the tick and input turns on the live path | the small host A/B, plus #517's windowed gate on the live profiles |
| S3 | the planner extraction touches the adapter's commit | B2's goldens and gate |
| S4 | the monitor land only | none beyond its tests |
| S5 | observer sessions are new membership on the sync-planning hot path | #517's gate and a host A/B |
| S6 | deletes code the exit check shows unreachable | the differential goldens unchanged |

**The recording gate.** `makeTurnRecord` runs on every tick turn, recorder or not. S1 gates typed encoding on a recorder being attached. S2 does the same for these, on `wants`:
- the `ReevaluationRecorded*` values that `applyPendingItem` (LK:3437) and `applyLifecycleItem` (LK:3640) build with no recorder attached;
- the tickless pass numbering that only the record uses.

The state hash keeps today's gate exactly: `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555, :2713; the initialize record at :4844). It doesn't depend on a port. The sync stream keeps its own gate, `recordsSyncStream` (LK:4881).

**E2E:** `test-e2e-game.sh` and the Demo reevaluation E2E, in all three encodings, from S1 on.

## 8. Order relative to #521, #606 and #546

| Step | Needs | Notes |
|---|---|---|
| S0 | nothing | done (#675) |
| S1 | #521's remaining PRs (the typed writer for every payload kind, EV2's static names), #606 (the strict typed decode) | independent of #546 |
| S2 | S1, #546 L1 (#677: no `IN_TURN_SYNC=false`) | `runTurn` replaces the live turn functions' entry, so it's planned against the keeper code of that time |
| S3 | S2, #546 B2 (decision 5's routine, to share its planning half) | #554 is already merged |
| S4 | S2, #387 PR 2 (or it does that migration) | |
| S5 | S2, S3, #546 B3 (membership moved; the initial sync's commit) | its own plan PR first |
| S6 | S2, #546 L2 with groups 2d and 2e | the exit check is in S6's PR; it deletes only what L1 and L2 left |

**Dependencies owned by #546, not steps of this plan:**
- L2 group 2e: live keepers with no port;
- L2 group 2d: live keepers with fake transports;
- B2's `.initialSyncCommit` and B3: the standalone initial sync.

**The graph.** #546's own order is E → L1 → L2 → B1 → B2 → B3 (#546 rev 13, §3.2: L2 comes after L1 and before B1).

```
#521, #606 ──► S1 ──┐
                    ├──► S2 ──┬──► S4 (also #387 PR 2)
#546 L1 (#677) ─────┘         ├──► S6 ◄── #546 L2 (2d, 2e)
                              ├──► S3 ◄── #546 B2   (L2 → B1 → B2)
                              └──► S5 ◄── S3, #546 B3
```

S1 doesn't wait for #546. S2 waits for S1 and L1. S6 waits for S2 and L2, and S3 and S5 for B2 and B3, which come after L2.

## 9. Questions for the maintainer

- **Q1: S0 early.** Answered yes, and done (#675).
- **Q2: 3.x records for readers that don't replay.** The admin record list (#493) and the runner's `--convert`. (`verify-replay-record.ts` replays, so it moves with S5, and its default record is regenerated in S1.) *Recommended:* the list reads the preamble and shows 3.x as "not replayable"; the converter goes, and #343 closes as obsolete.
- **Q3: what a viewer sees.** Broadcast only, as today, or also a recorded player's view through the real adapter. *Recommended:* broadcast by default, and a player's view only when the replay ticket names that player (admin chooses at start). Either way the observer never becomes the player (§5.5).
- **Q4: how a viewer's WebSocket reaches the session.**
  - (a) A replay path served by `ReplaySessions`, with observer admission (§5.5). It never enters `LandManager`/`LandRealm`.
  - (b) An instance of the recorded land type with an ID the session mints. That puts replay sessions back in land listings and on the router's create path.

  *Recommended: (a).*
- **Q5: the keeper's own move onto `TurnCore`.** No issue tracks it. This plan designs on the keeper's synchronous turns, and its seams are the same whether or not the keeper adopts `TurnCore` later. *Recommended:* don't wait for it. File it as its own issue if it's wanted.
- **Q6: the turn instant (deferred).** It isn't recorded in 4.0 (§3.2). It's added when keeper timers or deadlines move into turns, from the keeper's injected clock, land-relative. *Recommended: defer, as written.*
- **Q7: names.** *Recommended:* "replay" for the public surface (`ReplayRun`, `/admin/replay/*`) and "record" for the format. The `Reevaluation*` names go with the types they name, listed per PR as breaking changes.
- **Q8: #441's config fingerprint, declared or inferred.** Either lands and services declare their replay-relevant values (explicit and reviewable), or the host hashes every environment key a land reads (automatic but noisy). *Recommended: declared.* A value that changes behaviour without being declared is the land's bug, and the docs say so.
- **Q9: #526 stays out** (production stream, levels, snapshots). The seams stay: `TurnRecordSink` and `RecordCursor`. *Recommended: out.*

## 10. Issues against this design

| Issue | Outcome |
|---|---|
| #550 | Linked to this plan at GO. Closed by S6's deletion, with its exit check, not at GO |
| #211, #213, #607 | S1 (the 3.x replay readers go; one version authority) |
| #538 | Already closed (#590, #632) |
| #366 | Items 1–3 in S1 (resolved path, one open); 4–6 in S5 |
| #100 | S2 (one step in flight) and S4 (run tickets) |
| #575 | S1 (land ID and header at keeper init) |
| #343 | Obsolete if Q2 drops the converter; otherwise stays |
| #275 | Partly S1 (async reads); the writer's bound stays with #526 |
| #324, #342 | S2 |
| #572 | Stays open as the adapter fix (option A). S3 takes withheld players, uncommitted output and resyncs as recorded facts (§5.3) |
| #386 | Closed by S0 (#675) |
| #441 | S1 (header) and §5.2 (check); Q8 |
| #493 | Stays open; S1's preamble makes it a small change |
| #478 | S2 (typed verdicts) |
| #428 | Stays open. S0 moved its test to the generic path; it is closed by fixing that wait (an event, not a count poll), a small test PR of its own. S5 adds a readiness test for the new start |
| #51 | Provisional: close once the check in §7 holds; S2 adds a tickless land |
| #526 | Out of scope (Q9); the seams stay |
| #387 PR 2 | S4 uses it, or does the migration itself |
| #522 (monitor, legacy tick path) | S4 and S6 |
| #676 (harness flake, `disconnect-during-keeper-join` tickless) | Not this plan's (#678). Noted because S2's and S6's gates run that cell |

## 11. Risks

- **Replay treats live decisions as recorded facts.** Intake, deadlines, router admission and the adapter's lag and ceiling decide things that replay doesn't re-derive. If a live decision isn't recorded, replay can't reproduce it. Mitigation: every decision that changes state or output is a recorded outcome (membership deltas included, §3.1), and S2's and S3's mutants cover each one.
- **S2 reroutes the live turn.** `runTurn` becomes the entry for the live tick and input turns. It's planned against the keeper code at S2's time. Its checks are the differential goldens, #517's gate and the small host A/B.
- **S1 changes what every recording land writes.** DemoServer always records (`Examples/Demo/Sources/DemoServer/main.swift:94`). GameServer records when `ENABLE_REEVALUATION=true`, which the game E2E sets. S1's cost check, the regenerated records and the E2E cover that.
- **The bridge doubles the reader for S1–S2.** It materializes through the cursor, so it adds no second parser. It is deleted in S2 (§4). The runner wrapper that keeps GameDemo working lives until S5.
- **Observer sessions are new adapter surface.** S5 comes after B3, so it's built on the rewritten membership, not added to the old adapter.

## 12. Rev 2: what changed (kept for the record)

| Review point | Change | Where |
|---|---|---|
| MF1: S0's paths | The registrations build live keepers. S0 removes what builds a `.reevaluation` keeper with an adapter, keeps the resolver as a ticket gate, and refuses a non-live keeper in the adapter until S2 | §6 S0 |
| MF2: other off-path users | Listed and assigned | §2.4 |
| MF3: a portless entry | `runTurn(batch, wants:)` | §3.3 |
| MF4: boundary kinds | `.initialize`, `.tick`, `.pass`, `.syncOnly`, `.shutdown` | §3.1 |
| MF5: the check's inputs | Option (b), the shared planner | §5.3 |
| MF6: intermediate merges | S1 ports today's runners; S6 needs S2 and L2 | §6, §8 |
| MF7: 4.0 contracts | Preamble, codecs, one header, streaming | §5.1, §5.2 |
| MF8: the turn instant | Not recorded in 4.0 | §3.2 |
| Shoulds 1–5, nits 1–2 | S0's list, §10, the clock and steps, tests and cost apart, what moves with S5, the two off switches named apart | §3.2, §5.5, §6, §7, §10 |

## 13. Rev 3: what changed

Against rev 2's review of the rest (#612 issuecomment-7025788145).

| Review point | Change | Where |
|---|---|---|
| Correction (initial sync) | The standalone initial sync is #546's (B2 `.initialSyncCommit`, then B3), not L2's and not this plan's | §2.4, §8 |
| MF1: validation rules | Replaced by the live invariants: unique input identity, `(resolvedAtTick, sequence)` non-decreasing within a batch, W1 and W2 non-decreasing across batches and each checked at its own stage, land-wide pass ordinal. The mutants flip, and two live controls must pass | §3.1, §7 |
| MF2: `runTurn`'s contract | (a) `usesInTurnSync` is split into `routesThroughTurn` and `syncsInTurn` at each listed site; (b) `runTurn` returns per-input results, and the drain resumes waiters after the record's submission (`ticklessJobTurns` and the late server-input waiter included); (c) the order W1 → membership → inputs → W2 → handler → committed tick and hash → port → outcome, with the failed-input prefix kept | §3.3, §6 S2 |
| MF3: ownership | Main's call, written the same way in #546 rev 13: live keepers with no port are L2 2e, live fake transports are L2 2d, the initial sync is B2/B3. They are dependencies here, not steps. S6 gets an exit check (traps on every off-path entry, the full matrix green) before the deletion | header, §2.4, §6 S2/S6, §8 |
| MF4: S1's intermediate state | (a) `MaterializedRecordSource`, materialized at open through the cursor, with the definition passed to `openSource`, conversion to today's DTOs, and errors failing the open; (b) the checked-in 3.x records (hero-defense ×3, the SyncOutputGoldens records, the hybrid record) are regenerated in S1's PR | §6 S1, §4 |
| MF5: header bootstrap | The header is complete at keeper init (`RecordingSetup`): land ID, the caller's metadata, `createdAt`, `hardwareInfo` and the sync part, computed statically from the adapter's configuration. A disagreeing port is refused. The headless runner's metadata moves to init | §5.1 |
| MF6: when a batch is final | One-tick lookahead, the gap policy at a complete footer vs at truncation, one shared read-ahead bound, and a smaller writer reorder bound that marks the record incomplete rather than unreadable | §5.1, §7 |
| MF7: `SyncOutputCheck` and its facts | Markers and dispositions are conditions, not checked. Each disposition is named with what it yields (today's verifier's meaning), and skipped or withheld scopes are `notVerified`. "What it can check" is narrowed. The planner's pure input is given as a type, without the adapter's scratch | §5.3 |
| MF8: observers vs closed intake | Observer admission, first sync, the baseline of a recorded player's view and disconnect are defined apart from the player path, in B3's membership model | §5.5 |
| Should 1: membership positions | Every `players` change is a recorded membership item, at the next batch's start, in change order | §3.1, §5.1 |
| Should 2: `.initialize`, `.syncOnly`, failures | `.initialize` only if present; the registration backstop kept in `ReplayRun`'s checks; `.syncOnly` carries `afterPass` and a read position; a failure position may name a stage | §3.1, §3.3, §5.2 |
| Should 3: the step guard | An actor-isolated flag cleared in a `defer`, not `SingleFlight` | §3.4, §7 |
| Should 4: the capacity wait | Check and register in one segment against the land-wide count; any release and termination wake it; retry only while the ticket is current | §5.4, §7 |
| Should 5: `TickProcessedEvent` | Its fields keep their meaning; the result combines the comparator and the sync check; the pointer is corrected | §5.4 |
| Should 6: codecs | `RecordedMembership` for joins (no `@Payload` join payload); the live server-input preflight moves to 4.0 and stays on; resolver outputs keyed by scope and resolver key, with `absent` | §5.1 |
| Should 7: live cost and A/B | The `Recorded*` values, the hash and the pass numbering are gated on `wants`; today's hash gate is kept; the A/B tier per step | §7 |
| Should 8: the parity gate | Aggregation defined; unavailable hashes and skips are `notVerified` per scope; the E2E's "comparable scopes ran" kept; live no-port cases in S2's gate; today's verifier serves S2 until S3 | §3.4, §5.3, §7 |
| Should 9: CI paths | `.devcontainer/**` and `README*` added | §7 |
| Nit 1: #550 | Linked at GO, closed by S6 with its exit check | §10 |
| Nit 2: `createdAt`, `hardwareInfo` | Kept in the header, pinned for #327 as today | §5.1 |
| After S0 | Base moved to 4fbe76c6; S0 recorded as done; #386 closed; #428 stays open with its own fix; #676 noted | header, §6, §10 |

## 14. Rev 4: what changed

Against rev 3's review (#612 issuecomment-7026974327). Every statement about today's code was checked again at 4fbe76c6.

| Review point | Change | Where |
|---|---|---|
| MF1: membership and handlers | A membership delta (insert, replace, remove, rollback) is apart from the lifecycle item. Deltas apply at the batch's start, on replay only. Lifecycle items stay sequenced inputs in `applyInputs`' order. The schema is pinned against `InternalPlayerSession` and the handler's context. Services come from `ReplayRun`'s caller | §3.1, §3.3 step 2–3, §5.1 |
| MF2: tickless lookahead | Lookahead and truncation are per boundary. 4.0 writes one frame per boundary. A long tickless run is a control | §5.1, §7 |
| MF3: the hash gate | `enableLiveStateHashRecording && reevaluationRecorder != nil` (LK:4741, :4555, :2713; initialize at :4844) in all four places. LK:4881 is `recordsSyncStream`. §5.6's setting is that flag | §2.1, §3.3 step 7, §5.6, §7 |
| MF4: the disposition table | Every row taken from SV:307–520 as it is: uncommitted drops its staged cache (resend or diverged), encode drops cover events and diverge a seeded player, unverified is two cases, `eventsNotQueued` keeps the hash comparable, plus the seed, clear and missing-hash rows | §5.3 |
| MF5: GameServer's replay through S5 | `ConcreteReevaluationRunner` stays as a wrapper over `ReplayRun` with today's contract (`replayFrame` included) until S5. The generic viewer E2E gates S2. The bridge goes in S2 | §3.4, §4, §6 S2/S5, §11 |
| MF6: the cursor's owner, cancellation, no-port outputs | `ReplayRun` owns the cursor; `.replay` only closes intake. A read batch is always applied; a cancelled or failed read ends the run. With no port, `runTurn` takes events and the sync request into the outcome | §3.1, §3.3 step 8, §3.4, §7 |
| Should 1: validation | Unique sequence, not (kind, sequence). Structural checks apart from divergence. The restore at both stages; an overrun is `mismatch(.watermark)` and the run goes on | §3.1, §7 |
| Should 2: sites and failures | Sites grouped as routing, port output, or both (with each split). Results stay in `inputTurnResults` across the submission. Failed tick and pass rules written into steps 4 and 9 | §3.3 |
| Should 3: header-only open, bridge mapping | `RecordCursor.readHeader(filePath:)` for the callers with no definition and Q2. The bridge's mapping of passes, initialize, failure and lifecycle; deltas dropped through S1 | §5.1, §6 S1 |
| Should 4: the rest of the header | One resolved sync configuration for the header and the adapter. Both directions checked. OnInitialize waits for the port when the header records a sync stream. EncodingBenchmark's setter moves | §5.1 |
| Should 5: sync entry finality | An entry is handed out when its index is next and its boundary is final, so it never disappears. Duplicate indices refused. The writer closes the valid prefix past its bound. Writer and reader measure the same frames and bytes | §5.1 |
| Should 6: the planner's input | `SyncPatchPlanInput` (state, planned players, extraction drops, layout, cache policy, event window), apart from live delivery decisions and verifier-only facts | §5.3 |
| Should 7: S5's plan inputs | The adapter's precondition through S2 and S5; the observer's first sync needs | §5.5, §6 S2 |
| Should 8: `TickProcessedEvent` | Today's `expectedState` meaning stated. A recorded snapshot when there is one, `hasRecordedState`, `verdict`, and the summary counts | §5.4 |
| Should 9: the capacity wait | Applying or dropping frees a slot, an intake refusal doesn't. Cancellation removes a parked waiter. The ended and unlimited cases | §5.4, §7 |
| Should 10: deletion list and order | #546 deletes `IN_TURN_SYNC` (L1) and `beginSync`/`endSync`, `syncNowFromTransport` (L2); S6 deletes only the rest. The graph drawn, S1 independent of #546 | §6 S6, §8 |
| Should 11: the fixtures' tests | A two-commit check of each regenerated record against its 3.x original. Which historical assertions retire and what replaces them | §6 S1 |
| Should 12: S2's parity driver, resolver lookup, failure stages | The verifier's preload in S2 and how its results become verdicts; per-scope E2E assertions kept. A resolver descriptor API in S1. `.eventFlush`, `.actionResponse`, `.legacyCycle` reads and shutdown placed | §3.1, §5.1, §6 S2, §7 |
| Nit 1 | The land ID enters the keeper's init (LM:623) | §2.1 |
| Nit 2 | "A malformed or unsupported preamble" | §7 |
| Nit 3 | Today's viewer joins the live `GenericReplayLand` | §5.5 |
