# Action completion queue

Status: open (experiment branch `exp/action-completion-queue`; not merged without the maintainer's OK).

Line numbers are from `main` at 7a0f3b3b.

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
7. **Recording.** `applyPendingItem` records each action as it applies, with its resolver outputs and `resolvedAtTick` (`:2446`, `:2504`). Replay reads the recorded inputs per tick (`:2873`) and never runs resolvers.

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
- **Resolver-free actions** create no task. `submitAction` delivers them in its own segment, as today.
- **`handleActionEnvelope` stays.** It becomes `submitAction` followed by awaiting the response, with the same signature and behavior. Benchmarks, tests and any direct caller keep working.

### Where the line stops blocking

`TransportAdapter.handleActionRequest` calls `submitAction` on the inbound chain, so intake order is still the order the client sent in. Errors from intake (an unknown action, a bad payload, a superseded sender, a closed land) are sent at once, as now. The wait for the response moves into an adapter-owned task, tracked per session, which sends `actionResponse` or the error once the job completes. The chain moves on to the next message as soon as `submitAction` returns. Nothing in the NIO layer changes.

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
- **Join and leave are barriers on the chain.** A message sent after a join or leave is handled after it. See the leave edge below for what happens to actions still pending.
- **Delivery stays serial.** The existing "Serial delivery per session" rule still holds. What changes is that an action's handling returns at intake.

## Edges

1. **Out-of-order responses.**
   - The TS SDK matches responses by `requestID`: `actionCallbacks` is a `Map` keyed by it (`sdk/ts/src/core/view.ts:84`, `:362`, `:579`). Out-of-order responses already resolve the right promise; PR 3 adds a vitest case that pins this down.
   - PR 3 also checks the other in-repo clients, the ws-loadtest client and the CLI, for any FIFO assumption.
2. **Per-session in-flight cap.** The job table counts jobs per session. A job's entry is released when its **task ends**, not when its deadline fires. A resolver group that ignores cancellation therefore keeps its slot. At `ACTION_IN_FLIGHT_MAX_PER_SESSION` (default 8, 0 = no cap), the next resolver-bearing action from that session gets one of two treatments; this is decision D1:
   - (a) Rejected at intake with an error response. **Recommended:** events never wait.
   - (b) The chain waits for a slot. This is today's blocking, at N instead of 1.

   Resolver-free actions don't count.
3. **Abandoned-resolver cap, from the same table.** A process-wide count of jobs whose deadline passed but whose task is still running. It is the same quantity the `abandoned` gauge reports, kept by the table. At `RESOLVER_ABANDONED_MAX` (default 256, 0 = no cap), new resolver-bearing actions are rejected at intake until the count drops.
   - Joins and leaves with resolvers stay outside this cap in the first cut: they are barriers, and rejecting a leave would strand an entry.
   - The gauge and both caps get counters in the existing deadline metrics and in the profiler.
4. **Tickless lands.** Completion schedules the input drain itself (`scheduleInputDrain`, `:3567`), so a completion triggers its own turn. The response comes from the turn, as now.
   - `debugBeginWork` runs at submit and `debugEndWork` when the job's response is produced, so `debugFreeze` still drains in-flight actions.
   - The freeze's hold (`debugWaitWhileFrozen`) applies at submit as today.
5. **Deadline at drain.** The deadline still runs from the job's start, which is its intake, with the existing race.
   - A freeze drain or a destroy waits for a job at most until that job's deadline. After it, the job is abandoned: it keeps its table entry for the caps but no longer holds the drain.
   - A destroy cancels every job's task.
   - Completions that arrive while the land is draining are rejected with `landClosed` by the existing check. Their responses go out as errors if the session is still open.
6. **Leave or rejoin while an action is pending.** Leave does not wait for the session's jobs. A job that completes after the leave fails the ticket check at delivery and is rejected (`senderSuperseded`, the existing path, `:1756`). It is never applied or recorded.
   - On disconnect, the adapter drops the session's pending response tasks, so nothing is sent to a closed session. The keeper cancels the session's jobs.
   - A rejoin creates a new entry generation, so an old job is rejected the same way.
   - Decision D2 is whether leave should instead wait for the session's jobs, bounded by the deadline. **Recommended: no.** No client is left to receive those responses, and today's cross-session reentrancy already takes this path.
7. **Recording and replay: no format change expected.** Recording happens when an input applies (`:2504`), with its resolver outputs and its `resolvedAtTick`. Replay reads recorded inputs per tick and never runs resolvers.
   - Two sessions already have actions pending at the same time today, so the recorder already sees interleaved completions. A second pending action from the same session adds no new kind of interleaving.
   - A rejected job has taken a sequence number and leaves a gap. Replay already crosses such gaps through the recorded watermarks.
   - A test confirms all this rather than assuming it (test plan, item 2).
8. **Error code for the caps.** Rejecting at a cap needs a client-visible reason. A new `ErrorCode` value, e.g. `ACTION_IN_FLIGHT_LIMIT`, adds a string to the error payload. It changes no existing message's bytes, but it is a protocol addition. This is decision D3; the alternative is `ACTION_HANDLER_ERROR` with a message.

## What is reused and what changes

**Reused unchanged:**
- the intake checks and ticket;
- `deliverResolvedAction`;
- `pendingItems` and `readyPendingItemsInOrder`;
- tick and input-turn apply;
- recording;
- the deadline race in `ResolverExecutor`;
- `awaitInputTurn` and `scheduleInputDrain`;
- the NIO inbound chain and backlog bound;
- the SDK's `requestID` matching.

**Changed:**
- `LandKeeper`: the job table, `submitAction`, `completeAction`, cancellation on leave and destroy, the caps, and drain accounting.
- `TransportAdapter.handleActionRequest`: submit on the chain, then respond from a tracked task; tasks dropped on disconnect.
- `ResolverExecutor`: the race gains a hook so the job table learns when an abandoned task ends. The `abandoned` gauge stays.
- The env keys and docs.

**Not changed:**
- client events, join and leave intake;
- join and leave resolvers, which remain blocking barriers;
- wire format;
- recording format.

## PRs (each targets the experiment branch; reviewed; core-path rules apply)

1. **Job table and submit/complete split, behavior unchanged.** `handleActionEnvelope` = submit + await; the adapter still awaits it. Covers the job table, `completeAction`, cancellation on leave and destroy, and drain accounting. Tests show the existing resolver, delivery, replay and freeze suites pass unchanged, plus the new hold-point tests for completion.
2. **Caps.** The per-session in-flight cap and the abandoned cap from the table, with env keys, metrics, and the D1/D3 choices.
3. **Unblock the chain.** The adapter submits on the chain and responds from tracked tasks. Also includes:
   - the out-of-order response tests;
   - the disconnect tests;
   - the client FIFO audit and the SDK vitest case;
   - docs (EN + zh-TW);
   - a `Notes/solutions/` entry if a lesson emerges.

## Test plan

Swift Testing. The interleavings are forced with `HoldPoints` / `TestGate`, never timing. New hold points: `actionJobStart` (inside the job task, before the resolvers) and `actionComplete` (before the completion segment).

1. **Chain not blocked.** Action A's resolver is held. An event, a resolver-free action and a second action B from the same session are all handled and applied before A completes, on a tick land and a tickless land.
2. **Completion order.** A then B are sent and B's gate opens first. B applies in an earlier tick than A. The records show B before A, and `ReevaluationRunner`-style replay matches the live state hash. Within a single tick, A and B apply by sequence.
3. **Ticket.**
   - A leave during A's resolvers rejects A at delivery: no state change, no record, the error counted.
   - A rejoin during A's resolvers gives the same result.
4. **Drain.**
   - A destroy during A cancels its job. A's completion is rejected with `landClosed`, and the `abandoned` gauge returns to 0.
   - `debugFreeze` on a tickless land waits for the in-flight job up to its deadline.
5. **Caps.**
   - The (N+1)th held action from one session is rejected under D1(a); a resolver-free action and an event still pass.
   - A resolver that ignores cancellation keeps its slot after the deadline and frees it when its task ends.
   - At the abandoned cap the next resolver-bearing action is rejected, and accepted again after one task ends.
6. **Unchanged paths.**
   - Resolver-free actions keep their response and their timing: an ACK on tick lands, the handler response on tickless lands.
   - `handleActionEnvelope` callers see the same results.
7. **Adapter.**
   - Two actions get out-of-order responses, each with the right `requestID`.
   - A disconnect with jobs in flight sends no frame to the closed session and leaves no tracked task behind.
8. **SDK.** A vitest case: two pending actions, responses in reverse order, each promise resolves with its own response.
9. **Full gates.**
   - `swift test`, plus the three-encoding E2E (`test-e2e-ci.sh`, `test-e2e-game.sh` with reevaluation);
   - CI on the pinned toolchain;
   - one mutant per new rule, each shown to fail its test: the adapter awaiting the response again, the ticket check removed, the slot freed at the deadline instead of at task end, the drain waiting without a deadline.

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

## Open decisions for the maintainer

- **D1.** At the per-session cap, reject (recommended) or block the chain.
- **D2.** Leave doesn't wait for the session's pending actions (recommended), or waits up to the deadline.
- **D3.** A new `ACTION_IN_FLIGHT_LIMIT` error code (recommended), or reuse `ACTION_HANDLER_ERROR`.
- **Defaults.** `ACTION_IN_FLIGHT_MAX_PER_SESSION` = 8, `RESOLVER_ABANDONED_MAX` = 256.
