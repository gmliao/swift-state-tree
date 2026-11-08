# Action completion queue

Status: open (experiment branch `exp/action-completion-queue`; not merged without the maintainer's OK).

Line numbers are from `main` at 7a0f3b3b. Revision 2 takes in the plan review: tickless replay order (#325), the response slot, the abandoned-action count, and D1–D3 settled.

## Problem

A session's messages are handled one after another, and an action holds that line until its resolvers finish. So one slow external call delays everything else the client sends: resolver-free actions, client events (hero-defense movement is an event), join and leave. The delay can last up to the resolver deadline, 5000 ms by default for the whole process. Timed-out resolvers that ignore cancellation keep running, and nothing bounds how many of them there are.

## Current flow

1. **NIO inbound chain.** `WebSocketSessionHandler` hands each batch of frames to the session's `InboundTaskChain` (`Sources/SwiftStateTreeNIO/WebSocketSessionHandler.swift:416-427`). The chain runs one operation at a time: each `Task` awaits the previous one's `value` (`Sources/SwiftStateTreeNIO/InboundTaskChain.swift:18-26`). The batch awaits `transport.handleIncomingMessage` for each frame in turn.
2. **Transport, router, adapter.** `WebSocketTransport.handleIncomingMessage` awaits `delegate.onMessage` (`Sources/SwiftStateTreeTransport/WebSocketTransport.swift:341`). The router awaits `transportAdapter.onMessage` (`Sources/SwiftStateTreeTransport/LandRouter.swift:1022`), and the adapter awaits `handleActionRequest` (`Sources/SwiftStateTreeTransport/TransportAdapter.swift:2231`). That function awaits `keeper.handleActionEnvelope` (`:4822`) and only then sends the response.
3. **Keeper intake.** Intake runs in one synchronous segment of `LandKeeper.handleActionEnvelope` (`Sources/SwiftStateTree/Runtime/LandKeeper.swift:1945`). It does the closed-land and sender checks, takes the sequence number (`:2021`) and captures the ticket (`actionTicket`, `:1735`, holding the sender's entry generation).
4. **Resolvers.** `ResolverExecutor.executeResolvers` runs inside the keeper call (`LandKeeper.swift:2042`). It races the group against `ResolverDeadline.current` (`Sources/SwiftStateTree/Resolver/ResolverExecutor.swift:93-133`). When the deadline wins, the group keeps running unstructured, counted by the `abandoned` gauge (`ResolverDeadline.swift:87`). No limit applies (`ResolverExecutor.swift:101-118`).
5. **Delivery.** `deliverResolvedAction` (`LandKeeper.swift:1756`) re-checks that the land isn't closed and the ticket still matches. It then appends the action to `pendingItems` with `resolvedAtTick` set to the tick current at delivery.
6. **Apply.**
   - Tick land: the action applies in the next tick, in `readyPendingItemsInOrder` order (`:2425`): by `resolvedAtTick`, then by sequence. The call returns an empty ACK right after delivery (`:2083`), so the handler's return value doesn't reach the client today.
   - Tickless land: the call waits for the input turn and returns the handler's response (`awaitInputTurn`, `:3553`).
7. **Recording.** `applyPendingItem` records each action as it applies, with its resolver outputs and `resolvedAtTick` (`:2446`, `:2504`). Replay reads the recorded inputs per tick (`:2873`), queues them, and applies them in `readyPendingItemsInOrder` order. It never runs resolvers.
   - **Tickless lands.** `lastCommittedTickId` is assigned only on the tick paths (`:3020`, `:3194`), so on a live tickless land every input has `resolvedAtTick = -1` and every turn records under tick 0. The recorder appends the inputs in apply order (`ReevaluationRecorder.swift:586`), but replay re-sorts them by sequence.
   - So a tickless replay diverges from live whenever an input applies before one with a lower sequence. This already happens across sessions today and is filed as #325.

Steps 3, 5 and 6 already follow the turn rule: intake and delivery are synchronous segments, and the ticket is checked against current state. The only blocking comes from steps 1–2: the chain waits on the keeper call, and the keeper call waits on the resolvers.

Docs today state only delivery order: "Serial delivery per session" (`docs/transport/README.md:54`) and the inbound backlog bound (`:265`). They say nothing about the order inputs are applied in.

## Design

### Shape

The keeper's action entry point splits in two:

- **`submitAction(envelope, playerID, clientID, sessionID) throws -> ActionSubmission`** is synchronous apart from `ensureInitialized`. It runs today's intake segment unchanged: decoding, the closed-land and sender checks, the sequence number and the ticket. Then it registers a **job** in the keeper's job table under the job ID, sequence, session, ticket and intake tick. If the action declares resolvers, it starts a job task that runs them under the deadline race. It returns at once. `ActionSubmission` carries the sequence and the means to await the response.
- **Completion is a keeper turn.** The job task ends by calling `completeAction(jobID, result)` on the keeper. That synchronous segment:
  - removes or marks the job;
  - re-reads current state through the existing `deliverResolvedAction`, with its closed-land and ticket checks, and appends the input with `resolvedAtTick` set to the current tick;
  - on a tickless land, registers the response waiter in the same segment and schedules the input drain.

  This is the completion queue: completed jobs feed the existing `pendingItems` / `processPendingActions` / input-turn path. No second apply path is added.
- **The response slot is created at submit.** `submitAction` creates the job's response slot in its own segment, before any await. The completion segment (tick lands: the ACK) or the input turn (tickless lands: the handler's response or error) fills the slot. The adapter awaits the slot, not `awaitInputTurn`.
  - This matters because `awaitInputTurn` returns an empty response for an input a turn has already applied (`:3553`). A late adapter wait through it would lose a tickless response.
  - A waiter that arrives after the slot is filled gets the stored value. The slot is removed once it has been read, or when the job is cancelled.
- **Resolver-free actions keep today's path exactly.** No job, no task and no adapter task:
  - `submitAction` delivers them in its own segment.
  - The adapter awaits them on the chain as today: an ACK on tick lands, the input turn on tickless lands.

  The measured hot path doesn't change.
- **Jobs are addressed by job ID.** Cancellation on leave, rejoin, disconnect or destroy selects jobs by job ID and by the ticket's entry generation, never by session or player key alone. A job of an older session or entry is never confused with a newer one under the same key.
- **`handleActionEnvelope` stays.** It becomes `submitAction` followed by awaiting the response, with the same signature and behavior. Benchmarks, tests and any direct caller keep working.
- **Freeze hold.** On tickless lands, `submitAction` still awaits `debugWaitWhileFrozen` before intake, as today. The ticket and sequence segment comes after that await, so nothing captured before it goes stale.

### Where the line stops blocking

`TransportAdapter.handleActionRequest` calls `submitAction` on the inbound chain, so intake order is still the order the client sent in. Errors from intake (an unknown action, a bad payload, a superseded sender, a closed land, a cap) are sent at once, as now.

For an action with resolvers, the wait for the response moves into an adapter-owned task. The task is tracked per session under the job ID, and it sends `actionResponse` or the error once the slot is filled. The chain moves on to the next message as soon as `submitAction` returns. Nothing in the NIO layer changes.

### Order

- Sequence numbers are taken at intake, as today.
- An action applies in the first turn after its completion: tick lands by `resolvedAtTick`, which is the completion tick.
  - Between ticks this is completion order.
  - Within one tick, ties go by intake sequence (the existing sort, `:2425`). The order is deterministic and recorded.
- Responses can reach the client in a different order from the requests.

### Contract (documented in `docs/transport/README.md` and its zh-TW twin)

- **Actions are independent.** Two actions from one session have no application order between them.
- **A causal chain is the client's job.** If an action depends on an earlier one, the client awaits that action's response before sending it.
- **Client events keep send order.** A session's events apply in the order sent, and an event is never held behind a pending action. Events stay on the chain, and their intake is synchronous.
- **Events and resolver-free actions can overtake an earlier action.** Either one, sent after an action whose resolvers are still running, can apply before that action.
- **Join and leave are barriers on the chain.** A message sent after a join or leave is handled after it. See the leave edge below for what happens to actions still pending.
- **Delivery stays serial.** The existing "Serial delivery per session" rule still holds. What changes is that an action's handling returns at intake.

## Edges

1. **Out-of-order responses.**
   - The TS SDK matches responses by `requestID`: `actionCallbacks` is a `Map` keyed by it (`sdk/ts/src/core/view.ts:84`, `:362`, `:579`). Out-of-order responses already resolve the right promise; PR 3 adds a vitest case that pins this down.
   - PR 3 also checks the other in-repo clients, the ws-loadtest client and the CLI, for any FIFO assumption.
2. **Per-session in-flight cap.** The job table counts jobs per session. A job's entry is released when its **task ends**, not when its deadline fires. A resolver group that ignores cancellation therefore keeps its slot. At `ACTION_IN_FLIGHT_MAX_PER_SESSION` (default 8, 0 = no cap), the next resolver-bearing action from that session is rejected at intake with an error response (D1). The chain never waits for a slot, so events never wait. Resolver-free actions don't count.
3. **Abandoned-action cap: its own process-wide count.** This can't come from the per-keeper table, and it isn't the `abandoned` gauge, which also counts joins, leaves and OnInitialize across every land.
   - The new count is a process-wide counter of **action** jobs whose caller stopped waiting while their task still runs. It sits beside `ResolverDeadlineMetrics`.
   - The count goes up when the deadline wins the race (`ResolverExecutor.swift:113`) or the caller is cancelled (`:125`).
   - It comes down when the abandoned task ends, on both paths: the deadline path (`:117-118`) and the onCancel path (`:128-131`). The executor gets an `onAbandonedEnd` hook so each action job releases its unit, and its per-session slot, exactly once.
   - At `RESOLVER_ABANDONED_ACTIONS_MAX` (default 256, 0 = no cap), new resolver-bearing actions are rejected at intake until the count drops.
   - Joins and leaves with resolvers stay outside this cap in the first cut: they are barriers, and rejecting a leave would strand an entry.
   - The existing `abandoned` gauge is unchanged. The new count and both caps' rejections get counters in the deadline metrics and the profiler.
4. **Tickless lands (after #325, see edge 7).** Completion schedules the input drain itself (`scheduleInputDrain`, `:3567`), so a completion triggers its own turn. The turn fills the job's response slot.
   - `debugBeginWork` runs at submit and `debugEndWork` when the job's response is produced, so `debugFreeze` still drains in-flight actions.
   - The freeze's hold (`debugWaitWhileFrozen`) applies at submit as today.
5. **Deadline at drain.** The deadline still runs from the job's start, which is its intake, with the existing race.
   - A freeze drain or a destroy waits for a job at most until that job's deadline. After it, the job is abandoned: it keeps its table entry for the caps but no longer holds the drain.
   - A destroy cancels every job's task.
   - Completions that arrive while the land is draining are rejected with `landClosed` by the existing check. Their responses go out as errors if the session is still open.
6. **Leave or rejoin while an action is pending.** Leave does not wait for the session's jobs. A job that completes after the leave fails the ticket check at delivery and is rejected (`senderSuperseded`, the existing path, `:1756`). It is never applied or recorded.
   - On disconnect, the adapter drops the session's pending response tasks by job ID, so nothing is sent to a closed session. The keeper cancels the jobs whose ticket names the ended entry.
   - A rejoin creates a new entry generation, so an old job is rejected the same way.
   - Decision D2 is whether leave should instead wait for the session's jobs, bounded by the deadline. **Recommended: no.** No client is left to receive those responses, and today's cross-session reentrancy already takes this path.
7. **Recording and replay.**
   - **Tick lands: no change.** An action is bound to the tick current at its completion. Replay orders by `(resolvedAtTick, sequence)`, which is the live order: completion tick first, then intake sequence within the tick. A rejected job leaves a sequence gap, and replay already crosses such gaps through the recorded watermarks.
   - **Tickless lands: the apply order must be recorded.** Today replay re-sorts tick 0 by sequence while live applies in turn order (Current flow, step 7; #325). The plan would make this the normal case within one session.
   - **The fix, done first as #325 on `main` and then picked up by this branch:**
     - Each tickless input turn, and each legacy pass, is recorded as its own pass in the frame: the input sequences in apply order across actions, client events and lifecycle inputs, plus the sequence counter before the pass. That counter is the per-pass watermark #321 asks for, so the two land together.
     - Replay applies a frame that carries passes pass by pass, in recorded order, and restores the watermark before each one.
     - This is a record-format change, not a wire change. It is an optional field, so a record without passes replays as today, with a record version note.
   - **Until #325 lands,** a tickless land's resolver-bearing actions keep blocking the chain: PR 3 unblocks tick lands only. Tickless unblocking is a follow-up PR on top of #325.
8. **Error code for the caps (D3, settled).** No new `ErrorCode` while the wire is frozen.
   - A cap rejection uses `ACTION_HANDLER_ERROR` with a distinct message: "action rejected: in-flight limit reached" or "action rejected: abandoned-resolver limit reached".
   - A dedicated code (`ACTION_IN_FLIGHT_LIMIT`) is a follow-up after the freeze.

## What is reused and what changes

**Reused unchanged:**
- the intake checks and ticket;
- `deliverResolvedAction`;
- `pendingItems` and `readyPendingItemsInOrder`;
- tick and input-turn apply;
- tick-land recording;
- the deadline race in `ResolverExecutor`;
- `scheduleInputDrain`;
- the NIO inbound chain and backlog bound;
- the SDK's `requestID` matching;
- the resolver-free action path.

**Changed:**
- `LandKeeper`: the job table, `submitAction`, `completeAction`, response slots, job-ID cancellation, the per-session cap and drain accounting.
- `TransportAdapter.handleActionRequest`: submit on the chain; an action with resolvers is answered from a tracked task; tasks dropped by job ID on disconnect.
- `ResolverExecutor`: an `onAbandonedEnd` hook on both abandonment paths, and the process-wide abandoned-action count. The `abandoned` gauge stays.
- Tickless recording and replay: passes with per-pass watermarks (#325 with #321, on `main` first).
- The env keys and docs.

**Not changed:**
- client events, join and leave intake;
- join and leave resolvers, which remain blocking barriers;
- wire format, which has no new error code (D3).

## PRs

**#325 lands on `main` first**, as its own core PR: tickless passes, together with #321. It fixes a bug that already exists, independent of this experiment.

The PRs below each target the experiment branch, are reviewed, and follow the core-path rules.

1. **Job table and submit/complete split, behavior unchanged.**
   - `handleActionEnvelope` = submit + await the slot; the adapter still awaits it.
   - Covers the job table, response slots, `completeAction`, job-ID cancellation and drain accounting.
   - Tests: the existing resolver, delivery, replay and freeze suites pass unchanged, plus the new hold-point tests.
2. **Caps.** The per-session in-flight cap and the process-wide abandoned-action count with its executor hook. Also env keys, metrics, and `ACTION_HANDLER_ERROR` messages.
3. **Unblock the chain on tick lands.** The adapter submits on the chain and answers actions with resolvers from tracked tasks. Also includes:
   - the out-of-order response tests;
   - the disconnect tests;
   - the client FIFO audit and the SDK vitest case;
   - docs (EN + zh-TW);
   - a `Notes/solutions/` entry if a lesson emerges.
4. **Unblock the chain on tickless lands**, after #325: the tickless completion-order replay test.

## Test plan

Swift Testing. The interleavings are forced with `HoldPoints` / `TestGate`, never timing. New hold points: `actionJobStart` (inside the job task, before the resolvers) and `actionComplete` (before the completion segment).

1. **Chain not blocked.** Action A's resolver is held. An event, a resolver-free action and a second action B from the same session are all handled and applied before A completes. This runs on a tick land, and on a tickless land in PR 4.
2. **Completion order.**
   - **Tick land.** A then B are sent and B's gate opens first. B applies in an earlier tick than A. The records show B before A, and `ReevaluationRunner`-style replay matches the live state hash. Within a single tick, A and B apply by sequence.
   - **Tickless land (#325, then PR 4).** The handlers append to one list, so they don't commute. B is applied before A, and the replayed list equals the live one, `[B, A]`. The test also covers a client event overtaking a pending action, and an old record without passes still replaying.
3. **Response-slot race (tickless).** The input turn applies the action and fills its slot before the adapter's task starts waiting; it is held with a hold point. The late waiter still gets the handler's response, not an empty one.
4. **Ticket.**
   - A leave during A's resolvers rejects A at delivery: no state change, no record, the error counted.
   - A rejoin during A's resolvers gives the same result.
5. **Drain.**
   - A destroy during A cancels its job. A's completion is rejected with `landClosed`, and the `abandoned` gauge returns to 0.
   - `debugFreeze` on a tickless land waits for the in-flight job up to its deadline.
6. **Caps.**
   - The (N+1)th held action from one session is rejected (D1); a resolver-free action and an event still pass.
   - A resolver that ignores cancellation keeps its slot after the deadline and frees it when its task ends, on both the deadline path and the caller-cancelled path.
   - The abandoned-action count ignores joins, leaves and OnInitialize.
   - At the abandoned cap the next resolver-bearing action is rejected, and accepted again after one task ends.
7. **Unchanged paths.**
   - Resolver-free actions keep their response and their timing: an ACK on tick lands, the handler response on tickless lands.
   - `handleActionEnvelope` callers see the same results.
8. **Adapter.**
   - Two actions get out-of-order responses, each with the right `requestID`.
   - A disconnect with jobs in flight sends no frame to the closed session and leaves no tracked task behind.
9. **SDK.** A vitest case: two pending actions, responses in reverse order, each promise resolves with its own response.
10. **Full gates.**
   - `swift test`, plus the three-encoding E2E (`test-e2e-ci.sh`, `test-e2e-game.sh` with reevaluation);
   - CI on the pinned toolchain;
   - one mutant per new rule, each shown to fail its test:
     - the adapter awaiting the response again;
     - the ticket check removed;
     - the slot freed at the deadline instead of at task end;
     - the drain waiting without a deadline;
     - the adapter waiting through `awaitInputTurn` instead of the slot (fails the response-slot race);
     - tickless replay re-sorting a pass by sequence (fails tickless completion order);
     - the abandoned count freed on only one of the two paths.

## Evaluation (Mac only; measurement-host runs come later and separately)

Use the external-input-failure topic's harness as it is: `deep-research/external-input-failure/run.sh` in its `SMOKE=1` mode, unpinned, with its cell selection and environment. Its scripts are not edited. Run the same cells at the base commit and at the branch head. Each side is built in release with the same toolchain, and each side's `swift --version` is recorded.

- Compare the slow-resolver and timeout cells, base against head, on:
  - the ack latency of the inputs that succeed;
  - tick advance;
  - `inboundQueuedMessagesMax`;
  - the `abandonedResolvers` gauge and its drain time;
  - the replay verification result.
- **Expected:** latency of events and resolver-free actions no longer tracks resolver latency for the same session, the inbound queue stays small, replay still verifies, and the abandoned gauge stays at or below the cap.
- The Mac numbers show direction only. They are not written into the topic's README or results. A write-up goes into this plan's evaluation notes, and any publishable run happens later on the measurement host with its own design note.

## Decisions

Settled on review, pending the maintainer's OK of the whole plan:
- **D1.** At the per-session cap, reject the action with an error response; never block the chain.
- **D2.** Leave doesn't wait for the session's pending actions. They are rejected at delivery by the ticket.
- **D3.** No new error code while the wire is frozen. Cap rejections use `ACTION_HANDLER_ERROR` with a distinct message. `ACTION_IN_FLIGHT_LIMIT` is a follow-up after the freeze.

Open for the maintainer:
- **Defaults.** `ACTION_IN_FLIGHT_MAX_PER_SESSION` = 8 and `RESOLVER_ABANDONED_ACTIONS_MAX` = 256.
- **Order.** #325, the tickless replay order, with #321, lands on `main` before this branch's tickless step.
