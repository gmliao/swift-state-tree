# Replay on typed inputs and the keeper's turns (#612, with #550)

**Status:** rev 2, design for review. It answers rev 1's review: 8 must-fix, 5 should and 2 nits, posted on #612 at 443723d8; what changed is in §12. Doc only. No code until this plan is GO, the maintainer has answered §9, and each step's prerequisites (§8) have merged.

**Issue:** #612. #550 is folded in (maintainer, 2026-11-20). This plan answers #550's question and #546 L2's open group 5 ("reevaluation keepers: in-turn, or a replay-only cycle").

**Base:** `main` at 533d6f44, with line pointers at that SHA. "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, "LM" `Sources/SwiftStateTreeTransport/LandManager.swift`, "TA" `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, "RF" `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`, "RL" `Sources/SwiftStateTree/Runtime/ReevaluationRecordLog.swift`.

**Inputs read:**
- #612 and the issues it names, and #550;
- #521 and its plan (`2026-11-13-typed-events-actions.md`, rev 20);
- #606 with its strict-decode decision (2026-11-18);
- #655's plan rev 9 (`2026-11-19-adapter-turn-core-rewrite.md`, on its branch: §3.2 L1/L2, §3.3 decision 5) and its review;
- the turn core plan (`2026-11-18-swift-state-turns-core.md`);
- #387's plan (`2026-11-09-server-turn-inputs.md`).

**Solutions consulted:** `Notes/solutions/` has no entry for replay identity, record readers or mode flags. The reentrancy rule in CLAUDE.md and `2026-11-05-reentrancy-helpers.md` applies to the run's step and to the run service (§3.4, §5.4).

## 1. Goal

Replay feeds the recorded inputs into the same keeper turn a live land runs, in recorded order and at the recorded boundaries. Each run sends the turn's outputs where it needs them.

- **One machine.** A replaying keeper runs one synchronous turn entry point (§3.3), the one a live keeper runs too. There's no `LandMode`, and no apply-path branch on being a replay.
- **One input source per keeper,** chosen at construction: live intake (transport, router, server inputs) or a record cursor.
- **Outputs:**
  - the sync phase runs through a transport port when one is attached;
  - observers read each turn's outcome: the recorder, the turn comparator and the sync-plan check.
- **No second land type:** no `-replay` suffix, no alias in `LandTypeRegistry`, and no keeper mode resolver that switches the keeper's mode.

What this plan doesn't change:
- the live path's behaviour and its bytes to clients;
- the record as the only source of a replay's inputs;
- the rule that game logic reads time only as a tick ID (`LandContext.swift:99`);
- the record's byte identity (#327, §5.1).

## 2. Today

### 2.1 Recording (live)

- **When it records.** The recorder exists when `mode == .live && enableLiveStateHashRecording` (LK:945–970).
- **Turn records.** The keeper's turn builds a `ReevaluationTickRecord` (`makeTurnRecord`, LK:4795) on every tick turn, recorder or not (LK:4763). It submits it after the turn (LK:4790, :4983–4996). The legacy path records from `processPendingActions` (LK:3776–3793) and `flushOutputs` (LK:591–603).
- **Sync stream.** The adapter submits it as drafts (TA:4007–4050, LK:4927–4978), and only with in-turn sync (LK:4875).
- **Metadata.** It's set in `LandManager.buildLand` after the adapter exists (LM:737–773). A later header replaces an earlier one (RL:287).
- **Payloads.** Inputs are recorded as `AnyCodable` (`ActionRecorder.swift:741`, :777, :799, :831), and so are resolver outputs (:6–16). Server inputs pass through `ServerInputCodec.recordedForm` even when nothing records (LK:3099).
- **Format.** 3.6 by the metadata version (`ActionRecorder.swift:231–235`), but the preamble writes `(3, 5)` (RL:27). Canonical MessagePack. The reader takes the whole file (RL:240–335). It assembles late entries under older ticks, withholds a possibly partial last tick, and cuts the sync stream to its dense prefix.

### 2.2 Headless verification (CLI runner and monitor)

Two near-copies drive a `.reevaluation` keeper without a transport:
- `ReevaluationEngine.run` (`ReevaluationEngine.swift:200–432`), used by the example `ReevaluationRunner` executables;
- `ConcreteReevaluationRunner` (`ReevaluationRunnerImpl.swift:94–523`), stepped by `ReevaluationRunnerService` for the monitor land.

How a run goes:
- Each calls `stepTickOnce()` per recorded tick. The keeper pulls the tick's inputs from its `reevaluationSource` inside `runTick` (LK:4228–4535).
- OnInitialize is intercepted by `replayInitializeBeforeTickZero` (LK:1043–1075). Without that, the keeper's init starts `performInitialization` eagerly (LK:980, resolvers awaited at :1138).
- With no transport, the keeper's predicate `usesInTurnSync` (`mode == .live && transport?.runsSyncPhaseInTurn(of:)`, LK:667) is false, so the run takes the off-in-turn path: `processPendingActions` (LK:3739) or `replayRecordedPasses` (LK:4005).
- Sync outputs are verified by a shadow `SyncEngine`. It re-plans each recorded output from the replayed state and the record's ordered seed and clear markers (`SyncOutputVerifier.swift:249–960`, markers at :885, :918).

The monitor land reads the service's status under a lock on a 100 ms tick (`ReevaluationMonitorLand.swift:28–71`), the mailbox exception named in CLAUDE.md.

### 2.3 Replay viewing and the registrations

