# Replay on typed inputs and the keeper's turns (#612, with #550)

**Status:** rev 3, design for review.
- **S0 is done:** GO at rev 2, merged as #675 (4fbe76c6). §6 S0 records what it did.
- **Rev 3** answers rev 2's review of the rest: 8 must-fix, 9 should and 2 nits, in #612 issuecomment-7025788145. What changed is in §13.
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
- **One input source per keeper,** chosen at construction: live intake (transport, router, server inputs) or a record cursor.
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
- **The state hash** is computed only when `mode == .live && reevaluationRecorder != nil && usesInTurnSync` (LK:4881).
- **Sync stream.** The adapter submits it as drafts, and only with in-turn sync.
- **Metadata.**
  - The keeper's land ID is set after init (`setLandID`, LM:628).
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
             │ record cursor: recorded boundaries, validated, in order     │
             └──────────────────────────┬──────────────────────────────────┘
                                        │ TurnBatch (§3.1)
                                        ▼
       ┌───────────────────── LandKeeper.runTurn(batch) ─────────────────────┐
       │ synchronous, in this order (§3.3): W1, membership, inputs, W2,      │
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
- **`.record(RecordCursor)`:** the public intake is closed. Every live entry point refuses with one reason, `.replaying`. That covers `join`/`joinReportingAdmission`, actions, client events, server inputs and leaves. It replaces #387's `.notLive` and the mode checks in the client-event, action and server-input intake. The keeper doesn't start initialization (§3.3).

**The cursor yields boundaries, and each boundary is a `TurnBatch`:**

| Kind | Carries | Today's counterpart |
|---|---|---|
| `.initialize` (only when the land has OnInitialize) | the recorded resolver outputs for OnInitialize, and its outputs (events, state hash) | the initialize entry. A land with no `onInitialize` writes none (LK `performInitialization`) |
| `.tick(id)` | its membership items and inputs in applied order, the watermarks W1 (read at turn start) and W2 (read after the inputs), and the recorded outcome (rejected inputs, failure position, events, state hash) | one tick turn record |
| `.pass(tick, ordinal)` | a tickless land's membership items and inputs for one pass, its watermark and its outcome. One tick may have several. The ordinal is land-wide and continues across ticks | #325's passes |
| `.syncOnly(observedTick, afterPass, readPosition)` | no inputs; the recorded sync outputs it produced. `afterPass` and the read position place it between two passes of one tick | sync-only turns, stream `turnKind .syncOnly` (`ReevaluationSyncStream.swift:16`) |
| `.shutdown` | the shutdown lifecycle entry | the shutdown turn |

**Membership items.** On live, `players` changes outside the turn, before the resolvers are awaited: the join paths at LK:1581 and :1803, the leave at :2499, and the removals of a join that didn't complete (a drain during its resolvers at :1628 and :1856, a failed OnJoin resolver at :5586). Some of these changes queue no lifecycle item at all: no `onJoin`/`onLeave` handler, or a reconnect that replaces the entry.
- **Recording.** Every `players` change is recorded as a membership item, not only the handler items. It goes into the next batch the keeper runs after the change, in change order, ahead of that batch's inputs. A turn sees every change made before it starts, so this is the position the turn observed.
- **What an item carries:** player ID, client ID, session ID, guest flag, device ID and metadata (`ActionRecorder.swift:400–412`), plus whether a handler runs. S1's PR pins the field list against `PlayerSession`.
- **On replay,** `runTurn` applies each item to `players` at its position, then runs its handler if the item says one ran.
- **On live,** the change has already happened, so `runTurn` runs only the handler (`membership: .alreadyApplied`). When #588 moves the join into its turn, both sides use `.applyInTurn`.

**Validation before apply.** The cursor checks each boundary before handing it out. A violation ends the run with `recordInvalid(position, rule)`, before anything of that batch applies. These are the invariants a live record actually has:
- every input's identity (its kind and sequence) is unique in the record;
- within a batch, the inputs' `(resolvedAtTick, sequence)` doesn't decrease. That is execution order (`readyPendingItemsInOrder`, LK:3400–3409). Sequences alone may go down: an input whose resolver finished a tick later runs after one with a higher sequence, and so does a frozen server input applied after a later join;
- W1 doesn't decrease across batches, and neither does W2;
- each watermark is checked at its own stage:
  - W1 is checked before the inputs apply;
  - W2 is checked after they apply, and before the tick handler, which moves it as it emits;
