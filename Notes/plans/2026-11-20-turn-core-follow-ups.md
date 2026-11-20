# Turn core: coalesced follow-ups and a quiescence wait (#702)

**Status:** open, rev 2. Plan for review before any code: Code-1 checks the use-case mapping (§5), then Review reviews the plan.

**Rev 2** (Main's points on rev 1):
- `TurnDiagnostic` gets a new case, `.staleFollowUp`, instead of reusing `.staleTimer`. §7 states the switch break.
- Only the triggers whose users survive L2 stay: `.afterBatch` and `.afterWork`.
  - The latch, `.held`'s only user, is deleted in L2d (`2026-11-20-remove-adapter-off-mode.md` §3.6), before #700 adopts this.
  - The join-sync turn, the only user of `.after(Duration)` in the keeper, always passes `.zero`.
  - Both triggers and `releaseFollowUp` are dropped (§3.3, §12).
- §5.6 is corrected: the adapter's backlog and busy retry is deleted in L2c.

**Scope:** `SwiftStateTurns` only. One additive API: a coalesced follow-up per key and slot, owned by the key's generation, and a quiescence wait for tests. No adopter changes. Three of `LandKeeper`'s four hand-rolled slots (#695, #546 L2a) move onto it when the keeper adopts `TurnCore` (#700); L2d deletes the fourth, the latch, before that. Until then, #695's interim `GenerationTable` slots stay as they are.

## 1. The problem

An adopter often needs one follow-up to run after the current step, and only one. Requests made while it is pending should join it. An outside input that does the same work now should be able to consume it. The core has two near misses:
- `Turn.timer(at:for:_:)`: one per key, and a new one **replaces** the old;
- `Turn.queue(_:behind:)`: an input behind a hold, not coalesced, and it can't be consumed.

So adopters hand-roll the slot and a begin/end count for their tests. #695 hand-rolled four. Its review found that the slots were keeper-wide, not per binding. After a rebind, the old binding's pending retry blocked the new binding's from arming, then failed its own check, so the new binding's deferred sync never retried. Keyed generations rule that out, if the slot belongs to the generation. That is what this plan adds.

## 2. Prior art

| System | What it has | What we take, what differs |
|---|---|---|
| Erlang `gen_statem` ([docs](https://www.erlang.org/doc/apps/stdlib/gen_statem.html)) | `{next_event, …}` inserts an event that is handled next. Generic timeouts `{{timeout, Name}, T, Msg}` keep one timer per name: setting one again under a running name restarts it, and `{{timeout, Name}, cancel}` drops it. `state_timeout` is cancelled by a state change. | One pending item per name, dropped when its owner's state ends (our generation end). We **join** instead of restart (§3.2). `next_event` isn't coalesced. |
| Erlang `gen_server` with `erlang:start_timer/4` | The timer reference comes back in the message; the server compares it with the one in its state. | The ticket pattern the core already owns (rule 4 of the core plan). |
| Akka Typed `TimerScheduler` ([docs](https://doc.akka.io/libraries/akka-core/current/typed/interaction-patterns.html#scheduling-messages-to-self)) | `startSingleTimer(key, msg, delay)`, `isTimerActive(key)`, `cancel(key)`. A new timer under a key replaces the old, and a message from a replaced timer is not delivered. | Keyed, stale-safe, testable "is it armed" check. Replace, not join. |
| Elm ([`Process`](https://package.elm-lang.org/packages/elm/core/latest/Process)) | No coalescing primitive: `Process.sleep` piped into a `Cmd`, with a counter in the model so a stale message is ignored (the debounce packages do this). | Hand-rolled by every program; the core's job is to make it a primitive. |
| RxJS [`throttleTime`](https://rxjs.dev/api/operators/throttleTime), [`debounceTime`](https://rxjs.dev/api/operators/debounceTime), [`exhaustMap`](https://rxjs.dev/api/operators/exhaustMap) | Throttle (leading): first value wins, later ones in the window are dropped. Debounce (trailing): each value restarts the wait. `exhaustMap`: new values are ignored while the inner work runs. | Our join is `exhaustMap` for work, and throttle-leading in kind: the first arm wins (§3.2). Debounce is rejected: a steady stream would never let it run. |
| UIKit [`setNeedsLayout`](https://developer.apple.com/documentation/uikit/uiview/setneedslayout()) / [`layoutIfNeeded`](https://developer.apple.com/documentation/uikit/uiview/layoutifneeded()) | A flag that coalesces requests until the next update cycle. `layoutIfNeeded` does the pending layout now, and the flag clears. | Arm and join = `setNeedsLayout`. Consume, then doing the work in the same step = `layoutIfNeeded`. |
| Vue's scheduler ([`nextTick`](https://vuejs.org/api/general.html#nexttick)) | `queueJob` adds a job once per flush (a job already queued isn't added again); the flush runs in a later microtask. | The after-batch trigger runs as the actor's own job, after the batch, and a chain doesn't starve it (§3.3). |
| kotlinx.coroutines.test [`advanceUntilIdle`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-test/kotlinx.coroutines.test/-test-coroutine-scheduler/advance-until-idle.html), Espresso [`IdlingResource`](https://developer.android.com/training/testing/espresso/idling-resource) | Tests wait until the scheduler has no queued work, or until the app reports that it is idle, instead of sleeping. | The quiescence wait (§3.5). Ours only waits: the clock is the test's to drive. |

What none of them has, and the core adds: the pending item belongs to a key's **generation**. Ending or superseding the key closes the item unrun, in the same step, so an item armed under an old binding can neither run nor block the new binding's. That is the #695 bug class.

## 3. Design

### 3.1 Identity: a key and a slot

A follow-up is named by `(key, slot)`. The key gives it its owner and lifetime, as for a request. The slot tells a key's follow-ups apart: the keeper has three under one binding key (§5). `FollowUpSlot` is a new associated type with the default `Never`, so a machine that declares none is unchanged.

Each follow-up also gets a `RequestID` from the requests' counter. `handleAbandoned` can then name it, and no new identity type or `Abandonment` case is needed. Adding a case to the public `Abandonment` enum would break adopters' exhaustive switches.

### 3.2 Arm and join

`turn.followUp(input, slot, of: key, trigger)`:
- **`key` not live, or the core has ended:** nothing is armed, and the call returns `.refused`. After `endAll` it is counted in `ignoredAfterEnd`, as `start` and `queue` are.
- **No follow-up pending for `(key, slot)`:** one is armed under `key`'s current generation, and the call returns `.armed(id)`.
- **One is pending:** the call returns `.joined(id)` and changes nothing. The input and trigger stay the first arm's.

**Why join, and not replace as `timer` and gen_statem do.** The follow-up's handler reads the state when it steps, so the first arm's input serves as well as the latest's. Replacing an `.afterWork` follow-up on each arm would start its work again each time, and a steady stream of arms would keep putting it off (the debounce starvation). To start one again, consume it and arm again in the same step.

### 3.3 Triggers: when a pending follow-up steps

`FollowUpTrigger<Effect>` has two cases.

| Trigger | Steps | Used by |
|---|---|---|
| `.afterBatch` | In a new batch, run as the actor's own job after the current batch (as `continueDrain` is). It gets a fresh `now`. | The after-turn request (§5.3), the join-sync turn (§5.2) |
| `.afterWork(Effect, deadline: Duration?)` | When `perform(effect)` returns. A `deadline` that passes first closes the follow-up with `.deadline`. | The writer-drain retry (§5.1) |

Two triggers were in rev 1 and are dropped, because no user of theirs survives L2 (YAGNI). Either can be added later as a new case when a user needs it.
- **`.after(Duration)`:** a delay on the core's clock. The keeper's only delayed follow-up, the join-sync turn, always passes `.zero`. The adapter's delayed syncs (the behind-commit repair, the lag timer's request) keep their delays and holds on the adapter (L2 plan §3.2), and are outside requests, not follow-ups.
- **`.held`:** a follow-up stepped only when a step releases it. Its only user, the latch's rerun after a legacy cycle's `endSync`, is deleted in L2d with `beginSync`/`endSync` (L2 plan §3.6).

Rules:
- **It steps as a control input** through `handle`, under the generation it was armed in. That generation is current by construction: an end or supersede closes the follow-up eagerly (§3.4). Holds, `close` and the queue limit don't apply, as for a timer's input.
- **The slot is freed before the step,** so the step may arm a successor in the same slot. For `.afterBatch`, that successor runs in yet another batch. A follow-up that keeps re-arming itself is a chain of jobs, each yielding the actor, and can't loop inside one batch. That is why `.afterBatch` doesn't mean "at the end of this batch".
- **Order.** Follow-ups that become due together step in the order they were armed (by `RequestID`).
- **An `.afterWork` effect's own result** (a non-nil input from `perform`) steps as a `run`'s result does: as a control input, and before the follow-up's input. It steps whether or not the follow-up is still pending. A gate effect normally returns nil.

### 3.4 Consume and close

- **`consumeFollowUp(slot, of: key) -> M.Input?`.** Retires the pending follow-up without stepping it and returns its input; nil if none is pending. No `handleAbandoned` follows: the consumer already knows. A later arm in the same step makes a new one. A gate task still in flight finds the follow-up gone when it returns, and the follow-up's input doesn't step. A gate's own result still steps (§3.3).
- **`followUpPending(slot, of: key) -> RequestID?`.** A read, for the machine and its tests.
- **Closed unrun.** `end(key)`, a superseding `start(key)` and `endAll` close every follow-up of the key, as they close its requests: also ones armed earlier in the same step. Each closure steps `handleAbandoned(id, .keyEnded)` in that batch. A gate's deadline closes it with `.deadline`. A gate that returns for a closed follow-up steps nothing for it and reports `TurnDiagnostic.staleFollowUp`, a new case (§7).

### 3.5 The quiescence wait

On `TurnActor`:

```swift
public struct TurnWork: OptionSet, Sendable { followUps, requests, timers }
public func pendingWork(_ kinds: TurnWork = .followUps, of key: M.Key? = nil) -> Int
@discardableResult
public func waitForQuiescence(_ kinds: TurnWork = .followUps, of key: M.Key? = nil, atMost: Int = 0) async -> Bool
```

- **What counts:** a follow-up armed and not yet stepped, consumed or closed; an open request; an armed timer. The count can be restricted to one key. The default is follow-ups only: a periodic timer is never quiet.
- **When it is checked:** at the end of each synchronous segment of the actor: `runSegment`, and the entries that close work (completion, deadline, timer, gate return, the `.afterBatch` job). A step that retires a follow-up and arms its successor is one segment, so a waiter never sees the gap between them, and a chain keeps it waiting until the chain ends (#702's last boundary case).
- **It never hangs on an ended core.** `endAll` closes every request, follow-up and timer, so the next check wakes every waiter. A request whose worker hasn't returned (`.untilWorkerReturns`) is closed, so it doesn't count. When the actor is released, its core's `deinit` resumes the waiters that are left with false.
- **Cancellation.** A cancelled waiting task returns false at once, and its entry is removed (as `callerCancelled` removes a caller).
- **Returns** true once the count of `kinds` is at most `atMost`. It returns at once if the count is already there.
- **Cost (#621 item 4):** the waiters are an array scanned only when it isn't empty, so a core with no waiter pays one `isEmpty` test per segment. The count is recomputed per check (the follow-up table's size, or `open`/`timers` filtered by key), which is fine for tests.

`TurnStats` gains `pendingFollowUps` (a new stored property with a default).

## 4. Boundary cases (tests)

In `Tests/SwiftStateTurnsTests/FollowUpTests.swift`, on the test clock, with hold points where order matters and no sleeps. #702's cases first:
1. Arm, arm (`.joined`, the same id), run: one step, with the first input.
2. Arm, consume (the input is returned, and no step happens), arm again: `.armed` with a new id, then it runs.
3. Arm, then `end(key)`: closed unrun, `handleAbandoned(id, .keyEnded)`, and the wait wakes.
4. Arm under A, then `start` makes B current: A's is closed (`handleAbandoned`), B's arms freely (`.armed`) and runs. In the same step, an arm before the `start` is closed and one after it stands.
5. Arm during and after `endAll`: `.refused`, counted.
6. The wait with nothing armed returns at once (true).
7. The wait across a chain (a follow-up that arms its successor twice): it stays waiting until the third step, and each step is in a new batch (the clock is read three times).

Then:

8. `.afterWork`: it steps after the gate's `perform` returns, not before (the gate held at a `TestGate`). A gate result that isn't nil steps first. The deadline closes it with `.deadline`.
9. `.afterWork` closed while its gate runs (a consume, an `end`, a supersede): the gate's return steps nothing for it and reports `.staleFollowUp`, and the wait woke at the close, not at the return.
10. `.afterBatch`: it doesn't step inside the arming batch; it steps in the next job, with a fresh `now`.
11. A follow-up's input steps with its hold key held and after `close`: it is a control input.
12. Two slots under one key are independent. Two follow-ups due together step in arm order.
13. The wait: per key, `atMost`, `kinds` (requests and timers), a cancelled waiter, and an actor released with a waiter (it returns false; no leak).
14. Generated orders (`GeneratedOrderTests`): add arm, consume and end operations to the generator. Check invariants 18 to 20 (§6) after each step.
15. An exit test: `followUp` called from `read` stops the process, as every `Turn` use outside a step does. This one is free: `Turn` can't be made outside a step.

## 5. The LandKeeper follow-ups and the waiters

After #700, the keeper's machine has a key `.syncBinding`, started on every bind or rebind (today `syncBinding.rebind()` in `noteTransportBound` and `bindSyncRequester`). Its slots are `.drainRetry`, `.joinSync` and `.afterTurn`. The fourth hand-rolled slot, the latch, is deleted in L2d, before #700 (§5.4). The port isn't plain data, so it stays with the actor: the binding's generation names it, and the actor holds the current binding's port. Line numbers are #695's head (2c0361d1) `LandKeeper.swift`.

### 5.1 The writer-drain retry (`retrySyncOnlyTurnAfterWriterDrain`, :5112)

| Today | On the core |
|---|---|
| `guard inTurnDrainRetryBinding != syncBinding.current` (at most one per binding) | `followUp(.syncOnlyTurn, .drainRetry, of: .syncBinding, .afterWork(.waitForWriterDrain, deadline: nil))`; a second arm joins |
| `Task { await transport.waitForWriterDrainForInTurnSync(); await runRetriedSyncOnlyTurn }` | The gate effect's `perform` awaits the drain and returns nil |
| `runRetriedSyncOnlyTurn` clears the mark only if it is its own binding's | The core frees the slot before the step. A superseded binding's follow-up is closed at `start` and never runs |
| `acceptsSyncTurn(through:)`, the binding check | Not needed: the generation is current by construction. `mode`, `failure` and `isDraining` are still the handler's checks |
| "an invalidated retry still retires" (the wait returns at teardown) | It is closed at the supersede or `endAll`. The gate's late return steps nothing |

### 5.2 The join-sync turn (`scheduleJoinSyncTurn(after:)`, :5140)

| Today | On the core |
|---|---|
| At most one per binding (`joinSyncTurnBinding`) | `followUp(.joinSyncTurn, .joinSync, of: .syncBinding, trigger)`; a second arm joins |
| `after delay`, with `safeTaskSleep`. The only caller (:4691) passes `.zero`, and L2 keeps it so (L2 plan §3.2) | `.afterBatch`. The `delay` parameter goes; a delay would need `.after(Duration)`, dropped in rev 2 (§3.3) |
| The run re-checks `!isDraining`, `transportHasJoinsAwaitingSync` and the binding | The handler re-checks the first two; the binding is the generation |

### 5.3 The after-turn request (`requestSyncTurnAfterThisTurn`, :5283)

| Today | On the core |
|---|---|
| One pending. The same binding joins; a newer binding replaces it | `followUp(.syncOnlyTurn, .afterTurn, of: .syncBinding, .afterBatch)`. A join is `.joined`. A newer binding's `start` closed the old one, so its arm is `.armed` |
| `syncTurnNow` (an outside request through the same port) consumes it, then runs its phase, which may arm a successor | `syncTurnNow`'s step: `turn.consumeFollowUp(.afterTurn, of: .syncBinding)`, then its phase. A port that isn't the binding's is refused before this (`acceptsSyncTurn`), so "the same port" is "the current generation" |
| `runPendingSyncTurnAfterTurn`: `guard let followUp = pendingSyncTurnAfterTurn` (consumed meanwhile → retired) | The core doesn't step a consumed follow-up |
| `requestedSyncTurnsForTesting[reason]` | It stays a machine counter, bumped at arm time |

### 5.4 The latch's rerun: deleted in L2d, not mapped

L2d deletes `beginSync`/`endSync`, `isSyncing` and the latch `syncOnlyTurnAfterLegacyCycle` with its reads (L2 plan §3.6). L2 is ordered before #700, so the latch never reaches `TurnCore`. Rev 1 mapped it to a `.held` follow-up released by `endSync`'s step. `.held` had no other user and is dropped (§3.3). Until L2d, #695's interim latch stays as it is.

### 5.5 The waits

| Today | On the core |
|---|---|
| `requestedSyncWork` (begin/end count) | `pendingWork(.followUps, of: .syncBinding)` |
| `waitForRequestedSyncTurnsForTesting()` | `waitForQuiescence(.followUps, of: .syncBinding)` |
| `waitForRequestedSyncTurnsForTesting(atMost:)` | `waitForQuiescence(.followUps, of: .syncBinding, atMost: n)` |
| `hasRequestedSyncWorkForTesting` | `pendingWork(.followUps, of: .syncBinding) > 0` |
| The adapter's `waitForBackgroundSyncsForTesting` and the outbound-idle wait (`TransportAdapter.swift:3206`, :3221, :3225) | Unchanged: they call the keeper's waits, which forward |
| `inTurnDrainRetryBindingForTesting` | `followUpPending(.drainRetry, of: .syncBinding)` through a `read` |

The bug #695's review found, replayed on the core: A's retry is pending, `setTransport(B)` starts `.syncBinding` again, and A's retry is closed in that step. B's deferred phase arms `.drainRetry` and gets `.armed`, not `.joined`. Case 4 of §4 is this sequence on a model machine.

### 5.6 Later users, not in this plan

Per slot and trigger, after L2d:

| Trigger | Users after L2d |
|---|---|
| `.afterBatch` | The after-turn request (§5.3) and the join-sync turn (§5.2), on the keeper |
| `.afterWork` | The writer-drain retry (§5.1), which L2 keeps "as it is" (L2 plan §3.2) and its end state doesn't remove |
| `.after(Duration)`, dropped | None. The join-sync turn passes `.zero`. The adapter's behind-commit repair and the lag timer's request keep their delays and holds on the adapter (L2 plan §3.2); they are outside requests, which run their own turn at once |
| `.held`, dropped | None. The latch is deleted in L2d (§5.4) |

The adapter side, for when it adopts the core (#546's B slices):
- **The backlog and busy retry** (`deferSyncForOutboundBacklog`, `runBacklogDeferredSync`) is deleted in L2c with the off adapter's cycle (L2 plan §3.6). Rev 1 listed it here by mistake.
- **The adapter's kept-event follow-up** (`startFollowUpSync`) is deleted in L2c too. On an in-turn land the keeper's after-turn request (§5.3) does its work.
- **The behind-commit repair and the lag timer's request** stay on the adapter, each a delay, a hold, then an outside request. If a B slice wants either coalesced on the core, that slice adds `.after(Duration)` with its user.

## 6. Invariants added to the core's list

18. A follow-up steps after its key's generation ended or was superseded, after it was consumed, or twice.
19. Two follow-ups are pending for one `(key, slot)`.
20. A quiescence waiter returns true while more than `atMost` of its kinds are pending, or is still waiting after a segment in which nothing of its kinds is pending.

## 7. Public API

All additive and source-compatible, except one new enum case, stated below. Nothing existing changes signature or behaviour.

- `TurnMachine.FollowUpSlot: Hashable & Sendable`, an associated type with default `Never`.
- `public enum FollowUpTrigger<Effect: Sendable>: Sendable { case afterBatch, afterWork(Effect, deadline: Duration?) }`.
- `public enum FollowUpArming: Sendable, Equatable { case armed(RequestID), joined(RequestID), refused }`.
- On `Turn`:
  - `followUp(_:_:of:_:) -> FollowUpArming` (`@discardableResult`);
  - `consumeFollowUp(_:of:) -> M.Input?` (`@discardableResult`);
  - `followUpPending(_:of:) -> RequestID?`.
- On `TurnActor` (extension): `pendingWork(_:of:) -> Int` and `waitForQuiescence(_:of:atMost:) async -> Bool`.
- `public struct TurnWork: OptionSet, Sendable` with `followUps`, `requests` and `timers`.
- `TurnStats.pendingFollowUps: Int`.
- **`TurnDiagnostic.staleFollowUp`: a new case.** A gate returned for a follow-up already consumed or closed. It breaks source for an adopter that switches over `TurnDiagnostic` without a `default`: such a switch needs the new case, or a `default`. The enum is public, but its only producer is the `package` hook `onDiagnostic`, so in practice this package's tests. Reusing `.staleTimer` (rev 1) would have mislabelled it.

The wait is public, not `package`: adopters outside this package test their machines too. If Review prefers `package` for the first release, the switch costs nothing.

## 8. Implementation notes

- **`Runtime`:**
  - `followUps: [FollowUpKey: FollowUpRecord]`, keyed by `(key, slot)`;
  - `followUpIDs: [RequestID: FollowUpKey]`;
  - `dueFollowUps` (ordered ids);
  - `followUpWorkToLaunch` (the gates to start);
  - `closeFollowUps(of:)`, called next to `closeRequests(of:)` in `start`, `end` and `endAll`.
- **`TurnCore`:**
  - no task table: a gate's task is held strongly until it returns, as an effect's is, and a deadline's sleep goes in `deadlineTasks`;
  - `quiescenceWaiters`;
  - `followUpRunScheduled`.

  Every new stored var carries the `@exclusivity(unchecked)` attribute under the core's condition (`scripts/lint-turns.sh`, rule `unchecked-state`).
- **Driver:** `drainProducts` launches the follow-ups' gates (and a gate's deadline task). When `dueFollowUps` isn't empty at the end of `runSegment`, it schedules one `Task { self.runDueFollowUps() }`, as `continueDrain` is scheduled. Each new path starts with an `isEmpty` test, so a machine without follow-ups pays one branch per segment.
- The new step paths are `@inlinable`, and `scripts/check-turns-inlinable.sh` lists their specializations.
- `scopeEnded(key)` doesn't change: follow-ups are closed eagerly, not by the deferred-input clock.

## 9. Docs

- DocC core-concepts article: a "Follow-ups" section after timers, with a compiled example (the after-turn request: arm, join, consume), and a row in the summary table. The `docs/turns/` excerpt check covers it.
- `docs/turns/README.md` and `README.zh-TW.md`: one paragraph each, kept in sync.
- The core plan's rules list (`2026-11-18-swift-state-turns-core.md` §4) isn't edited; this plan is the record of rules 21–24:
  - 21: arm and join;
  - 22: triggers;
  - 23: consume and close;
  - 24: the wait.

## 10. Cost and verification

- **Tests:** `swift test --filter SwiftStateTurnsTests`, debug and release, in the pinned `swift:6.2.4-noble` image. The full `swift test` and E2E run on CI.
- **Mutants**, each expected to fail a named case:
  - join → replace (case 1);
  - `closeFollowUps(of:)` skipped in `start` (case 4);
  - the slot freed after the step instead of before (case 7);
  - the waiter checked mid-step (case 7);
  - `endAll` not waking waiters (case 3/13).
- **`TurnsBench`** gains "arm and run one `.afterBatch` follow-up" and "arm and join". The existing benches are read before and after in that image, release, to check that the added `isEmpty` branches don't show. Instruction counts on the measurement host only if Review asks: no adopter's hot path changes.

## 11. Steps

One PR, in reviewable commits:
1. Values, `Turn` API, `Runtime` records, closing on `end`/`start`/`endAll`;
2. the triggers in the driver (the `.afterBatch` job, the `.afterWork` gates and their deadlines);
3. the quiescence wait and `TurnStats.pendingFollowUps`;
4. the tests (§4) and the generator's new operations;
5. DocC and `docs/turns/`, the bench, the inlinable list.

## 12. Open questions for review

1. Reuse `RequestID` for follow-ups (proposed), or a new `FollowUpID`. Reuse keeps `handleAbandoned`'s signature.
2. Step `handleAbandoned` when a follow-up is closed unrun (proposed, as #702 says), or close it silently. Silent would mean a machine can't release what it counted at arm time.
3. `.afterBatch` as the actor's next job (proposed), or the end of the current batch. A job matches #695's `Task` hop and bounds a chain.
4. The wait public (proposed) or `package`.

Settled in rev 2 (Main):
- `TurnDiagnostic` gets the new case `.staleFollowUp`. A new public enum case needs no maintainer ask; §7 states the switch break.
- **YAGNI on the triggers.** `.held` and `.after(Duration)` are dropped: after L2d neither has a user (§5.6). `.held`'s only user, the latch, is deleted in L2d. The keeper's only delayed follow-up, the join-sync turn, passes `.zero`. `releaseFollowUp` goes with `.held`. `.afterWork` stays: its user, the writer-drain retry, survives L2c and L2d. A later user adds a dropped trigger back as a new case, with its own cases in §4.