- **`registerWithGenericReplay`** (RF:222–308) is the production path (GameServer `main.swift:171`, :194, :225).
  - The replay land is `GenericReplayLand` (`GenericReplayLand.swift:50–133`), a live keeper of a separate definition, registered as `<type>-replay`.
  - Its services start a headless run. Each tick it pops one result, assigns the decoded state (state → `fullStateSnapshot` → JSON → `init(fromBroadcastSnapshot:)`), requests a broadcast-only sync and re-emits the recorded events typed (#632).
  - Viewers get the broadcast view only.
  - Its ticket gate is `injectingGenericReplayKeeperModeResolver`, whose accepted fallback is `.live` (RF:534–550).
- **`registerWithReevaluationSameLand`** (RF:47–118) is used only in tests.
  - It registers the live definition under `<type>-replay`, with the generic runner bootstrap and the same `.live` resolver.
  - The live definition never consumes the runner's results, so a viewer sees a fresh land while `resultsQueue` grows (`ReevaluationRunnerService.swift:301`).
- **`registerWithReevaluation`** registers a separate replay definition (RF:120–196). It is used only in tests.
  - Its gate is `injectingReplayTicketGate`, whose accepted fallback is `nil`, which means live (RF:553–569, :126–127).
  - It gives the replay land the live land's path hashes (#386).

None of the three builds a `.reevaluation` keeper. All of them build live keepers with in-turn sync.

### 2.4 Who reaches the off paths

There are two different off switches, and they need to be named apart:
- **the adapter's flag:** `inTurnSync: inTurnSync && !isReevaluationKeeper` (LM:722), set from the keeper mode `LandManager` resolved;
- **the keeper's predicate:** `usesInTurnSync` (LK:667), which needs `.live` and an attached transport that opts in.

**A `.reevaluation` keeper with an adapter** turns the adapter's flag off. Two routes build one:
- **a resolver returning `.reevaluation`,** through `LandManager.buildLand` (LM:614–669, :722). Its sources are:
  - the public `NIOLandServerConfiguration.keeperModeResolver` (`NIOLandHost.swift:220`, :242);
  - the resolver parameter of `LandManager`'s inits (LM:265, :305, :339);
  - `injectingReevaluationKeeperModeResolver` (RF:623–637), whose only caller is `ReplayTicketJoinTests.swift:244`;
  - `LandManagerReevaluationModeTests` (:137, :167, :200, :215);
- **directly:** the public `LandKeeper.init(mode: .reevaluation)` (LK:901) with an adapter. That happens in:
  - `TransportAdapterJoiningAdmissionTests.swift:227` (a replay viewer's join, `arguments: [true, false]`);
  - `TransportAdapterNewestWinsTests.swift:381` (a replay keeper takes no transport inputs);
  - `TransportAdapterRegisterSessionTests.swift:186` (reevaluation mode runs no lifecycle handlers).

**The adapter's own cycle outside replay.** The standalone initial sync, `_syncStateForNewPlayer` (TA:5584, a `runSyncPhase(isSyncCycle: false)` commit), runs with in-turn sync on, from the adapter's join and the router's non-flip branch, outside `withSyncState`. #655 rev 9's review (must-fix 8) asks for it as an L2 group.

**The keeper's off path, users today:**
- the two headless runners (`.reevaluation`, no transport);
- live keepers with no transport: `Examples/GameDemo/Sources/ReevaluationRunner/main.swift:452` (a live recording keeper), `HashCostBenchmark.swift:46`, and about 19 core test files;
- keeper-side tests that attach a fake transport to a `.reevaluation` keeper: `ReplaySequenceWatermarkTests`, `ServerInputTests`, `ShutdownTurnTests`, `TicklessReplayPassTests` and `LandKeeperReevaluationOutputModeTests`;
- until #546 L1, live keepers with `IN_TURN_SYNC=false`.

## 3. Shape

```
             ┌──────────────── input source (exactly one) ─────────────────┐
             │ live intake: transport, router, submitServerInput           │
             │ record cursor: recorded boundaries, validated, in order     │
             └──────────────────────────┬──────────────────────────────────┘
                                        │ TurnBatch (§3.1)
                                        ▼
       ┌───────────────────── LandKeeper.runTurn(batch) ─────────────────────┐
       │ synchronous: membership changes, inputs, tick handler, events,      │
       │ outcome (rejected, failure, watermarks, state hash when asked),     │
       │ sync phase only if a port is attached                               │
       └───────────┬──────────────────────────────────┬──────────────────────┘
                   │ sync phase (port)                │ TurnOutcome
                   ▼                                  ▼
          TransportAdapter (clients)        observers: recorder (live)
          or no port                                   TurnComparator (replay)
                                                       SyncOutputCheck (replay)
```

### 3.1 The input source and the record cursor

A keeper is built with an `InputSource`:
- **`.live`:** today's intake. `submitAction`, client events, joins and leaves through the router, and `submitServerInput` (#387).
- **`.record(RecordCursor)`:** the public intake is closed. Every live entry point refuses with one reason, `.replaying`. It replaces #387's `.notLive` and the mode checks at LK:2776, :2960 and :3088. The keeper doesn't start `performInitialization` (§3.3).

**The cursor yields boundaries, and each boundary is a `TurnBatch`:**

| Kind | Carries | Today's counterpart |
|---|---|---|
| `.initialize` | the recorded resolver outputs for OnInitialize, and its outputs (events, state hash) | the initialize entry and its marker (LK:561, :977, :1191–1245) |
| `.tick(id)` | the inputs in applied order, both sequence watermarks (before inputs, before the tick handler), and the recorded outcome (rejected, failure position, events, state hash) | one tick turn record |
| `.pass(tick, ordinal)` | a tickless land's inputs for one pass, its watermark, and its outcome; one tick may have several | #325's passes |
| `.syncOnly(observedTick, reason)` | no inputs; the recorded sync outputs it produced | sync-only turns (LK:633, :697, :1934–1936, :4619–4669), stream `turnKind .syncOnly` (`ReevaluationSyncStream.swift:16`) |
| `.shutdown` | the shutdown lifecycle entry | the shutdown turn (LK:5149–5250) |

**Membership inputs.** A join or a leave inside a batch carries what the keeper's `players` entry holds and handlers can read: player ID, client ID, session ID, guest flag, device ID, metadata and the resolver outputs. S2's PR pins the field list against `PlayerSession`.
- On live, `players` changes in the async join and leave paths, outside the turn (LK:1576, :1798, :2494), and `applyLifecycleItem` (LK:3635) runs only the handler.
- On replay there's no join path, so `runTurn` applies the recorded `players` change at the item's position, then runs the handler.
- Each item says which applies: `membership: .alreadyApplied | .applyInTurn`. Live keeps its split until #588 moves the join into its turn. Then both use `.applyInTurn`.

**Validation before apply.** The cursor checks each boundary before handing it out:
- tick IDs don't decrease;
- pass ordinals are consecutive within a tick;
- sequences strictly increase within and across batches;
- each watermark is at or below its batch's first sequence;
- `.initialize` comes first;
- a failure position names an input in its batch.

A violation ends the run with `recordInvalid(position, rule)`, before anything of that batch applies.

**Typed inputs.** The cursor decodes each payload once, with the land definition's registries and the codec of its kind (§5.1). A payload that doesn't decode ends the run with its tick, sequence and type (#521's rev 8 rule). For client input that's the strict decode of #606's 2026-11-18 decision.

### 3.2 Time

Game logic reads time only as `tickId`. A replay reads no clock:
- **Boundaries** come from the record (tick IDs, pass ordinals, sync-only entries), not from a clock.
- **Outcomes that depended on time** are recorded as their outcome, never re-derived: an action job's deadline, a resolver timeout, a join that timed out, a sync-lag pause (`rejected`, `landFailure`, resolver outputs, the adapter's recorded dispositions).
- **No turn instant is recorded in 4.0.** A wall-clock instant per turn would break the record's byte identity (§5.1, #327). Q6 is deferred until keeper deadlines or timers move into turns. Then the instant comes from the keeper's injected clock, stored as an offset from a land-relative origin, never as a raw `TurnInstant`: that is process-relative (`Values.swift`) and means nothing in another process. The stepped clock is set inside the serialized step, before the batch's first read. It is monotonic, and ties are allowed.
- **Viewer pacing** uses its own clock. A tick land paces by the definition's tick interval, the same definition the live land ran, as `GenericReplayLand` does today (`GenericReplayLand.swift:54`). A tickless land steps at a fixed rate the viewer sets.

A replay arms no timer and makes no holding request (turn core plan, §3.3–3.4, rule 18).

### 3.3 The keeper's turn entry point

S2 adds one synchronous entry point and routes both live and replay through it:

```swift
// Not async: a batch applies without a suspension point.
func runTurn(_ batch: TurnBatch, wants: OutcomeRequest) -> TurnOutcome
```

What it does, in order:
1. **Watermarks.** It sets the batch's sequence watermarks. On replay it checks them against the outcome counter, as #72's restore does today.
2. **Membership.** It applies `.applyInTurn` changes at their positions.
3. **Inputs.** It applies the inputs (`applyInputs`, LK:3934). A failing input fails alone, and a land failure stops the batch at its position (#535).
4. **Tick handler.** For `.tick` it runs the tick handler, unless the land failed.
5. **Outcome.** It collects the events, the rejected inputs, the failure position and the watermarks. It adds the state hash only when `wants.stateHash` is set, which a recorder or a comparator sets. Today the hash is gated on live recording.
6. **Sync phase.** It runs the phase only when a port is attached: `usesInTurnSync` becomes "a port is attached and opts in", with no mode term.
7. **Waiters.** It resolves waiters only for live inputs: `inputTurnResults` (LK:5443) is written for inputs with callers, and a replayed batch has none, so nothing accumulates. Today `replayRecordedPasses` clears it per pass.

**OnInitialize on replay.** The keeper built with `.record` doesn't start `performInitialization`. `ReplayRun`'s first step takes the cursor's `.initialize` batch and calls `runTurn(.initialize)`, which runs OnInitialize synchronously with the recorded resolver outputs. No resolver is awaited, and there's no eager start to race (today's interception, LK:1043–1075, goes).

**Live keepers with no port** (the recording runner, the benchmark, the core tests) also run `runTurn` with no sync phase. So after S2 nothing reaches the keeper's off path except `IN_TURN_SYNC=false`, which L1 removes, and the adapter's own cycle, which L2 removes.

### 3.4 The observers and the run

**`TurnOutcome` observers:**
- **The recorder** (live): today's submission (LK:4983–4996), behind a `TurnRecordSink` protocol. Typed encoding and the state hash run only when a recorder is attached (§7 cost). #275's bound and #526's levels attach here later.
- **`TurnComparator`** (replay): it compares each replayed outcome with the batch's recorded one, field by field: state hash, events (typed value, then encoded bytes), watermarks, rejected inputs, failure position. Its verdict per batch is `match`, `mismatch(field, detail)` or `notVerified(reason)`, with tick, sequence and output index. The CLI, the monitor and tests share it (#478).
- **`SyncOutputCheck`** (replay): §5.3.

**`ReplayRun`** replaces `ReevaluationEngine.run` and `ConcreteReevaluationRunner`, with their duplicated setup and their two `CapturingSink`s:
- It opens the record once (§5.1) and checks it before the first step (§5.2).
- It builds the keeper with `.record(cursor)` and attaches the observers the caller asked for, plus a port for a viewer (§5.5).
- `step()` reads the next boundary, then runs it with `runTurn` and returns the verdicts. `runToEnd()` loops it.
- One step in flight: `step()` sets its in-flight flag and checks it in one segment, before the cursor's async read. A second call while one is in flight returns `.busy`. That's a `SingleFlight` per run, the CLAUDE.md helper. Reentrancy during the read can't start a second step (#100's step race).
- It owns its keeper. The keeper is single-use and dropped at the end of the run.

## 4. What goes away

| Today | Fate | Step |
|---|---|---|
| `LandKeeperModeConfig.reevaluation`, `LandManager`'s `.reevaluation` branch (LM:626–669) and the adapter flag's `!isReevaluationKeeper` term (LM:722) | Deleted. `keeperModeResolver` stays, with `.live` and `.invalidReplaySession` only: it's the ticket gate (§6 S0) | S0 |
| `registerWithReevaluationSameLand`, `registerWithReevaluation`, `injectingReevaluationKeeperModeResolver` | Deleted (§2.3) | S0 |
| `LandMode`, `ReevaluationOutputMode` (LK:32–43) | Deleted. The input source and the observers replace them | S2 |
| The keeper's mode branches (LK:431, 585–623, 636, 668, 935–973, 1044–1119, 1583, 1805, 2499, 2631, 2776, 2960, 3088, 3614, 3753, 3971, 4213–4514, 4876, 4907, 5149–5250) | Each becomes intake closed, cursor validation, a `runTurn` step, an observer, or nothing (viewers aren't players, §5.5). S2's PR lists each site with its fate | S2 |
| `runTick`'s replay pull (LK:4228–4535) and `replayInitializeBeforeTickZero` (LK:1043–1075) | Replaced by the cursor and `runTurn` | S2 |
| The keeper's off path: `processPendingActions` (LK:3739), `replayRecordedPasses` (LK:4005), `deliverLegacyPass` (LK:3867), the legacy `runSync` loop (LK:5504), `syncNowFromTransport`, `beginSync`/`endSync` (LK:1331–1387) | Unreachable after S2 and L2; deleted | S6 |
| `ReevaluationEngine`, `ConcreteReevaluationRunner`, `CapturingSink` | Replaced by `ReplayRun` and `TurnComparator` | S2 |
| `SyncOutputReplayDriver` (the shadow's driver) | Replaced by `SyncOutputCheck`'s driver; the planner is shared with the adapter (§5.3) | S3 |
| `GenericReplayLand`, `ReevaluationReplayProjector` (the hard-coded "hero-defense" projector), `DecodeReplayState`, the replay use of `fromBroadcastSnapshot`, `registerWithGenericReplay`, `replayLandSuffix` (RF:9–18, `NIOLandServer.swift:92–100`, `LandTypeRegistry.swift:54–61`), `checkRecord(replayLandSuffix:)` (`SchemaFingerprint.swift:295–305`), `ReevaluationReplaySessionDescriptor`, `/admin/reevaluation/replay/start` | Replaced by `enableReplay` and replay sessions (§5.5) | S5 |
| The 3.x replay readers and their compatibility branches (#211, #607) | Deleted when 4.0 is the written format | S1 |

## 5. The parts in detail

### 5.1 Record format 4.0

**Why a new major:** input payloads change form, the header is written once, and the version authority changes.

**Version authority.** The preamble's `(major, minor)` is the one authority. The header carries no separate version, so the 3.5/3.6 disagreement can't recur.
- A reader refuses a different major.
- For a newer minor of 4, replay refuses (`recordNewerThanReader`), and a reader that lists records shows the record as not replayable.
- A preamble that is missing or malformed refuses the file.
- Admin maps all of these to 409 `RECORD_VERSION_MISMATCH` (#213).

**Byte identity stays.** With in-turn sync, two recordings of one input are byte-identical (#327, RL:16–17, `RecordTurnBoundaryLiveTests.swift:195`). 4.0 records no wall time, so that test and the differential harness's record goldens keep working; their bytes change once, in S1.

**One codec per payload kind.**

| Kind | Stored as | Decoded by | On failure |
|---|---|---|---|
| Client action, client event, join payload | canonical MessagePack written by the `@Payload` typed writer, positional in declaration order (#521 PR 1a), under the static wire name (#521 EV2) | the definition's registry and #606's strict typed decode | the run ends (record/code mismatch) |
| Server input (`ServerInputPayload: Codable`, #387) | canonical MessagePack of its `Codable` encoding, named keys; it stays `Codable` (#387's plan, outside #521) | `serverInputRegistry` by its type identifier, synthesized `Codable` | the run ends |
| Resolver output (`Codable & Sendable`, `ResolverOutput.swift:23`) | canonical MessagePack of its `Codable` encoding, named keys | the declared resolver's output type | the run ends |
| Server event (an output, compared) | the typed writer's bytes (#521) | decoded to check that it resolves; compared as bytes | `mismatch` |

**Canonical encoding from the typed value, not the client's wire bytes.** Wire bytes depend on the client's encoding (JSON key order, whitespace, number forms), so two recordings of one input could differ. The cost is one encode per recorded input, and it runs only on a recording land (§7).

**The header: one, before the first turn record, never replaced.**
- **Written by the keeper.** It holds what the keeper has at init: land type and land ID (fixed at init, no `setLandID` afterwards, #575), the RNG seed the keeper holds (#575), the schema fingerprint (#604), the effective-config fingerprint (§5.2, Q8), and the initial-state hash (the state before OnInitialize).
- **The port's part:** the sync config and whether the sync stream is recorded. `LandManager` attaches the port before the keeper's first turn. The recorder buffers the header until both parts are in, and the first turn record forces it out. A keeper with no port writes "no sync stream".
- **A second header** is a format violation, and the reader refuses it. Today a later header replaces the earlier one (RL:287).

**The cursor (streaming).** The reader keeps today's semantics on purpose, one by one:
- **Two streams.** Turn records and their inputs are never late: each batch is written in its turn, so the input side streams strictly in order. The sync stream is a second stream, read in `streamIndex` order through a bounded reorder buffer. A late entry for an older tick waits there until its index is next. A gap wider than the buffer's bound (a reader constant, refused above it) is a format violation.
- **Truncation.** A file without its footer ends at the last complete batch. The possibly partial last tick is withheld (today: RL:316–320). The sync stream is cut to its dense prefix. The verdicts after that point are `notVerified(.truncated)`.
- **Frame size:** each frame is bounded by a reader limit, refused above it.
- **Opening.** The path is resolved once to its real absolute form: symlinks, and a relative `REEVALUATION_RECORDS_DIR`. Containment is checked on the resolved path, and the file is opened once. The run keeps that handle (#366 items 1–3). Reads are async (#275).

### 5.2 Checks before the first step

In this order, each refusing with its own code:
1. version (at open);
2. schema fingerprint (#604);
3. effective config (#441);
4. land type registered on this host;
5. initial-state hash.

The engine no longer takes an initial state from its caller. It builds the state the way the live land did, from the same definition, and the hash check catches a custom initial state that the record didn't carry. The seed comes from the header. A record without a sync stream runs no `SyncOutputCheck`, and its sync verdicts are `notVerified(.notRecorded)`.

### 5.3 `SyncOutputCheck`: what it feeds and what it compares

**What it is.** It replaces the shadow's driver. It doesn't pose as a transport. It reads the replaying keeper's state after each batch that the record says synced, the same read today's shadow makes.

**What it compares:** the recorded drafts. That means, for each output, the broadcast hash, the per-player hashes and the event hashes, in recorded order (`SyncOutputVerifier.swift:885`, :918).

**What it feeds the planner:**
- **Membership** comes from the record's ordered seed and clear markers. These say who was in the sync set and when, which today's shadow already uses.
- **Adapter-side decisions** come from the recorded dispositions, as facts. A player the adapter withheld (sync lag, #572 option A) is listed as unverified in the output, and the check skips that player. An output that was planned but not committed (a closed gate, the writer's refusal) is recorded as not committed: its plan is checked, its delivery isn't. A resync is recorded with its cause, and the check plans that player's full snapshot at that point and compares its hash.
- **Never a recorded hash.** Inputs to the planner are membership and dispositions. A recorded fact can't verify itself.

**The planner: option (b), shared and narrower.** S3 takes the planning half of B2's routine (decision 5's `planAndCommit`: the diff per recipient, from state, the membership view and the phase scratch) into a deterministic function that both the adapter's machine and the check call. Commit, writer, lag and ceiling handling stay on the adapter.
- **What it can check:** broadcast and per-player diffs and their order, event order, seed and clear order, and the plan of a resync.
- **What it can't check:** what lag, ceilings, backpressure or the socket decided. Those are taken as recorded.
- **Rejected:** option (a), recording the phase's full inputs (recipients, sessions, lag state, joins, scratch). It grows every recorded turn on the live path to replay something the record already states as outcomes.

**#554 is closed.** It extracted the stateless encoding and frame building, not `planAndCommit`. S3 needs B2's routine (§8).

**Viewer runs.** In S5 a viewer's observer sessions aren't the recorded players. When a viewer run verifies per-player output, the check runs beside the viewer's port, on the recorded membership, never on the observers.

### 5.4 The monitor and the run service

- **Runs and tickets.** `ReevaluationRunnerService` keeps runs keyed by a run ticket (a `GenerationTable`). A new run supersedes the old one, and a stale run's results are dropped by its ticket (#100).
- **Results as server inputs.** The run reports through `submitServerInput` (#387): `RunProgress` and `TurnVerdict`, each carrying the run ticket. The monitor's handlers keep the current ticket in state and drop an input from another run. The monitor's tick no longer reads the service, so CLAUDE.md's monitor exception and #522's item go.
- **The bound.** #387's submit refuses at the in-flight cap at once (`.overCap`). The run then waits for capacity instead of queueing: it awaits `keeper.serverInputCapacity(for: RunProgress.self)`, a new additive keeper call. The keeper resumes it as a turn output when it applies an input of that type. Nothing else holds results, so `resultsQueue`'s unbounded growth goes (`ReevaluationRunnerService.swift:301`). The name and shape of that call are a point for review.
- **The match rule.** `isMatch` is the comparator's verdict, which includes events and sync outputs. `TickProcessedEvent` gets the recorded state hash as `expectedState` (`ReevaluationMonitorLand.swift:56–58`).

### 5.5 Replay viewing

A replay session is a `ReplayRun` with a real `TransportAdapter` as its port, paced in wall time (§3.2).

- **Addressing.** `POST /admin/replay/start` (record path, land type) opens and checks the record (§5.1–5.2) and creates the session. It returns a replay ticket and a WebSocket path. The ticket is HMAC-signed with the session ID inside. No record path is in the ticket, the instance ID or any client message (#366 items 4–6). The session isn't a land of a `-replay` type: a `ReplaySessions` component on the host owns it, outside `LandManager`'s type registry (§9 Q4).
- **Readiness.** The start call returns after the session's keeper has run `.initialize` and its adapter accepts sessions. A viewer that connects with the ticket can't race the creation. S5 adds a test for that, held at the point where the start returns.
- **Viewers are observers, not players.** They get an adapter session but no `PlayerID` in the land's state, and no OnJoin or OnLeave. Today's replay keeper inserts viewers as players and skips OnJoin (LK:1580–1583). Which view an observer gets is §9 Q3.
- **Pacing.** A driver task steps the run on the viewer's clock (§3.2), with a speed factor (1× by default), pause, and seek-forward. Seek-backward needs snapshots (#526) and isn't in scope.
- **Same definition.** The session's keeper is built from the registered `LandDefinition` of the recorded land type, so its path hashes, event hashes and fingerprint are the live land's.
- **Moved in S5 with it:** the admin routes; the monitor WebClient's routes; `verify-replay-record.ts` (a replay client over HTTP, not a record reader); the CLI replay E2E (`reevaluation-replay-e2e-game.ts`) and its `test-e2e-game.sh` wiring; and `docs/core/reevaluation.md` and `docs/transport/auth.md` with their zh-TW companions.

### 5.6 Recording

- **The recorder is an observer** (`TurnRecordSink`) on a live keeper. The host enables it through a host-level setting, not the state-hash flag (LK:945).
- **The sync stream** is recorded through the port as today: drafts come back in the phase's output (#553).
- **`ReevaluationRecordSaver.saveOnShutdown`** stays the land's call. #526's production stream is out of scope; the sink protocol is where it attaches.

## 6. Steps

Each step is its own PR to `main` (core paths).

**S0: the `.reevaluation` keeper behind an adapter, and the two test-only registrations.** It is independent of the rest. With Q1, it goes before #546 L2.
- **Removes:** `LandKeeperModeConfig.reevaluation`, `LandManager`'s `.reevaluation` branch (LM:626–669), the flag's `!isReevaluationKeeper` term (LM:722), `injectingReevaluationKeeperModeResolver`, `registerWithReevaluationSameLand` and `registerWithReevaluation`.
- **Keeps the gate:** `keeperModeResolver`, public, with `.live` and `.invalidReplaySession` only. Both surviving users go through `replayTicketGatedResolver` (RF:367–392): `registerWithGenericReplay` and the monitor.
- **The breaking change:** removing `.reevaluation` from the public enum, the resolver and the two registrations. There are no external users, so no deprecation (the 2026-11-18 rule). The PR lists it under "Public API".
- **The refusal until S2:** `TransportAdapter` is public, so a keeper built directly with `LandKeeper(mode: .reevaluation)` could still take an adapter. Until S2 deletes `LandMode`, the adapter refuses a non-live keeper where it binds to it: a precondition on the keeper's mode. Today `mode` is a `private var` assigned only in the init (LK:381, :916). S0 makes it a `nonisolated let` that the adapter can read. Keeper-side fake transports aren't adapters, and they keep working until S2 converts their tests.
- **Tests:**
  - `LandManagerReevaluationModeTests`: deleted. It tests the removed branch.
  - `ReplayTicketJoinTests`: deleted. Its ticket cases move to the generic path in `MonitorTicketTests`. The #428 flake goes with it.
  - `ReevaluationFeatureRegistrationTests`: its arms for the removed APIs go, and the generic ones stay.
  - `TransportAdapterJoiningAdmissionTests.swift:227`, `TransportAdapterNewestWinsTests.swift:381` and `TransportAdapterRegisterSessionTests.swift:186`: the reevaluation arms are deleted. They test a viewer as a player on a reevaluation keeper, which S5's observer tests replace, and replay intake, which S2's `.replaying` refusal test replaces.
  - `EventNameHostRegistrationTests.swift:193`/`:199` and `RecordSchemaFingerprintRegistrationTests.swift:94`/`:103`/`:154`: the removed arms go and the `registerWithGenericReplay` arms stay, so #521 D15's registration check stays covered.
- **Docs:** CLAUDE.md (:55, :100: the reevaluation flow), `docs/core/reevaluation.md` and its zh-TW companion.
- **Kept until S5:** `/admin/reevaluation/replay/start` and the suffix, which the generic viewer uses.
- **What it gives #546:** no adapter is ever bound to a `.reevaluation` keeper. So L2's group 5 needs no replay-only cycle: #655 rev 9's choice (b) in B2 goes, and #655 records that. L2 still has the standalone initial sync (`_syncStateForNewPlayer`, §2.4) as its own group. That's an L2 item, not replay.

**S1: format 4.0, writer and reader, with today's runners ported.**
- The writer writes 4.0 (§5.1): typed inputs by codec kind, one header from the keeper, the preamble as the version.
- The streaming cursor reads 4.0. It also serves today's source interface (the one `runTick` pulls from), so `ReevaluationEngine`, `ConcreteReevaluationRunner` and `GenericReplayLand`'s run keep replaying fresh records until S2 and S5 replace them. The game E2E's separate-process `--verify` (`reevaluation-e2e-game.ts:96–97`) runs on 4.0 from this step on.
- The 3.x replay readers and their branches are deleted (#211, #213, #607).
- It also covers #575 and the header part of #441.

**S2: the turn entry point, the cursor's batches and `ReplayRun`** (§3.1, §3.3, §3.4).
- `runTurn` takes live and replay alike. `InputSource` comes in, and `LandMode` and `ReevaluationOutputMode` are deleted, with each mode branch's fate listed.
- The CLI runner and the monitor's runner move to `ReplayRun` and `TurnComparator`. The keeper-side tests that used `.reevaluation` with fake transports are converted.
- After S2 the keeper's off path has no caller except `IN_TURN_SYNC=false` (gone with L1) and the adapter's cycle (gone with L2).
- It covers #324, #342 and #478.

**S3: `SyncOutputCheck` on the shared planner** (§5.3). It needs S2 (`ReplayRun` drives it) and B2 (the planner's source). It deletes `SyncOutputReplayDriver`.

**S4: the run service and the monitor** (§5.4). It needs S2 and #387 PR 2, or does that migration itself. It covers #100 and #522's monitor item.

**S5: replay viewing** (§5.5). It needs S2, S3, and #546 B3, since B3 moves membership and observer sessions are new membership. It deletes `GenericReplayLand`, the projector, `registerWithGenericReplay` and every suffix site, and moves the clients and docs listed in §5.5. It covers #366 items 4–6.

**S6: the deletion.** It needs S2 and #546 L2, not S3–S5: after S2 the replaying keepers no longer use the off path. It deletes the keeper's off path, `beginSync`/`endSync`, `syncNowFromTransport` and the remaining `IN_TURN_SYNC` code, and the #655 decisions that guard the legacy cycle (decisions 1 and 4, already superseded by L2). That is #550's outcome and #522's "legacy tick path" item.

## 7. Verification

**Determinism, before and after S1/S2.** The scenarios are those under `Tools/CLI/scenarios/game/`, a tickless land with several passes under one tick and a sync-only phase between them, and the Demo counter land. The gate:
- recording with S1 and verifying with the ported runner, then with S2's `ReplayRun`, gives the same verdicts turn for turn;
- every verdict is `match` where the record has the field, and `notVerified` where it doesn't (no sync stream, no state hash);
- the live client frames are compared by the differential harness's goldens (#555). The record bytes are compared on their own: their goldens change once in S1 and are deterministic (no wall time), and `RecordTurnBoundaryLiveTests`' byte identity holds.

**Mutants.** Each of these must fail with its own verdict:
- a replayed input applied in another order, and a dropped recorded input;
- a wrong seed, a changed config value, a stale fingerprint, and an initial-state hash that doesn't match;
- a pass ordinal skipped, and a watermark above its batch;
- a second header, and a preamble that disagrees.

A recorded client payload with an extra field must fail the run (#606 strict).

**Interleavings by holds, not time:**
- a second `step()` during the cursor's read (`.busy`);
- a run superseded during a step;
- a viewer that connects before readiness;
- the monitor at its cap, resumed by capacity.

**Separate-process verify (#51).** The game E2E's `--verify` runs in a new process (`reevaluation-e2e-game.ts:96–97`) in the `e2e-game-tests` job. Check against #51's acceptance criterion that the job runs on every PR that touches replay (`e2e-tests.yml` ignores Markdown, `docs/` and `Notes/` only), then close #51. S2 adds a tickless land to that run.

**Cost, each tier on its own:**
- **S1:** `makeTurnRecord` runs on every tick turn (LK:4763), so typed encoding and the state hash are gated on a recorder being attached. S1 measures release builds with recording off and with it on, base against change: ServerLoadTest (`config.record`) and EncodingBenchmark (`records`). ws-loadtest runs with `ENABLE_REEVALUATION=false` (`run-ws-loadtest.sh:376`).
- **S2:** `runTurn` reroutes the live tick and input turns, so S2 takes the off-path gate (#517's windowed instructions) on the live profiles.
- **S5:** observer sessions are new membership on the sync-planning hot path, so S5 takes #517's gate and a host A/B tier of its own.
- **S3:** the planner extraction touches the adapter's commit, so S3 is checked against B2's goldens and gate.

**E2E:** `test-e2e-game.sh` and the Demo reevaluation E2E, in all three encodings, from S1 on.

## 8. Order relative to #521, #606 and #546

| Step | Needs | Notes |
|---|---|---|
| S0 | nothing | before #546 L2 if Q1 is yes |
| S1 | #521's remaining PRs (the typed writer for every payload kind, EV2's static names), #606 (the strict typed decode) | independent of #546 |
| S2 | S1, #546 L1 (no `IN_TURN_SYNC=false`) | `runTurn` replaces the live turn functions' entry, so it's planned against the keeper code of that time |
| S3 | S2, #546 B2 (decision 5's routine, to share its planning half) | #554 is already merged |
| S4 | S2, #387 PR 2 (or it does that migration) | |
| S5 | S2, S3, #546 B3 (membership moved) | |
| S6 | S2, #546 L2 | |

The sequence: S0 → #546 L1 → S1 (once #521 and #606 land) → S2 → L2 → S6. In parallel: B2 → S3, B3 → S5, and S4 after S2.

## 9. Questions for the maintainer

- **Q1: S0 early.** Remove `.reevaluation` from the public keeper mode config and resolver, and the two test-only registrations, before L2. Then no adapter is ever bound to a `.reevaluation` keeper, and #655 drops its replay-only cycle option. *Recommended: yes.*
- **Q2: 3.x records for readers that don't replay.** The admin record list (#493) and the runner's `--convert`. (`verify-replay-record.ts` replays, so it moves with S5.) *Recommended:* the list reads the preamble and shows 3.x as "not replayable"; the converter goes, and #343 closes as obsolete.
- **Q3: what a viewer sees.** Broadcast only, as today, or also a recorded player's view through the real adapter. *Recommended:* broadcast by default, and a player's view only when the replay ticket names that player (admin chooses at start).
- **Q4: how a viewer's WebSocket reaches the session.**
  - (a) A replay path served by `ReplaySessions`. It uses the adapter's join for observer sessions and never enters `LandManager`/`LandRealm`.
  - (b) An instance of the recorded land type with an ID the session mints. That puts replay sessions back in land listings and on the router's create path.

  *Recommended: (a).*
- **Q5: the keeper's own move onto `TurnCore`.** No issue tracks it. This plan designs on the keeper's synchronous turns, and its seams are the same whether or not the keeper adopts `TurnCore` later. *Recommended:* don't wait for it. File it as its own issue if it's wanted.
- **Q6: the turn instant (deferred).** It isn't recorded in 4.0 (§3.2). It's added when keeper timers or deadlines move into turns, from the keeper's injected clock, land-relative. *Recommended: defer, as written.*
- **Q7: names.** *Recommended:* "replay" for the public surface (`ReplayRun`, `enableReplay`, `/admin/replay/*`) and "record" for the format. The `Reevaluation*` names go with the types they name, listed per PR as breaking changes.
- **Q8: #441's config fingerprint, declared or inferred.** Either lands and services declare their replay-relevant values (explicit and reviewable), or the host hashes every environment key a land reads (automatic but noisy). *Recommended: declared.* A value that changes behaviour without being declared is the land's bug, and the docs say so.
- **Q9: #526 stays out** (production stream, levels, snapshots). The seams stay: `TurnRecordSink` and `RecordCursor`. *Recommended: out.*

## 10. Issues against this design

| Issue | Outcome |
|---|---|
| #550 | Answered: replaying keepers use `runTurn` from S2, and the off path is deleted in S6. Close #550 when this plan is GO, pointing here |
| #211, #213, #607 | S1 (the 3.x replay readers go; one version authority) |
| #538 | Already closed (#590, #632) |
| #366 | Items 1–3 in S1 (resolved path, one open); 4–6 in S5 |
| #100 | S2 (one step in flight) and S4 (run tickets) |
| #575 | S1 (header from the keeper at init) |
| #343 | Obsolete if Q2 drops the converter; otherwise stays |
| #275 | Partly S1 (async reads); the writer's bound stays with #526 |
| #324, #342 | S2 |
| #572 | Stays open as the adapter fix (option A). S3's contract covers withheld players, planned-but-not-committed output and resyncs (§5.3) |
| #386 | S0 (`registerWithReevaluation` goes) |
| #441 | S1 (header) and §5.2 (check); Q8 |
| #493 | Stays open; S1's preamble makes it a small change |
| #478 | S2 (typed verdicts) |
| #428 | S0 (its test goes); S5 adds a readiness test for the new start |
| #51 | Provisional: close once the check in §7 holds; S2 adds a tickless land |
| #526 | Out of scope (Q9); the seams stay |
| #387 PR 2 | S4 uses it, or does the migration itself |
| #522 (monitor, legacy tick path) | S4 and S6 |

## 11. Risks

- **Replay treats live decisions as recorded facts.** Intake, deadlines, router admission and the adapter's lag and ceiling decide things that replay doesn't re-derive. If a live decision isn't recorded, replay can't reproduce it. Mitigation: every decision that changes state or output is a recorded outcome, and S2's and S3's mutants cover each one.
- **S2 reroutes the live turn.** `runTurn` becomes the entry for the live tick and input turns. It's planned against the keeper code at S2's time, with the differential goldens and #517's gate as its checks.
- **S1 changes what every recording land writes.** DemoServer always records (`Examples/Demo/Sources/DemoServer/main.swift:94`). GameServer records when `ENABLE_REEVALUATION=true`, which the game E2E sets. S1's cost check and the E2E cover that.
- **Observer sessions are new adapter surface.** S5 comes after B3, so it's built on the rewritten membership, not added to the old adapter.

## 12. Rev 2: what changed

| Review point | Change | Where |
|---|---|---|
| MF1: S0's paths | The registrations build live keepers. S0 removes what builds a `.reevaluation` keeper with an adapter (the mode config case, `LandManager`'s branch, the flag, the injector), keeps the resolver as a ticket gate, refuses a non-live keeper in the adapter until S2, and converts the named tests | §2.3, §2.4, §6 S0, Q1 |
| MF2: other off-path users | Listed: the standalone initial sync (an L2 group), transport-less live keepers, keeper-side tests with fake transports. Each is assigned to the step that removes it; #655 drops its replay-only cycle option | §2.4, §3.3, §6 S0/S2/S6 |
| MF3: a portless entry | `runTurn(batch, wants:)`, synchronous, with no transport needed: watermarks, membership, inputs, tick handler, outcome, sync only with a port, waiter cleanup | §3.3 |
| MF4: boundary kinds | `.initialize`, `.tick`, `.pass`, `.syncOnly`, `.shutdown`, with what each carries; membership applied in the turn on replay; OnInitialize without the eager start; validation and its error | §3.1, §3.3 |
| MF5: the check's inputs | Option (b): the planning half of B2's routine, shared. Membership from markers, dispositions as facts, drafts compared; #554 noted as closed; viewer runs check on recorded membership | §5.3 |
| MF6: intermediate merges | S1 ports today's runners to the 4.0 cursor through today's source interface; the off path is unreachable after S2, so S6 needs S2 and L2 only; S3 needs S2 and B2; S5 needs B3 | §6, §8 |
| MF7: 4.0 contracts | Preamble as the version authority; newer minor refused for replay; a codec table per payload kind; canonical MessagePack from the typed value; one header with the keeper's and the port's parts; the initial-state hash; two streams with a bounded reorder buffer; truncation; frame bound | §5.1, §5.2 |
| MF8: the turn instant | Not recorded in 4.0, so #327's byte identity stays; Q6 deferred, land-relative when it comes | §3.2, §5.1, Q6 |
| Should 1: S0's list | CLAUDE.md, the registration test arms kept on the generic path, the replay start route and suffix kept until S5 | §6 S0 |
| Should 2: §10 | #554 closed; #386 and #428 move to S0; #572's contract; #51 provisional | §5.3, §10 |
| Should 3: clock and steps | The stepped clock's rule (for later); one step in flight with `SingleFlight`; capacity-based resume and per-ticket drop for the monitor | §3.2, §3.4, §5.4 |
| Should 4: tests and cost apart | Client frames and record bytes compared apart; `notVerified` expected; the recorder gate on `makeTurnRecord`'s added work; S2's and S5's #517 gates, and S5's A/B | §7 |
| Should 5: what moves with S5 | `verify-replay-record.ts`, the monitor WebClient, the CLI replay E2E and its wiring, and two docs pages with their zh-TW | §5.5, Q2 |
| Nit 1 | The adapter's flag and the keeper's predicate named apart | §2.4 |
| Nit 2 | Moot: no instant in 4.0 | §3.2 |
