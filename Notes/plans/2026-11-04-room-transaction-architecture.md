# RoomTransaction: internal target architecture for a room turn

Status: design, revision 3 (final, 2026-11-04), after adversarial check; boundary primitives section added 2026-11-05 (one review pass, all findings accepted); cross-room scheduling section added 2026-11-05. Internal architecture only; the Land DSL and public API stay as they are (deprecations where an entry point changes meaning). It defines the shape that the remaining sync work converges on; each change is its own PR and conforms to this document.

## Problem

Users of the Land DSL already write code in a phase-separated shape: Resolvers do async I/O before the handler, handlers mutate state synchronously, events are outputs. The runtime does not follow the same rule internally. The sync pipeline is hand-written async code that reads state, event queues and membership on both sides of `await`s, and the join path takes its own snapshot outside the sync protocol. Every recent sync bug (#68, #70, #77, #60, #84, #69) is a read on one side of an `await` and an action on the other. Each fix so far added a local mechanism (marks, offsets, follow-ups, watermarks). Two further bugs on main come from the same shape at the input side: a throwing handler leaves its batch half-applied and re-runs it (#87), and tickless action responses can reach the wrong caller (#88). This document fixes the target shape once, so later changes remove mechanisms instead of adding them.

## The shape

A room turn is a serial, input-captured transaction with an outbox:

```
input boundary (async)        core (synchronous, deterministic)                     output boundary (async)
decode, resolvers,      →  apply inputs → tick → sync.plan → sync.commit   →  writer (network),
join/leave requests        (one keeper turn, no suspension point)              recorder (ordered enqueue)
captured as values
```

Turn kinds: **input** (apply captured inputs), **tick** (inputs + tick handler), **sync-only** (no apply or tick; used by the settle cycle and the projection). Any turn may include the sync phase. Join inputs are applied only in a turn that includes the sync phase: on lands with periodic sync they wait for the next periodic sync turn, which applies all joins captured since the last one; on tickless lands the next drain includes the sync phase.

Sketch (internal, names provisional):

```swift
struct CapturedInputs {           // values only; captured before the turn, sequence-ordered
    var actions: [ResolvedAction]         // decoded and typed; resolver outputs attached
    var clientEvents: [ClientEventInput]
    var membership: [MembershipInput]     // join(session, auth, generation) / leave / disconnect
}

struct Outbox {                   // values only; delivered after commit
    var frames: [SessionFrame]            // state frames, events, join accept/deny, action responses and errors
    var records: [RecordEntry]            // recorder entries, in turn order
}

// The keeper is the runner. One turn:
//   1. take CapturedInputs (everything captured when the turn starts)
//   2. for each input in sequence order, on a savepoint:
//        join   → canJoin on the current state → players insert → OnJoin; outbox: accept/deny
//        leave  → OnLeave → players remove
//        action → handler; outbox: response (addressed by input sequence) or error
//        event  → handler
//      a throw rolls back that input only (see rule 5)
//   3. tick, if this is a tick turn
//   4. if this is a sync turn: plan = sync.plan(state, membership, eventQueue)   // read-only on game state
//                              outbox += sync.commit(plan)   // caches, event-queue removal, frames,
//                                                            // firstSync for joins applied this turn,
//                                                            // dirty-flag clear
//   5. enqueue the outbox synchronously: frames to the writer (#86), records to the recorder queue
```

## Rules

1. **No suspension point in the core.** Steps 2–4 are non-async functions that take their inputs as parameters, so `await` cannot appear in them (compiler-enforced). The sync entry is reached via `assumeIsolated` on the shared executor, which is a runtime check of the executor only; it says nothing about what the function reads.
2. **Inputs are captured before the turn.** Decode (including today's AnyCodable → JSON → typed re-decode), resolver results and join/leave requests are values in `CapturedInputs`. Decode errors are answered at the boundary and never enter the turn. No step reads a live source (transport, clock, another actor).
3. **Each phase declares what it reads and writes.** Apply and tick read and write game state and keeper membership. Sync reads game state, membership and the event queue; writes only its caches, the event queue and the outbox. Handlers never see sync caches.
4. **Outputs leave only through the outbox,** after commit, in phase order: action responses, errors and join decisions are outbox entries addressed per input, so a caller gets the response of its own input (fixes #88). The recorder handoff is a synchronous ordered enqueue like the writer; freeze and teardown wait for both drains, each with its own timeout (the recorder drain may do file I/O in `flushIfNeeded`), like `OutboundWriter.finish`.
5. **Failure is per input.**
   - Scope: a savepoint covers `state`, the events and sync requests that input emitted into the output collector, and the keeper `players` change of a join or leave input.
   - A thrown input keeps its sequence number, is removed from the queue, and is recorded with outcome `threw`, so replay reproduces the throw and the numbering. The other inputs are applied exactly once (fixes #87).
   - Response: a tickless caller receives the error; on tick lands the caller already received an ACK, so the error goes into the outbox.
   - Cost: copy-on-write is per storage level; the first write into a large collection copies that collection once per input. Measure in the spike against an undo log or copy-on-first-write; do not assume it is cheap.
   - A throwing sync plan commits nothing: caches unchanged, events kept, dirty flags kept; the next broadcast diff uses the `.empty` baseline with a per-player firstSync reset (ordered-writer plan B2'). Clearing dirty flags is part of commit, never a separate step. Before layer 3 (PR 2) the copy is taken on the keeper, so the clear stays in the beginSync turn and commit owns only the decision; a throwing plan then forces `.all` extraction against the `.empty` baseline, so nothing the cleared flags covered is lost. Restoring flags would need a per-field mark-dirty API, which does not exist.

### Enforcement

- Compiler: non-async core functions (rule 1).
- Structure: the core lives in types with no stored reference to the transport, recorder, clock or another actor; phases have shapes like `(borrowing State, MembershipView, EventQueueView, inout SyncCaches) -> OutboxPart`, handlers keep `(inout State, LandContext)`. The strongest form is a module boundary: core types in `SwiftStateTree`, which cannot import Transport. `LandContext` has no async or `Task` escape today.
- CI: a grep over the core files for `ContinuousClock.now`, `Date()`, `Task {`.
- Review only: reading a clock or a `nonisolated(unsafe)` global inside a synchronous function, lock-based escapes.

## Membership

Three layers exist; only the first two move into the turn.
- **Keeper membership** (`players`, canJoin, OnJoin/OnLeave): a join is a captured input `join(session, auth, generation)`. Inside the turn it runs canJoin against the current state, inserts the player, runs OnJoin (first session only, as today), and puts the accept/deny into the outbox. The sync phase of the same turn produces the joiner's firstSync. So "join response before firstSync" and "firstSync includes OnJoin's effects" hold by construction, and two joins in one turn are checked against state that already contains the first. The router awaits the turn's result instead of `keeper.join`'s return value.
- **Latency bound:** join response and firstSync arrive within one sync interval on periodic lands (hero-defense: 100 ms), at the next drain on tickless lands. Today the join response is immediate (but sent before OnJoin's effects are in state). Joins add no extra sync cycles, so join storms do not multiply cycles. Measure join request → join response and → firstSync p95 in the load test before and after.
- **Reconnection:** an existing player joining again keeps today's behaviour (`isReconnection`: replace the clientID, no OnJoin).
- **Deny:** a denied join changes nothing in `players` or adapter membership; it is recorded with its decision.
- **Failure paths of a pending join** (captured, not yet applied):
  - the connection disconnects: the join input is cancelled (removed from capture, recorded as cancelled); no leave input follows, since the player never joined;
  - the router's handshake timeout fires: same as a disconnect;
  - the land is destroyed: pending joins complete with `cancelled`;
  - the land is frozen: capture is held, so the join waits; the router's join timeout must exceed the freeze auto-resume timeout, or the join is cancelled and the client retries.
- **Adapter membership** (sessions, generations, initial-sync state): updated in the same turn, keyed by `SessionID`.
- **Router handshake** (`sessionHandshakePhase`, `sessionToBoundLandID`, accept-time generation): per connection, stays outside the turn. Disconnect and leave are inputs; transport-side teardown stays outside.

## Composability

- **Phases stack.** New phases (physics, AI, metrics) are inserted at a fixed position, each obeying rules 1–4 and declaring reads and writes.
- **Inputs fold.** A turn applies its inputs in keeper sequence order; replay applies the same sequence.
- **Savepoints are per input** (rule 5).
- **Rooms do not compose atomically.** Cross-room interaction goes through messages: one room's outbox produces a message that becomes another room's captured input in a later turn (saga style). This keeps room-level parallelism.
- **Tickless lands:** one turn per drain of whatever is captured when the turn starts; no timer window. It batches naturally under load and adds no latency when idle.

## End state of the sync phase (before → after)

**Before (V1).** Sync runs on the adapter side across several `await`s:
```
sync loop (adapter)
  → await keeper.beginSync()     copy state, clear dirty flags
  → diff                         (the keeper keeps running ticks and actions meanwhile)
  → await keeper, one hop per event
  → await transport.send(...)    per send
  → await keeper.endSync()
joiners: a separate await keeper.currentState() → firstSync, outside the cycle
```
Every `await` is a gap. The sync bugs came from these gaps: dirty flags cleared early (#68), events lost or sent twice (#77, #82), lost updates for joiners (#69), and frame reordering (#86).

**After (layer 3 + #69 + boundary primitives).** Sync is a synchronous phase inside the turn:
```
            ┌───────────── one turn (keeper executor, no await) ──────────────┐
 inputs ──► │ apply inputs (per-input savepoint)                                │
            │ handler / tick                                                    │
            │ collect events                                                    │
            │ sync phase                                                        │
            │   plan:   diff against staged caches (broadcast + per player;     │
            │           joiner firstSync in the same turn; a field that fails   │
            │           to encode is dropped and recorded)                      │
            │   commit: write caches, clear dirty flags, consume event queue    │
            │   outbox: enqueue frames to the ordered writer (sync, in order)   │
            └───────────────────────────────────────────────────────────────────┘
 after the turn: recorder submits one TickRecord; the writer delivers asynchronously
```

| Turn kind | Trigger | Content |
|---|---|---|
| Tick turn | tick loop | tick; sync if a handler requested it or a coincident sync folded in |
| Sync-only turn | sync loop, at its own interval | sync only; cadence unchanged |
| Input turn | tickless lands, one per drain of captured inputs | apply inputs, then sync if requested |

Rules carried with it:
- **Coincident fold:** a sync whose next tick deadline is within `min(5 ms, tick/4, sync/4)` folds into that tick turn, so it never overtakes the tick.
- **Back-pressure:** skip the cycle while the writer holds an earlier state element; dirty flags, events and due are kept.
- **Failure:** staged commit; plan failure leaves caches untouched; tickless lands schedule a bounded repair turn.
- **Kill switch:** the legacy path for one release, as a real rollback.

At the boundary: per-session serial inbound queue + epoch check (input side); ordered writer with back-pressure and connection generation (output side); lifecycle state + SingleFlight (the room itself).

Removed: `beginSync` / `endSync` / `isSyncing`, per-event hops, the recovery plan, `initialSyncingPlayers` / `lateJoinSnapshot`, the cross-cycle bookkeeping of #77 / #82, the polling drain.

Cost (spike, macOS, release): tick-turn and sync-only-turn p99 equal to or below main; update cadence unchanged; 50-player json room within budget; capacity unchanged; savepoints ≈ 0.

**What V1's awaits actually bought.** Head-of-line blocking, total throughput and the transport ceiling are the same in both designs. The one real gain was that a large room's diff/encode overlapped its tick on another core. V1 paid for it with copy-on-write copies of every container that was mutated while a sync held the state value (the state is passed by value; in-turn sync has no mutation during the sync, so it triggers none), and with the correctness gaps above. The copy volume is being measured. Spike, 50-player json room, tick-interval p99: V1 59.4 ms; in-turn without the coincident fold 65.6 ms; with the fold 54.7 ms (n=1).

**Same correctness on the await design: what it would take.** It is possible in principle. In practice it means re-implementing database concurrency control on top of `await`s. Each gap needs its own mechanism, and this project designed most of them before choosing the turn:

| Gap | Mechanism on the await design | Where it showed up |
|---|---|---|
| state changes during sync | snapshot (CoW copies of mutated containers) | V1 |
| dirty flags cleared early | per-field versions; clear only versions ≤ snapshot | #68 |
| events lost or duplicated | per-event sequence numbers; per-session watermark compared on every delivery | #77, #82, #69 rev 3 (`r`/`w` bounds) |
| joins miss updates | pending joiners; W1/W2 window handling | #69 rev 3 |
| plan failure | a recovery plan | PR 2 (eight review rounds, then removed) |
| frame order | ordered writer | #86 (needed by both designs) |
| state changed after every await | an epoch check at each one | the 2026-11-05 audit |

| | Await design + mechanisms | Turn design |
|---|---|---|
| Correctness comes from | analysing and patching each interleaving | the structure: no suspension inside a turn |
| Runtime overhead | CoW copies, per-write versions, per-delivery watermark checks | ≈ none |
| Complexity | every new feature re-examines all interleavings | a new phase obeys "no await" |
| Tests | enumerate interleavings | the turn is deterministic; test the boundary |
| Sync output replayable | no: order depends on task scheduling | yes, given the comparator |
| Large-room encode overlap | yes | recovered by encoding outside the turn |

This is the classic database choice between concurrency control (locking/latching/MVCC) and partitioned serial execution, the H-Store/VoltDB argument: much of a conventional engine's time goes to concurrency bookkeeping, and single-threaded execution per partition removes it. SST makes the same choice: parallelism comes from many rooms, and each room runs its turns serially to completion.

**Optional large-room mitigation: encode outside the turn.** The plan yields immutable patch values, and encoding them to bytes is a pure function. Run the encoding off the turn on another core, then hand the bytes to the writer in outbox order. What is sent, and in what order, is still decided in the turn, so correctness is unchanged. Not needed now (normal sync-only turn p99 ≈ 2 ms; json50 passes with the fold). Build it only if rooms larger than 50 players, or json rooms, exceed the budget.

In one line: sync goes from **a flow across `await`s** to **a synchronous function inside the turn**. Inputs are captured before the turn and outputs leave only through the outbox; that is also the precondition for replaying sync output.

## Boundary primitives (outside the turn)

The turn is safe because nothing suspends inside it. Everything around it, in `LandManager`, `LandRouter`, `TransportAdapter`, the transports and the host, is ordinary async actor code. There every `await` lets other calls run, and a decision taken before it can be stale after it (check → await → act; the 2026-11-05 audit, #96–#102). Three small primitives carry the same principle to the boundary: **state is decided and mutated in synchronous segments; anything that crossed an `await` is validated before it enters one.**

```
 [ lifecycle state + SingleFlight ] ── creates / drains / destroys ──► the room
                                       (not a gate on inputs)

 inputs ──► [ serial queue ] ──► [ epoch check ] ──► ┌───────────────────┐
 (actions, joins,                  (still valid      │  RoomTransaction  │──► outbox
  leaves, events)                   after await?)    │  sync turn,       │
                                                     │  no await inside  │
                                                     └───────────────────┘
```

| Primitive | Role relative to the turn | Used for |
|---|---|---|
| **Serial queue per key** | The ordering the turns rely on. An actor serializes *segments*, not operations: the turn is safe because it has no awaits, while an operation that suspends (join, leave) is ordered only by an explicit queue. Actor isolation alone does not order join/leave, which is exactly this bug class. | The adapter's membership queue (exists); per-session inbound ordering (#99); join/leave ordering |
| **Epoch / generation** | Not needed inside a turn (rule 1: no suspension, so nothing can change underneath). It is the **validity check at every act that follows an `await`**: admission to a turn (join), egress (frames stamped with the connection generation, `closeSession(expectedGeneration:)`), and boundary-state writes (adapter caches, the manager's map, service state). | Connection generation (#86), membership generation for initial sync (#98, #92), session epoch for joins (#97), container identity on removal (#96), the runner's run epoch (#100) |
| **Lifecycle state + SingleFlight per key** | The **lifecycle of the room itself**, before the first turn and after the last. A synchronous state (`starting` / `running` / `draining`) decides what may enter; SingleFlight makes create and teardown run once. SingleFlight alone does not stop a join from entering a draining keeper. | `getOrCreateLand` and drain/destroy (#96), host/server/transport start and stop (#101) |

Rules:
- **Lifecycle:** state changes are synchronous; a draining container is treated as absent, and a create for a key whose container is draining **waits for that drain flight first**, so the old keeper's finalize (`onShutdown`, persistence) never overlaps the new keeper's initialize for the same LandID. Identity removal prevents the map ABA, not this overlap.
- **SingleFlight:** the flight runs in its own task; a caller's cancellation only stops that caller's wait; only the owner cancels a flight; failure removes the entry and reaches every waiter (no negative caching); success publishes into the owner's map and removes the in-flight entry in one synchronous segment; a flight never awaits its own key.
- **Epoch:** capture it before the `await` and compare it in the same synchronous segment as the act; on a mismatch, do nothing or compensate (for example, roll back a join whose session ended). Compensation is ordered too: it runs inside the same queued operation, not from a new Task. Never remove keyed state by key alone from a callback that can outlive its instance.
- **Serial queue:** order-sensitive work for one key goes through one queue, not independent Tasks; different keys stay concurrent. Disconnect goes through the same queue, after the key's last input. Validation runs **inside** the queued operation, not before enqueue (checks done before the queue go stale: duplicate login, "already joined"). An operation never awaits work that enqueues on its own key (self-deadlock), and a slow operation blocks its key (head-of-line), so keeper calls made from inside the queue are bounded by a timeout.
- **Tests** force the interleaving with a hold at the `await` (a test gate), never by timing.
- Rule 2 (inputs captured before the turn) is the link: all awaits happen outside the turn, and these primitives govern how their results are handed in.

Layers of defence, strongest first: fewer awaits in actors (move work into the synchronous core); APIs that make the wrong shape unwritable (`getOrCreate` only, synchronous state transitions, identity-only removal); test gates; a syntax-based CI check that flags check → await → write on the same stored property (warning only; separate issue; it sees one actor's properties, so cross-actor cases such as a check in `LandRouter` with the act in `TransportAdapter` stay with tests and review); the convention in CLAUDE.md / AGENTS.md (added on main, c018b2f).

## Cross-room scheduling (deterministic staggering)

The boundary primitives keep each room correct across `await`s. This one keeps rooms from interfering in **time**. Many independent rooms with the same interval, started together, fire together: the executor pool saturates in a burst and then idles (thundering herd). That was the root cause of #86's 300-room RTT regression: sync start times bunched in the first part of the 100 ms window.

Pattern (#89): each periodic loop starts at a per-key phase offset, `offset = stableHash(landID) mod min(interval, cap)`, cap 100 ms.
- **Deterministic, not random.** The same LandID always gets the same offset, so runs, tests and replays reproduce. The offset shifts wall-clock start only, never tick numbers, so replay hashes are unaffected.
- **Stable hash** (FNV-1a), not Swift's `Hasher`, whose seed changes per process.
- **Bounded:** at most one interval of extra first-tick delay; an env switch turns it off for tests that need aligned timing.
- Random jitter is the right choice only where reproducibility doesn't matter and the parties can't coordinate, for example client reconnect backoff after a server restart.

Rule: any periodic work multiplied across many keys (rooms, sessions, servers) gets a per-key stable offset, or a documented reason why alignment is harmless. Retries and reconnects multiplied across clients get randomized backoff.

**The load generator is part of the system under test.** Client cadence gets a per-client phase or jitter and a connect ramp. RTT is measured from the intended send time (no coordinated omission). The report states the actual land/player layout (#105–#107). Limits: for periods over 100 ms, lands created together still bunch into one 100 ms slice (by design). Tick and sync use the same hash, so a land's own two loops are correlated; #89 spreads lands, not a land's loops. Follow-ups: ping first-offset and a real pong deadline (#108), the destroy delay and `.reevaluation` loops (#110), and provisioning backoff (#111).

## Pattern catalog

One line per pattern: where SST uses it, the gap, and what to build it from (built-in, dependency, or own code in `Sources/SwiftStateTree/Support/`).

| Pattern | In SST | Gap | Build from |
|---|---|---|---|
| Synchronous turn + outbox | RoomTransaction (this document) | layer 3 in progress | own |
| Staged commit (plan, then commit) | #91 `StagedCaches` | — | own |
| Bulkhead (a bad input/field doesn't sink the room) | #91 drop-and-commit per field | thrown inputs (#87) | own |
| Conflation (state keeps only the latest; events never dropped) | #86 back-pressure skip, dirty flags kept | — | `AsyncStream(bufferingPolicy: .bufferingNewest(1))` where it fits |
| Bounded queue with an explicit overflow policy | #86 writer | per-session outbound `AsyncStream` in `WebSocketTransport` is unbounded; inbound and membership queues unbounded | `AsyncStream` buffering policy; NIO `NIOAsyncWriter` / `WriteBufferWaterMark` |
| Serial queue per key | adapter membership queue | per-session inbound (#99) | own (`AsyncStream` + consumer task, or a task chain) |
| SingleFlight per key | `LandKeeper.ensureInitialized` | land create/destroy (#96), host lifecycle (#101) | own (~50 lines) |
| Lifecycle state machine | — | host/server/transport (#101), land draining (#96) | evaluate swift-service-lifecycle (`ServiceGroup`) for the host; own enum for lands |
| Epoch / generation | connection generation (#86) | #96–#100 | own |
| Deadline on cross-boundary awaits | CLI join timeout | router → keeper, membership-queue → keeper calls | own (task-group race helper) |
| Idempotency key | — | client retries re-apply actions/joins | own |
| Record nondeterministic decisions | resolver outputs | canJoin, disconnect vs leave (#69) | own |
| Watermark (sequence boundary) | event sequence | — | own |
| Deterministic staggering / random backoff | #89 | timer audit pending; SDK reconnect | own |
| Kill switch with one source of truth | — | layer 3 PR A | own |
| Measurement tool reports its own health | — | load client event-loop lag (client-cost spike) | own |

## Replay

The reevaluation runner already matches the shape: it loads recorded inputs into `pendingItems` and calls `stepTickOnce`. In this architecture it is the same runner with a different capture source (the recording) and a different outbox sink; the existing `mode == .reevaluation` branches (join skips OnJoin, `handleActionEnvelope` returns empty, the flushOutputs sink) collapse into that switch. Restoring the sequence watermark stays the replay source's job.

**Replay readiness for sync output** (built in now, verification later):
- Record format gains, via `decodeIfPresent` and a record-version bump (`recordVersionMismatch`): the canJoin decision and every join including non-first sessions, thrown inputs with outcome `threw`, disconnect vs leave. These are needed anyway (rule 5, Membership).
- With membership recorded, the per-player frame set is determined by the recording.
- Still required before sync output can be compared: a comparator over canonical patch lists (sorted paths, values, event sequences), not encoded bytes. Because the comparator sorts, the live diff's key iteration order (`compareSnapshots` iterates `Set(keys)`) does not need to become deterministic: patches on distinct paths commute, and array order is part of the state the diff already preserves. The hot path stays unchanged. Membership recording lands with the #69 re-plan (join as a captured input). After #69, the remaining work is the comparator plus one verification run per encoding. The precondition is "same inputs + same session/membership trace + same encoding and starting cache state".

## Mapping of current and planned work

| Work | Role in the shape | Removes | State |
|---|---|---|---|
| #86 ordered writer | Outbox delivery: frames are values, enqueued synchronously, delivered in order | polling drain, direct join-response send; `transportSendQueue` deprecated (nil), `TransportSendQueue` type removed in layer 3 | open, perf investigation |
| PR 3 (#61) | Outbox back-pressure | — | after #86 |
| PR 2 (plan + commit) | The sync phase; planned as synchronous functions so step 4 can call them | — (behaviour-preserving) | after #86 |
| Layer 3 (spike + 2 PRs) | The runner; adapter shares the keeper's executor; per-input savepoints; recorder enqueue | `beginSync`/`endSync`/`isSyncing`; OnLeave's `syncBroadcastOnlyFromTransport` and broadcast-only cycles (leave is an input, its effects go out in the turn's sync phase); #68 clear-at-beginSync (→ commit); #77/#82 consumed-event marks and follow-up decision (event queue consumed in commit, same turn) | after PR 2 |
| #87, #88 | Fixed by rule 5 and rule 4; may be fixed earlier on their own | — | issues |
| #69 (re-planned) | Join as a captured input; firstSync in the same turn | `syncStateForNewPlayer` becomes the "join applied" outcome; `lateJoinSnapshot`, `initialSyncingPlayers`, per-player `hasReceivedFirstSync` (→ per-session state); watermarks, W1/W2 handling | after layer 3 |
| #84 cross-land leak | Outbox frames are `.session`-addressed per land (done in #86); immediate path removed in layer 3 | transport-wide `.broadcast` from a land | #86 + layer 3 |
| #83 debug freeze | Runner control point between turns; projection is a sync-turn result | tickless in-flight counter moves to the input boundary: freeze holds capture, running resolvers finish and their results wait in the capture queue | on main; adapt in layer 3 |
| Boundary primitives (#96 PR first) | SingleFlight + Epoch + test gate; serial queue documented | duplicate lands, removal by ID, destroy/join race; later #97–#101 | #96 PR after #86 |
| #89 phase offset (merged) | Cross-room scheduling: per-land stable phase offset | burst alignment of land loops | done; timer audit for other aligned periodic work pending |
| Sync-output replay | Readiness built in (Replay section); comparator later | — | later (after the join re-plan) |

## What this changes in the existing plans

- PR 2: name its plan/commit types after the sync phase; keep its tests; no new hop-dependent bookkeeping.
- #69 rev 3: superseded by a re-plan on top of layer 3 (Membership section). Kept: per-session synced state, generation before visibility, the own-OnJoin `.all` decision, `syncStateForNewPlayer` outcome semantics. Dropped: `beginSyncWithWatermark`, `r`/`w` bounds (the join and its events are in one turn), interleaved-flush handling, coalescing.
- Layer 3: the evaluation's conditions stand (spike, tick/sync split for the 50-player json room); the spike also measures savepoint cost.

## Out of scope

- A public, general-purpose framework. Generalize only if a second use appears.
- Cross-room atomic transactions.
- The sync-output comparator and canonical patch hashing.

## Adversarial check record (revision 1 → 2)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Rule 5 rewritten from today's behaviour (#87): rollback scope, thrown inputs recorded, response routing, measured cost; dirty flags kept on a throwing plan |
| B2 | blocking | Membership section: join is a captured input running canJoin → insert → OnJoin in the turn; router awaits the turn; latency stated; handshake stays outside |
| S1 | should | Enforcement subsection: compiler, structure, CI grep, review-only residue |
| S2 | should | Outbox carries per-input responses, errors, join decisions (#88) |
| S3 | should | Dirty-flag clear is part of commit |
| S4 | should | Recorder handoff is a synchronous ordered enqueue; freeze/teardown wait for both drains |
| S5 | should | "Removes" column; three turn kinds; #83 freeze holds capture; replay precondition widened |
| N1 | nit | Sync plan takes the event queue |
| N2 | nit | PR 2 "planned as" |
| Q1–Q5 | — | Answered in rules 2 and 5, Composability (tickless), Replay |
| R1 (rev 2 pass) | should | Any turn may include sync; joins wait for the next sync turn (option b, confirmed by the maintainer), batched; latency bound and measurement stated |
| R2 (rev 2 pass) | should | Pending-join failure paths (disconnect, handshake timeout, destroy, freeze), reconnection, deny |
| N1/N2 (rev 2 pass) | nit | Removes column completed; recorder drain timeout |