- tick IDs don't decrease;
- the pass ordinal is consecutive land-wide, including across ticks;
- `.initialize`, if present, comes first;
- a failure position names an input in its batch, or a stage of the batch: the tick handler, the sync phase, or the end of inputs (`LandFailurePosition.endsInputs`). A sync-stage failure has no failing input.

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

S2's PR lists each of these sites with the predicate it takes:
- initialize: LK:1193;
- join: :1651 and :1889;
- actions: :2202 and :2657;
- leave: :2585;
- client events: :2909 and :3046;
- server input: :3153;
- tick: :4250 and :4300;
- tickless turns: :5442 and :5539;
- the helpers: :637, :859, :1903–1924, :4881 and :5062.

**What `runTurn` does, in order.** This is the order `runTickTurn` has today (LK:4705–4773), kept.
1. **W1.** It sets W1. On replay it checks the recorded W1 against the outcome counter, as #72's restore does.
2. **Membership.** It applies the batch's membership items (§3.1): on replay `players` changes and then the handler runs; on live only the handler runs.
3. **Inputs.** It applies the inputs in the batch's order (`applyInputs`). A failing input fails alone.
4. **A land failure in the inputs** stops the batch at its position (#535). The outcome is the failed prefix: the applied inputs and the failure position. There is no W2, no state hash, no events and no sync. The turn ends here.
5. **W2.** It sets W2, and replay checks it.
6. **Tick handler.** For `.tick` it runs the tick handler.
7. **Committed tick and hash.** It commits the tick. It computes the state hash only when `wants.stateHash` is set. A recorder sets it under today's gate (LK:4881: a recorder is attached and the sync runs in the turn), and a comparator sets it on replay.
8. **Port.** When `syncsInTurn`, it calls the port with the events and the sync request (`runTurnOutputs`). The port can fail the land, and it routes the events: `includeSync == false` sends events without a sync. So nothing is final before this call.
9. **Outcome.** It builds `TurnOutcome` after the port returns: the applied inputs with a result per input, the rejected inputs, the events, the failure position (including a sync-stage failure from step 8), the watermarks, and the hash.

**After `runTurn`, outside it.** The caller that ran the turn does the rest, as today:
- **live:** it submits the record (`await submitTurnRecord`). Only then does it resume the waiters with each input's result from the outcome (`resumeInputTurnWaiters`, LK:5381–5393). So a caller sees its result only after its record is submitted. The same holds for `ticklessJobTurns` and the late-registering server-input waiter;
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
- It builds the keeper with `.record(cursor)` and attaches the observers the caller asked for, plus a port for a viewer (§5.5).
- `step()` reads the next boundary, then runs it with `runTurn` and returns the verdicts. `runToEnd()` loops it.
- **One step in flight.** It is an actor-isolated flag:
  - `step()` checks the flag and sets it in one segment, before the cursor's async read;
  - a second call while the flag is set returns `.busy` at once;
  - a `defer` clears the flag on every exit: success, a read error, cancellation, and supersession by a newer run.

  This isn't `SingleFlight`: `SingleFlight.flight(for:start:)` gives a second caller the task already in flight (`SingleFlight.swift:46–58`), and never returns `.busy`. Reentrancy during the read can't start a second step (#100's step race).
- It owns its keeper. The keeper is single-use and dropped at the end of the run.

## 4. What goes away

| Today | Fate | Step |
|---|---|---|
| `LandKeeperModeConfig.reevaluation`, `LandManager`'s `.reevaluation` branch, the adapter flag's `!isReevaluationKeeper` term, `registerWithReevaluationSameLand`, `registerWithReevaluation` and their resolvers | Deleted. The adapter refuses a non-live keeper | S0 (done, #675) |
| `LandMode`, `ReevaluationOutputMode` (LK:32–43) | Deleted. The input source and the observers replace them | S2 |
| The keeper's mode branches | Each becomes intake closed, cursor validation, a `runTurn` step, an observer, or nothing (viewers aren't players, §5.5). S2's PR lists each site with its fate | S2 |
| `runTick`'s replay pull and `replayInitializeBeforeTickZero` | Replaced by the cursor and `runTurn` | S2 |
| The keeper's off path: `processPendingActions`, `replayRecordedPasses`, `deliverLegacyPass`, the legacy `runSync` loop, `syncNowFromTransport`, `beginSync`/`endSync` | Unreachable after S2 and #546 L2; deleted after S6's reachability check | S6 |
| `ReevaluationEngine`, `ConcreteReevaluationRunner`, `CapturingSink` | Replaced by `ReplayRun` and `TurnComparator` | S2 |
| `SyncOutputReplayDriver` (the shadow's driver) | Replaced by `SyncOutputCheck`'s driver on the shared planner (§5.3) | S3 |
| `GenericReplayLand`, `ReevaluationReplayProjector` (the hard-coded "hero-defense" projector), `DecodeReplayState`, the replay use of `fromBroadcastSnapshot`, `registerWithGenericReplay`, `replayLandSuffix` (configuration, `NIOLandServer`, `LandTypeRegistry`, `NIOAdminRoutes`), `ReevaluationReplaySessionDescriptor`, `/admin/reevaluation/replay/start` | Replaced by replay sessions (§5.5) | S5 |
| The 3.x replay readers and their compatibility branches (#211, #607) | Deleted when 4.0 is the written format and the checked-in records are regenerated | S1 |
| The S1 bridge (`MaterializedRecordSource`, §6 S1) | Deleted when its last user moves: the runners in S2, `GenericReplayLand` in S5 | S5 |

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
| Membership item (join, leave, replacement; §3.1) | `RecordedMembership`, a `Codable` struct: player ID, client ID, session ID, guest flag, device ID, `metadata: [String: String]`, whether a handler ran. Canonical MessagePack, named keys. There is no `@Payload` join payload: a join carries `PlayerSession` fields and string metadata (`ActionRecorder.swift:400–412`) | synthesized `Codable` | the run ends |
| Server input (`ServerInputPayload: Codable`, #387) | canonical MessagePack of its `Codable` encoding, named keys. It stays `Codable` (#387's plan, outside #521) | `serverInputRegistry` by its type identifier, synthesized `Codable` | the run ends |
| Resolver output (`Codable & Sendable`, `ResolverOutput.swift:23`) | canonical MessagePack of its `Codable` encoding, named keys, keyed by its scope (the item's kind and sequence, or OnInitialize) and its resolver key. An output that is absent on purpose (a resolver that didn't run, or returned nothing) is recorded as `absent`, not left out | the cursor looks up the declared output type in the definition's resolver table by handler and resolver key | the run ends; an output with no declared type is `recordInvalid` |
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
- **Where the sync part comes from.** `LandManager` computes it before building the keeper, from the configuration it gives the adapter. That needs a static `TransportAdapter.recordSyncConfig(for:)`, which today's instance property `syncConfigForRecord` becomes.
- **"No port, ever" vs. "port not attached yet."** These are told apart by the init parameter, not by timing: `.notRecorded` is "no sync stream". The headless runner and keepers with no port pass it.
- **A port that disagrees.** When `setTransport` attaches a port whose sync config differs from the header's `.recorded(syncConfig)`, the keeper refuses it with a precondition. That is a wiring bug.
- **The headless runner's metadata.** `ReevaluationRunner/main.swift:459–471` calls `setLandID` and `setMetadata` after init. That moves to `RecordingSetup` too.
- **A second header** is a format violation, and the reader refuses it. Today a later header replaces the earlier one.

**The cursor (streaming): when a batch is final.**
- **The file has two streams in one handle.** Turn frames (batches) are written in their turn, in order. Sync frames are the sync stream, read in `streamIndex` order.
- **Lookahead: one tick.** The cursor holds a tick's batches until it has read the next tick's first turn frame, or the footer. Only then does it hand them out. It never hands out a batch it might later withhold.
- **Truncation.** A file without its footer, or with `complete == false`:
  - the held newest tick is withheld, as today;
  - the batches before it are final;
  - the verdicts for the withheld tick and everything after are `notVerified(.truncated)`.
- **Gaps in the sync stream:**
  - at a complete footer, a missing `streamIndex` is a format violation (`recordInvalid`);
  - at truncation, the sync stream is cut to its dense prefix, and the outputs after the cut are `notVerified(.truncated)`.
- **Bounded read-ahead.** Filling a sync-stream gap reads forward, past turn frames that aren't due yet. Those frames wait in a turn-frame buffer.
  - Both buffers share one bound, `RecordCursor.maxReadAhead` (a frame count and a byte count). Above it the record is refused.
  - The writer keeps its reorder distance under a smaller constant, `ReevaluationRecorder.maxReorderDistance`. A sync draft written further than that from its turn's frame marks the record incomplete at that point (the footer's `complete = false`, with a reason), instead of writing a file the reader refuses.
  - S1 tests both bounds with a hold that delays one draft, not with timing.
- **Frame size:** each frame is bounded by a reader limit, and refused above it.
- **Opening.** The path is resolved once to its real absolute form: symlinks, and a relative `REEVALUATION_RECORDS_DIR`. Containment is checked on the resolved path, and the file is opened once. The run keeps that handle (#366 items 1–3). Reads are async (#275).

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

**What it takes as fact.** These recorded facts are conditions for a hash check. The check doesn't confirm that they should exist, or their order: a recorded fact can't verify itself. Each fact keeps today's meaning in `SyncOutputVerifier.output(_:observedTickId:state:)` (SV:344–520), and each yields the following.

| Recorded fact | What it yields |
|---|---|
| Seed and clear markers (the ordered membership of the sync set) | who is planned at each output. A player is planned from its seed to its clear. The adapter can emit a clear before a resync output and a seed after it (TA's resync handling), so the order is taken as recorded |
| `extractionDrops[scope]` | the scope's dropped keys keep their cached values in the replayed snapshot (`substituting`), and the hash is compared |
| `resetsKeyScopes` | the planner resets that output's key scopes before planning, as live did |
| `encodeDropScopes` | broadcast or a seeded player: the hash is compared, and delivery is `notVerified(.encodeDropped)`. A joiner whose whole view didn't encode: `notVerified(.viewNotSent)`, and it stays pending |
| `eventsNotQueued`, `eventsNotMerged` | those sequences are left out of the event comparison. The output's events are `notVerified(.eventsNotMerged)` |
| `perPlayerUnverified` (a withheld player, e.g. sync lag, #572 option A, or a player not addressed) | the player is neither compared nor staged: its baseline doesn't move. `notVerified(.withheld)` |
| `perPlayerUncommitted` | the player is planned and apply-checked against the replayed state, and its baseline moves as planned. The record holds only its ID, not a plan hash, so its hash isn't compared: `notVerified(.uncommitted)` |

A skipped or withheld scope yields `notVerified`, never `match`.

**What it can check:** the content of broadcast and per-player diffs, and how each scope's baseline evolves, given the recorded markers and dispositions. It also checks event order. It can't check:
- whether a marker or a disposition should exist;
- what lag, ceilings, backpressure or the socket decided.

**The planner: option (b), shared and narrower.** S3 takes the planning half of B2's routine (decision 5's `planAndCommit`) into a deterministic function that the adapter's machine and the check both call:

```swift
struct SyncPlanInput {
    let state: LocatedStateRead          // the keeper's state after the batch
    let planned: [PlayerID]              // the sync set at this output (adapter: its membership view; check: the markers)
    let dispositions: SyncOutputDispositions  // the table above; empty on live
    let mode: SyncPlanMode               // full, broadcast-only, resync
}
func plan(_ input: SyncPlanInput, caches: inout SyncEngine.Caches) -> SyncPlan
```

The adapter's phase scratch isn't an input. The adapter keeps commit, the writer, lag and ceilings, and gives the planner its membership view. The check has no scratch. It gives the planner the markers and the dispositions. S3's PR fixes the final names against B2's code.

**Rejected:** option (a), recording the phase's full inputs (recipients, sessions, lag state, joins, scratch). It grows every recorded turn on the live path to replay something the record already states as outcomes.

**#554 is closed.** It extracted the stateless encoding and frame building, not `planAndCommit`. S3 needs B2's routine (§8).

**Until S3,** S2's `ReplayRun` drives today's `SyncOutputVerifier` through its existing driver, as an observer. That is the sync verifier §7's S2 gate compares against.

**Viewer runs.** In S5 a viewer's observer sessions aren't the recorded players. When a viewer run verifies per-player output, the check runs beside the viewer's port, on the recorded membership, never on the observers.

### 5.4 The monitor and the run service

- **Runs and tickets.** `ReevaluationRunnerService` keeps runs keyed by a run ticket (a `GenerationTable`). A new run supersedes the old one, and a stale run's results are dropped by its ticket (#100).
- **Results as server inputs.** The run reports through `submitServerInput` (#387): `RunProgress` and `TurnVerdict`, each carrying the run ticket. The monitor's handlers keep the current ticket in state and drop an input from another run. The monitor's tick no longer reads the service, so CLAUDE.md's monitor exception and #522's item go.
- **The bound is land-wide.** `serverInputMaxInFlight` is one cap for the land (LK:379, :3113), shared by `RunProgress` and `TurnVerdict`. #387's submit refuses at the cap at once (`.overCap`). The run then waits for capacity through a new keeper call, `awaitServerInputCapacity()`:
  - **check and register in one segment:** if the land-wide count is under the cap, it returns at once. Otherwise it registers its waiter in that same actor segment, so a release between the check and the registration can't be missed;
  - **any release wakes it:** applying or refusing any server input of any type frees a slot and resumes one waiter;
  - **termination wakes it:** the land draining, failing or stopping resumes every waiter with `.landEnded`;
  - **the run's loop retries the submit only while its run ticket is current.** A superseded run stops.

  Nothing else holds results, so `resultsQueue`'s unbounded growth goes (`ReevaluationRunnerService.swift:301`).
- **`TickProcessedEvent` keeps its fields and their meaning** (`ReevaluationMonitorEvents.swift:61–68`, emitted at `ReevaluationMonitorLand.swift:60–68`):
  - `expectedHash` is the recorded state hash;
  - `expectedState` is the recorded state.

  Its match result is the batch's aggregated verdict (§3.4), which combines the comparator and the sync check:
  - `mismatch` if either says mismatch;
  - otherwise `notVerified` if either says notVerified;
  - otherwise `match`.

  Rev 2 pointed at :56–58, which is `TickSummaryEvent`.

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

  Today's replay keeper inserts viewers as players and skips OnJoin, which goes. S5's own plan PR details these against B3's code.
- **Pacing.** A driver task steps the run on the viewer's clock (§3.2), with a speed factor (1× by default), pause, and seek-forward. Seek-backward needs snapshots (#526) and isn't in scope.
- **Same definition.** The session's keeper is built from the registered `LandDefinition` of the recorded land type, so its path hashes, event hashes and fingerprint are the live land's.
- **Moved in S5 with it:**
  - the admin routes and the monitor WebClient's routes;
  - `verify-replay-record.ts`, a replay client over HTTP, not a record reader;
  - the CLI replay E2E (`reevaluation-replay-e2e-game.ts`) and its `test-e2e-game.sh` wiring;
  - `docs/core/reevaluation.md` and `docs/transport/auth.md`, with their zh-TW companions.

### 5.6 Recording

- **The recorder is an observer** (`TurnRecordSink`) on a live keeper. The host enables it through a host-level setting, not the state-hash flag. The setting only attaches the recorder. It doesn't widen today's hash gate (LK:4881).
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
  - membership items for every `players` change;
  - one header, complete at keeper init (`RecordingSetup`);
  - the preamble as the version;
  - the writer's reorder bound.
- **The cursor** reads 4.0 (§5.1, §3.1 validation).
- **The bridge.** Today's runners address the record by tick: the max tick, the whole sync stream, completeness and the land failure before tick 0, then several getters per tick, with the verifier querying the same tick again. A forward-only cursor can't serve that. S1 adds `MaterializedRecordSource: ReevaluationSource`:
  - **at open,** it reads the whole 4.0 file through the cursor, so validation and decoding happen once;
  - **an index** by tick serves every getter, and `getSyncStream()` serves the materialized sync stream;
  - **the definition** reaches it through `openSource(filePath:definition:)`, which gains the definition parameter. 4.0's positional client payloads need the definition to decode;
  - **conversion to today's DTOs:** each decoded typed value is converted back to the DTO today's keeper decodes (`ReevaluationRecordedAction` and the others, with `AnyCodable` payloads), through the value's `Encodable` form;
  - **errors:** a cursor error fails the open, so the run is refused before its first step. The keeper's two error paths can't be reached through the bridge: it treats a failed max-tick read as EOF, and it logs a failed tick read and goes on. S1 adds a test that a corrupt 4.0 file fails at open;
  - **its users** are `ReevaluationEngine`, `ConcreteReevaluationRunner` and `GenericReplayLand`'s run, until S2 and S5 replace them.
- **The checked-in 3.x records are regenerated with the 4.0 writer in S1's PR,** with the command for each in the PR:
  - `Examples/GameDemo/reevaluation-records/{1,2,3}-hero-defense.sstr`. `verify-replay-record.ts:85` defaults to `3-hero-defense.sstr`, and `test-e2e-game.sh:293` calls it without a record path; `HeroDefenseReplayStateParityTests.swift` reads them;
  - `Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/*.reeval.sstr` (five files);
  - `Tests/SwiftStateTreeTransportTests/Fixtures/HybridEventFrames/hybrid-record.sstr`.

  Keeping the 3.x reader until those consumers move is the alternative. It is rejected: it keeps #211's branches alive through S5.
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
- **The runners:** the CLI runner and the monitor's runner move to `ReplayRun` and `TurnComparator`. Today's `SyncOutputVerifier` serves as the sync observer until S3.
- **Tests:** the keeper-side tests that used `.reevaluation` with fake transports are converted to `.record` keepers.
- **Not in S2:** live keepers with no port, and live keepers with fake transports, keep `routesThroughTurn == false`. They are #546 L2 groups 2e and 2d.
- It covers #324, #342 and #478.

**S3: `SyncOutputCheck` on the shared planner** (§5.3). It needs S2 (`ReplayRun` drives it) and B2 (the planner's source). It deletes `SyncOutputReplayDriver`.

**S4: the run service and the monitor** (§5.4). It needs S2 and #387 PR 2, or does that migration itself. It covers #100 and #522's monitor item.

**S5: replay viewing** (§5.5). It needs S2, S3, and #546 B3 (observer membership is new membership, and the initial sync is B3's). It gets its own plan PR first.
- It deletes `GenericReplayLand`, the projector, `registerWithGenericReplay`, every suffix site and the S1 bridge.
- It moves the clients and docs listed in §5.5.
- It covers #366 items 4–6.

**S6: the deletion.** It needs S2 and #546 L2, including groups 2d and 2e. It doesn't need S3–S5.
- **Exit check first, in the same PR.** S6's first commit makes each off-path entry trap:
  - `processPendingActions`;
  - `replayRecordedPasses`;
  - `deliverLegacyPass`;
  - the legacy `runSync` loop;
  - `syncNowFromTransport`;
  - `beginSync`/`endSync`.

  Each becomes `preconditionFailure("off path reached: <name>")`. The full matrix must be green on that commit: `swift test` in every CI variant, the differential harness with every cell (the legacy cells as L2 left them), the live fake transports, E2E in all three encodings, and the benchmarks' smoke runs. A trap that fires names the caller still to move, and S6 stops there.
- **Then the deletion,** in the second commit:
  - the keeper's off path;
  - `beginSync`/`endSync` and `syncNowFromTransport`;
  - `routesThroughTurn`, now constant;
  - the remaining `IN_TURN_SYNC` code;
  - the #546 decisions that guard the legacy cycle (decisions 1 and 4, already superseded by L2).
- This is #550's outcome and #522's "legacy tick path" item.

## 7. Verification

**Determinism, before and after S1/S2.** The scenarios are those under `Tools/CLI/scenarios/game/`, a tickless land with several passes under one tick and a sync-only phase between them, and the Demo counter land. The gate:
- recording with S1 and verifying with the bridged runner, then with S2's `ReplayRun`, gives the same verdicts turn for turn;
- verdicts aggregate as §3.4 says. `match` is required where the record has the field and the scope was compared. Today's verifier also reports unavailable hashes and scope-level skips, and these come out as `notVerified(reason)` per scope, with the same reasons on both sides;
- the E2E keeps its requirement that comparable scopes actually ran (`reevaluation-e2e-game.ts:103–107`): a run with zero compared scopes fails, even with no mismatch;
- the live client frames are compared by the differential harness's goldens (#555). The record bytes are compared on their own: their goldens change once in S1 and are deterministic (no wall time), and `RecordTurnBoundaryLiveTests`' byte identity holds;
- S2's gate also runs live keepers with no port, unchanged (they keep their path until 2e). This pins that S2 didn't move them.

**Mutants.** Each must fail with its own verdict or error:
- a replayed input applied in another order, and a dropped recorded input;
- a wrong seed, a changed config value, a stale fingerprint, and an initial-state hash that doesn't match;
- a pass ordinal skipped (land-wide);
- a W1 or W2 lower than the previous batch's;
- a duplicate input identity;
- a batch whose `(resolvedAtTick, sequence)` decreases;
- an `.initialize` that isn't first;
- a second header, and a preamble that disagrees;
- a sync-stream gap at a complete footer.

Two controls must pass: a live record whose sequences go down within a batch (a resolver finished a tick late), and one whose W1 is above every input sequence in its batch. Rev 2's rules would have refused both.

A recorded client payload with an extra field must fail the run (#606 strict).

**Interleavings by holds, not time:**
- a second `step()` during the cursor's read returns `.busy`;
- the step flag is cleared after a read error and after cancellation;
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

**The recording gate.** `makeTurnRecord` runs on every tick turn, recorder or not. S1 gates typed encoding and the state hash on a recorder being attached. S2 does the same for these, on `wants`:
- the `ReevaluationRecorded*` values that `applyPendingItem` (LK:3437) and `applyLifecycleItem` (LK:3640) build with no recorder attached;
- the state hash;
- the tickless pass numbering that only the record uses.

Today's hash gate (LK:4881) is kept exactly. §5.6's host-level setting doesn't widen it.

**E2E:** `test-e2e-game.sh` and the Demo reevaluation E2E, in all three encodings, from S1 on.

## 8. Order relative to #521, #606 and #546

| Step | Needs | Notes |
|---|---|---|
| S0 | nothing | done (#675) |
| S1 | #521's remaining PRs (the typed writer for every payload kind, EV2's static names), #606 (the strict typed decode) | independent of #546 |
| S2 | S1, #546 L1 (no `IN_TURN_SYNC=false`) | `runTurn` replaces the live turn functions' entry, so it's planned against the keeper code of that time |
| S3 | S2, #546 B2 (decision 5's routine, to share its planning half) | #554 is already merged |
| S4 | S2, #387 PR 2 (or it does that migration) | |
| S5 | S2, S3, #546 B3 (membership moved; the initial sync's commit) | its own plan PR first |
| S6 | S2, #546 L2 with groups 2d and 2e | the exit check is in S6's PR |

**Dependencies owned by #546, not steps of this plan:**
- L2 group 2e: live keepers with no port;
- L2 group 2d: live keepers with fake transports;
- B2's `.initialSyncCommit` and B3: the standalone initial sync.

The sequence: S0 (done) → #546 L1 → S1 (once #521 and #606 land) → S2 → L2 → S6. In parallel: B2 → S3, B3 → S5, and S4 after S2.

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
| #676 (harness flake, `disconnect-during-keeper-join` tickless) | Not this plan's. Noted because S2's and S6's gates run that cell |

## 11. Risks

- **Replay treats live decisions as recorded facts.** Intake, deadlines, router admission and the adapter's lag and ceiling decide things that replay doesn't re-derive. If a live decision isn't recorded, replay can't reproduce it. Mitigation: every decision that changes state or output is a recorded outcome (membership items included, §3.1), and S2's and S3's mutants cover each one.
- **S2 reroutes the live turn.** `runTurn` becomes the entry for the live tick and input turns. It's planned against the keeper code at S2's time. Its checks are the differential goldens, #517's gate and the small host A/B.
- **S1 changes what every recording land writes.** DemoServer always records (`Examples/Demo/Sources/DemoServer/main.swift:94`). GameServer records when `ENABLE_REEVALUATION=true`, which the game E2E sets. S1's cost check, the regenerated records and the E2E cover that.
- **The bridge doubles the reader for S1–S5.** It materializes through the cursor, so it adds no second parser. It is deleted in S5 (§4).
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
