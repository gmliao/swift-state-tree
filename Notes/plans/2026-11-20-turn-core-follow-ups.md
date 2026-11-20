# Turn core: coalesced follow-ups and a quiescence wait (#702)

**Status:** open, rev 4. Plan for review before any code: Code-1 checks the use-case mapping (§5), then Review reviews the plan.

**Rev 4** (Review's NOT GO on rev 3, issue comment 7033041365: 3 must-fix, 5 should, 4 nit; Main's two additions). The shape is unchanged; the rules are made exact:
- §3.3: the gate's lifecycle (launch filter, per-arm checks, the deadline race) and the driver's revalidation between follow-up steps (MF 1, 2).
- §3.5: one check point, `deinit` path dropped, `atMost`, cancellation and `true` defined (MF 3).
- §3.1: follow-up ids are notification ids only (should 1).
- §5: anchors refreshed to b6924b42; the binding's installs and invalidations, the gate's port, the handler's checks, the test counters, the #700 teardown observation (should 2–4).
- §7: the compatibility claim qualified (should 5).
- §8: what a machine without follow-ups pays (Main); §10: a `TurnsBench` before/after of the call and send paths in the PR.
- §4: case 13's release half and case 16 dropped; cases 17–26 added (the gate lifecycle, revalidation, abandon → re-arm, the stale non-nil result, `endAll` waking a registered waiter, and Main's superseded gate at `endAll`).
- §2: four prior-art corrections (nit 1).

**Rev 3** (Code-1's use-case check of rev 2, against #695's head b6924b42): the three mappings and the dropped triggers stand. §5 changes in wording and tests only, not in the core API:
- §5.3: outside requests keep the keeper's counter by reason; only the after-turn arm maps to the machine. `syncTurnNow` validates before it consumes.
- §5.5: a closed follow-up's gate doesn't count. The two #695 tests that rely on a stale retry being counted are rewritten at #700. The wait keeps the waiter table's cancellation rule.
- §4: case 15, a re-arm from the retry's own step.
- §5.4: dropping `.held` assumes L2d lands before #700.

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
| Erlang `gen_statem` ([docs](https://www.erlang.org/doc/apps/stdlib/gen_statem.html)) | `{next_event, …}` inserts an event that is handled next. Generic timeouts `{{timeout, Name}, T, Msg}` keep one timer per name: setting one again under a running name replaces it, `{{timeout, Name}, cancel}` drops it, and they survive state changes. `state_timeout` is the one a state change cancels. `next_event` is handled before events already queued. | One pending item per name, dropped when its owner's state ends (our generation end): `state_timeout`'s lifetime with a generic timeout's naming. We **join** instead of replace (§3.2). `next_event` isn't coalesced. |
| Erlang `gen_server` with `erlang:start_timer/4` | The timer reference comes back in the message; the server compares it with the one in its state. | The ticket pattern the core already owns (rule 4 of the core plan). |
| Akka Typed `TimerScheduler` ([docs](https://doc.akka.io/libraries/akka-core/current/typed/interaction-patterns.html#scheduling-messages-to-self)) | `startSingleTimer(key, msg, delay)`, `isTimerActive(key)`, `cancel(key)`. A new timer under a key replaces the old, and a message from a replaced timer is not delivered. | Keyed, stale-safe, testable "is it armed" check. Replace, not join. |
| Elm ([`Process`](https://package.elm-lang.org/packages/elm/core/latest/Process)) | No coalescing primitive: `Process.sleep` piped into a `Cmd`, with a counter in the model so a stale message is ignored (the debounce packages do this). | Hand-rolled by every program; the core's job is to make it a primitive. |
| RxJS [`throttleTime`](https://rxjs.dev/api/operators/throttleTime), [`debounceTime`](https://rxjs.dev/api/operators/debounceTime), [`exhaustMap`](https://rxjs.dev/api/operators/exhaustMap) | Throttle (leading): first value wins, later ones in the window are dropped. Debounce (trailing): each value restarts the wait. `exhaustMap`: new values are ignored while the inner work runs. | Our join is throttle-leading in kind: the first arm wins (§3.2). It isn't `exhaustMap`, which ignores values until the inner work completes: we free the slot before the step, so the step may arm a successor. Debounce is rejected: a steady stream would never let it run. |
| UIKit [`setNeedsLayout`](https://developer.apple.com/documentation/uikit/uiview/setneedslayout()) / [`layoutIfNeeded`](https://developer.apple.com/documentation/uikit/uiview/layoutifneeded()) | A flag that coalesces requests until the next update cycle. `layoutIfNeeded` does the pending layout now, and the flag clears. | Arm and join = `setNeedsLayout`. Consume, then doing the work in the same step = `layoutIfNeeded`. |
| Vue's scheduler ([`nextTick`](https://vuejs.org/api/general.html#nexttick)) | `queueJob` dedupes while a job is marked queued; the flush runs in a later microtask, and a job queued again during the flush can run in the same flush. | The after-batch trigger runs as the actor's own job, after the batch. Unlike Vue, a follow-up armed by a follow-up's step runs in the next job, never the same one, so a chain can't starve the actor (§3.3). |
| kotlinx.coroutines.test [`advanceUntilIdle`](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-test/kotlinx.coroutines.test/-test-coroutine-scheduler/advance-until-idle.html), Espresso [`IdlingResource`](https://developer.android.com/training/testing/espresso/idling-resource) | `advanceUntilIdle` actively runs queued tasks and advances virtual time; an `IdlingResource` reports when the app is idle. Neither sleeps. | The quiescence wait (§3.5) is the idling-resource kind: it only waits, and the clock is the test's to drive. |

What none of them has, and the core adds: the pending item belongs to a key's **generation**. Ending or superseding the key closes the item unrun, in the same step, so an item armed under an old binding can neither run nor block the new binding's. That is the #695 bug class.

## 3. Design

### 3.1 Identity: a key and a slot

A follow-up is named by `(key, slot)`. The key gives it its owner and lifetime, as for a request. The slot tells a key's follow-ups apart: the keeper has three under one binding key (§5). `FollowUpSlot` is a new associated type with the default `Never`, so a machine that declares none is unchanged.

Each follow-up also gets a `RequestID` from the requests' counter. `handleAbandoned` can then name it, and no new identity type or `Abandonment` case is needed. Adding a case to the public `Abandonment` enum would break adopters' exhaustive switches.

**A follow-up's id is a notification id only.** It names the follow-up in `FollowUpArming` and `handleAbandoned`, and nowhere else:
- `cancel(id)` touches open requests only; on a follow-up's id it does nothing (to drop a follow-up, consume it);
- `reply(after: id)` publishes at once for an id that isn't an open request, so a follow-up's id gives no ordering;
- a gate's result never goes through request completion: neither `complete` nor `handleLateResult` (whose stale path, `stepStale`, is for closed requests) sees it. It enters through its own entry (§3.3).

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

**The gate's lifecycle (`.afterWork`).** Each rule names the arm by its id, so two gates for one slot (after consume-and-arm, or case 15's re-arm) never act on each other's follow-up.
- **Launch is filtered.** The step stages the gate; `drainProducts` launches it only if that arm's follow-up is still pending. A follow-up armed and then consumed, ended or superseded in the same step starts no gate. This is the timers' rule (a staged timer is checked against its live record), not the request effects' (a staged effect launches even if its request closed in that step).
- **A return or a deadline checks its own arm:** the core's incarnation first (as `complete` does), then that the arm's id is still pending with its gate not yet returned. A's gate can neither step nor close B's follow-up in the same slot.
- **The deadline and a consume (or a close) in one actor turn:** each is a separate actor entry, and whichever is serviced first wins, as for a request (`deadlineFired` checks `rt.open`).
  - Consume first: the follow-up is gone. The deadline task is cancelled in the same segment's sweep, and if it was already waking it finds nothing pending and reports `.staleDeadline`.
  - Deadline first: the follow-up closes with `.deadline` and `handleAbandoned` steps; the consume returns nil.
  - The gate returning first: the deadline task is cancelled, and a late wake reports `.staleDeadline`.
- **Shared `deadlineTasks`.** A gate's deadline lives in the requests' table. The cancellation sweep, which today cancels any id missing from `rt.open`, keeps an id whose follow-up is pending with its gate still out, and cancels it once the gate has returned or the follow-up is gone.
- **Debug accounting.** Gate launches count in rule 20's accounting of launched work, as effects do.

**How a trigger enters the driver, and the revalidation between steps.**
- **`.afterWork`:** the gate's return is an actor entry. If its arm is pending, the arm becomes due. Then the gate's own non-nil result steps (a control input, as a `run`'s result), whether or not the arm was pending, and its products drain through the normal between-step drain. The due arm steps after that, from the driver's loop, which re-checks right before the step that the arm is still pending: the result's step may have consumed it, superseded its key or called `endAll`.
- **`.afterBatch`:** the job's eligible set is the arms that were due when the job began, as a snapshot of ids in arm order. Each keeps its record until it is dispatched, and each is re-checked right before its step, after the step before it and that step's drain. If the first due input calls `endAll`, the second is closed by it (`handleAbandoned`) and doesn't step (invariant 18). Arms made by those steps go to the next job.
- **A stale gate's non-nil result** still steps (it is a `run`-style result, rule 17), and may arm new work, also after a quiescence wait already returned for the closed follow-up.

### 3.4 Consume and close

- **`consumeFollowUp(slot, of: key) -> M.Input?`.** Retires the pending follow-up without stepping it and returns its input; nil if none is pending. No `handleAbandoned` follows: the consumer already knows. A later arm in the same step makes a new one. A gate task still in flight finds the follow-up gone when it returns, and the follow-up's input doesn't step. A gate's own result still steps, and a gate deadline still armed is cancelled (§3.3).
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

- **What counts:** a follow-up armed and not yet stepped, consumed or closed; an open request; an armed timer. The count can be restricted to one key. The default is follow-ups only: a periodic timer is never quiet. A closed follow-up isn't counted, also while its gate is still out (§5.5). An empty `kinds` counts nothing, so its wait returns at once.
- **The check point.** One epilogue, at the end of `runSegment`, after the batch has drained. Every mutation that changes a count marks the runtime dirty (arm, consume, close, a gate's return, a request opening or closing, a timer arming or dropping), and every entry that can make one runs `runSegment` when dirty: `submit` and `query` included, so a consume in a query's answer step reaches the check. The check and the registration run in one actor-isolated segment with no suspension between them. A step that retires a follow-up and arms its successor is one segment, so a waiter never sees the gap between them, and a chain keeps it waiting until the chain ends (#702's last boundary case).
- **It never hangs on an ended core.** `endAll` closes every request, follow-up and timer, and the epilogue of its segment wakes every waiter whose kinds are then empty. A request whose worker hasn't returned (`.untilWorkerReturns`) is closed, so it doesn't count. `endAll` and cancellation are the only ways a wait ends other than its count. There is no release path: a task suspended in `waitForQuiescence` is inside an actor method and retains the actor (a launched gate retains it too), so the actor can't be released while a waiter exists. Rev 3's `deinit` path is dropped; `LifetimeTests` covers release as today.
- **What `true` means:** at some check point, the count of `kinds` was at most `atMost`. It isn't a claim about the state on return: other work may have armed since. It returns true at once if the count is already there.
- **`atMost` must not be negative.** A negative value stops the process (`fatalError`, so the message prints in release builds too): no count can reach it, not even an ended core's zero.
- **Cancellation.** A cancelled waiting task returns false once the cancel handler's hop to the actor is serviced, and its entry is removed (as `callerCancelled` removes a caller). The rule is the one #695's waiter table keeps (b6924b42, from #692):
  - waiters are keyed by id, so a cancellation removes its own entry and no other;
  - the registration re-checks `Task.isCancelled` and the count inside the continuation's closure, so a cancellation that lands before the entry exists can't leave it waiting;
  - the entry is resumed once, by whichever is serviced first: a check point that finds the count reached (true), or the cancel hop (false). A cancel that races a satisfying check point loses if the check point runs first, and the task returns true.
  Tests bound the wait with `withinHangBound`, as today.
- **Cost (#621 item 4):** the waiters are a table scanned only when it isn't empty, so a core with no waiter pays one `isEmpty` test per segment. The count is recomputed per check (the follow-up table's size, or `open`/`timers` filtered by key), which is fine for tests.

`TurnStats` gains `pendingFollowUps` (a new stored property with a default).

## 4. Boundary cases (tests)

In `Tests/SwiftStateTurnsTests/FollowUpTests.swift`, on the test clock, with hold points where order matters and no sleeps. #702's cases first:
1. Arm, arm (`.joined`, the same id), run: one step, with the first input.
2. Arm, consume (the input is returned, and no step happens), arm again: `.armed` with a new id, then it runs.
3. Arm, then `end(key)`: closed unrun, `handleAbandoned(id, .keyEnded)`, and the wait wakes.
4. Arm under A, then `start` makes B current: A's is closed (`handleAbandoned`), B's arms freely (`.armed`) and runs. In the same step, an arm before the `start` is closed and one after it stands.
5. Arm during and after `endAll`: `.refused`, counted.
6. The wait with nothing armed returns at once (true).
7. The wait across a chain (a follow-up that arms its successor twice): it stays waiting until the third step, and each step is in a new batch. The clock is lazy, so each step reads `turn.now`, and it is read three times.

Then:

8. `.afterWork`: it steps after the gate's `perform` returns, not before (the gate held at a `TestGate`). A gate result that isn't nil steps first. The deadline closes it with `.deadline`.
9. `.afterWork` closed while its gate runs (a consume, an `end`, a supersede): the gate's return steps nothing for it and reports `.staleFollowUp`, and the wait woke at the close, not at the return.
10. `.afterBatch`: it doesn't step inside the arming batch; it steps in the next job, with a fresh `now`.
11. A follow-up's input steps with its hold key held and after `close`: it is a control input.
12. Two slots under one key are independent. Two follow-ups due together step in arm order.
13. The wait: per key, `atMost`, `kinds` (requests and timers), and a cancelled waiter (it returns false, and its entry is gone).
14. Generated orders (`GeneratedOrderTests`): add arm, consume and end operations to the generator. Check invariants 18 to 20 (§6) after each step.
15. A re-arm from the follow-up's own step: an `.afterWork` follow-up's step finds the writer held again and arms the same slot. The slot was freed before the step, so the arm is `.armed` with a new id, not `.joined` with the one stepping. The wait stays busy across the hand-over. On the keeper this is the drain retry whose phase is deferred again.
16. Dropped in rev 4 (an exit test; see below the list). The number is kept so the cases match the test names.
17. A superseded binding's `.afterWork` gate still waiting when `endAll` runs (Main, from #695's review): its follow-up is closed at once and uncounted (`pendingWork` is zero and the wait returns before the gate does), and its late return steps nothing.
18. Armed and closed (an `end`, a consume) in one step, before launch: no gate starts.
19. A consume and the gate's deadline, in both orders: whichever is serviced first wins, and the other finds nothing (`.staleDeadline`, or a consume that returns nil).
20. A's stale gate returning while B is pending in the same slot (after consume and re-arm): it neither steps nor closes B.
21. A `handleAbandoned` that arms the same key: after a plain `end`, `.refused` (the key isn't live); after a supersede, `.armed` under the new generation, and it runs; after `endAll`, `.refused` and counted.
22. A follow-up whose own step supersedes its key and then arms: the arm is new, under the new generation, and runs.
23. Two `.afterBatch` follow-ups due together, the first's step calls `endAll`: the second is closed (`handleAbandoned`) and doesn't step.
24. A gate's non-nil result whose step ends the key: the follow-up is closed, not stepped.
25. A stale gate's non-nil result still steps, and arms work after a wait already returned for the closed follow-up (rule 17).
26. `endAll` wakes a waiter registered before it.

Case 16, rev 3's exit test for `followUp` outside a step, is dropped: a `Turn` can't be obtained outside a step (`read` lends the machine only), so the restriction is a compile-time one, and the core's tests don't probe crashes.

## 5. The LandKeeper follow-ups and the waiters

After #700, the keeper's machine has a key `.syncBinding`, started on every bind or rebind (today `syncBinding.rebind()` in `noteTransportBound` and `bindSyncRequester`). Its slots are `.drainRetry`, `.joinSync` and `.afterTurn`. The fourth hand-rolled slot, the latch, is deleted in L2d, before #700 (§5.4). The port isn't plain data, so it stays with the actor: the binding's generation names it, and the actor holds the current binding's port. Line numbers are #695's head (b6924b42) `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.

**The generation follows every installation and invalidation of the binding.** Today `syncBinding.rebind()` runs in `noteTransportBound` (:5240, from `setTransport` with a transport, :475) and in `bindSyncRequester` (:5250, the first requester of a keeper never attached). At #700 each of these is a `start(.syncBinding)` in a step:
- the init's transport and every `setTransport(_:)` with a transport (a bind or a rebind);
- the first requester's bind;
- `setTransport(nil)` (a detach): today it changes eligibility (`transport` is nil, `hasHeldTransport` stays true, so `bindSyncRequester` refuses) without a new ticket. On the core it is an `end(.syncBinding)`, so the detached binding's follow-ups close at once rather than being refused when they run;
- the teardown: `endAll`.

**The gate's effect carries its port.** The binding's port isn't plain data, so the effect is `.waitForWriterDrain(port)` with the port the follow-up was armed under (a `Sendable` box held by the actor, not the machine), and `perform` waits on that port. An effect that read the actor's current port when `perform` began would make A's gate wait on B's writer.

**The handler's checks.** A follow-up's step under the current generation still checks what the generation doesn't: `mode == .live`, `failure == nil`, `!isDraining`, and `port.runsSyncPhaseInTurn(of:)` (the shared executor, so its `assumeIsolated` is valid), in that order, as `acceptsSyncTurn` (:5268) does today. The join-sync step re-checks `transportHasJoinsAwaitingSync` after those.

### 5.1 The writer-drain retry (`retrySyncOnlyTurnAfterWriterDrain`, :5151)

| Today | On the core |
|---|---|
| `guard inTurnDrainRetryBinding != syncBinding.current` (at most one per binding) | `followUp(.syncOnlyTurn, .drainRetry, of: .syncBinding, .afterWork(.waitForWriterDrain(port), deadline: nil))`; a second arm joins |
| `Task { await transport.waitForWriterDrainForInTurnSync(); await runRetriedSyncOnlyTurn }` | The gate effect's `perform` awaits that port's drain (:5159 today) and returns nil |
| `runRetriedSyncOnlyTurn` clears the mark only if it is its own binding's | The core frees the slot before the step. A superseded binding's follow-up is closed at `start` and never runs |
| `acceptsSyncTurn(through:)`, the binding check | Not needed: the generation is current by construction. `mode`, `failure` and `isDraining` are still the handler's checks |
| "an invalidated retry still retires" (the wait returns at teardown) | It is closed at the supersede or `endAll`. The gate's late return steps nothing |

### 5.2 The join-sync turn (`scheduleJoinSyncTurn(after:)`, :5179)

| Today | On the core |
|---|---|
| At most one per binding (`joinSyncTurnBinding`) | `followUp(.joinSyncTurn, .joinSync, of: .syncBinding, .afterBatch)`; a second arm joins |
| `after delay`, with `safeTaskSleep`. The only caller (:4730) passes `.zero`, and L2 keeps it so (L2 plan §3.2) | `.afterBatch`. The `delay` parameter goes; a delay would need `.after(Duration)`, dropped in rev 2 (§3.3) |
| The run re-checks `!isDraining`, `transportHasJoinsAwaitingSync` and the binding | The handler re-checks the first two; the binding is the generation |
| `joinSyncTurnsForTesting += 1` (:5198) at the accepted job, before the phase | The same place: in the follow-up's step, after its checks pass, before the phase |

### 5.3 The after-turn request (`requestSyncTurnAfterThisTurn`, :5322)

| Today | On the core |
|---|---|
| One pending. The same binding joins; a newer binding replaces it | `followUp(.syncOnlyTurn, .afterTurn, of: .syncBinding, .afterBatch)`. A join is `.joined`. A newer binding's `start` closed the old one, so its arm is `.armed` |
| `syncTurnNow` (an outside request through the same port) consumes it, then runs its phase, which may arm a successor | `syncTurnNow`'s step: `turn.consumeFollowUp(.afterTurn, of: .syncBinding)`, then its phase. A port that isn't the binding's is refused before this (`acceptsSyncTurn`), so "the same port" is "the current generation" |
| `runPendingSyncTurnAfterTurn`: `guard let followUp = pendingSyncTurnAfterTurn` (consumed meanwhile → retired) | The core doesn't step a consumed follow-up |
| `requestedSyncTurnsForTesting[reason]`: `syncTurnNow` (:5306) bumps it for every outside request (`.resume`, `.lagTimer`, `syncNow`, the repair) before `acceptsSyncTurn`, so it counts refused requests too. Only `.keptEvents` is bumped at arm time, by the after-turn request (:5323), for every attempt, a join included | The outside requests' counts stay a keeper counter by reason, bumped where they are today, refused ones included (the freeze test asserts `[.resume]` + 1). Only the after-turn arm's `.keptEvents` count moves to the machine, bumped in the step that arms it, before the arming outcome, so a join counts as today |
| `syncTurnNow`'s order: `acceptsSyncTurn` (the port and the binding ticket), then the consume, then the phase. A stale-ticket lag or repair request returns `.skipped` | The same order in its step. The generation check comes before `consumeFollowUp`: a request whose ticket names an older binding returns `.skipped` and consumes nothing. Otherwise a stale lag callback would swallow the current binding's kept-events turn. A §4-style keeper test at #700: a stale lag request with an after-turn pending leaves it pending, and it steps |

### 5.4 The latch's rerun: deleted in L2d, not mapped

L2d deletes `beginSync`/`endSync`, `isSyncing` and the latch `syncOnlyTurnAfterLegacyCycle` with its reads (L2 plan §3.6). L2 is ordered before #700, so the latch never reaches `TurnCore`. Rev 1 mapped it to a `.held` follow-up released by `endSync`'s step. `.held` had no other user and is dropped (§3.3). Until L2d, #695's interim latch stays as it is.

**This assumes L2d lands before #700**, as the L2 plan orders it. If #700 were to come first, the latch would need a trigger again, `.held` or an equivalent, added back as a new case with its cases in §4.

### 5.5 The waits

| Today | On the core |
|---|---|
| `requestedSyncWork` (begin/end count) | `pendingWork(.followUps, of: .syncBinding)` |
| `waitForRequestedSyncTurnsForTesting()` | `waitForQuiescence(.followUps, of: .syncBinding)` |
| `waitForRequestedSyncTurnsForTesting(atMost:)` | `waitForQuiescence(.followUps, of: .syncBinding, atMost: n)` |
| `hasRequestedSyncWorkForTesting` | `pendingWork(.followUps, of: .syncBinding) > 0` |
| The adapter's `waitForBackgroundSyncsForTesting` and the outbound-idle wait (`TransportAdapter.swift:3206`, :3221, :3225) | Unchanged: they call the keeper's waits, which forward |
| `inTurnDrainRetryBindingForTesting` (:5346) | `followUpPending` is `Turn`-only, and `core.read` lends the machine only, so the test reads it through an `answer` (a query whose step returns `followUpPending(.drainRetry, of: .syncBinding)`), or through a read-only runtime accessor on the core if one is added for tests |

The bug #695's review found, replayed on the core: A's retry is pending, `setTransport(B)` starts `.syncBinding` again, and A's retry is closed in that step. B's deferred phase arms `.drainRetry` and gets `.armed`, not `.joined`. Case 4 of §4 is this sequence on a model machine.

**What the wait counts for a superseded binding.**
- (a) A closed follow-up isn't counted, also while its `.afterWork` gate is still in flight. `pendingWork` and `waitForQuiescence` count follow-ups that are armed and neither stepped, consumed nor closed; a gate is the follow-up's trigger, not work of its own. The gate's late return steps nothing for it (it reports `.staleFollowUp`) and moves no count.
- (b) That differs from today. A's stale drain retry stays counted until its writer wait returns, and two #695 tests rely on that: `olderBindingsRetryDoesNotBlockTheCurrentOne` and `teardownEndsAnArmedRetry` (`TransportAdapterRequestedSyncTurnTests.swift:134`, :218). At #700 they are rewritten on the core's terms:
  - the first checks that B's retry arms (`.armed`) while A's gate still waits, and that A's late gate return steps nothing, with a step counter on the machine;
  - the second checks the same under `endAll`: the retry is closed, the wait returns at once, and the gate's return after it steps nothing.
- (c) Slot quiescence alone doesn't prove the teardown released the writer. A closed follow-up isn't counted, but its gate may still be stuck on A's writer, so "the wait returns at once" would pass with a stranded gate. Today `teardownEndsAnArmedRetry` (:218) proves that the teardown releases the real writer wait while the send is still blocked. The rewrite keeps that as its own observation: the gate returned after the teardown (`.staleFollowUp` reported, or a gate-return counter on the keeper).
- (d) The rebind test (`olderBindingsRetryDoesNotBlockTheCurrentOne`, :134) keeps its check that B delivers stamp 2 while A's writer is held. `.armed` alone proves admission, not delivery.
- (e) A stale gate's non-nil result can still arm work after the wait returned (rule 17; §4 case 25). The drain gate returns nil, so on the keeper this doesn't arise; a keeper gate that returns a result would need its own case.

**One ordering change, intended.** When one commit arms both the join-sync turn and the kept-events after-turn request, #695 runs them as two `Task`s, in whichever order the executor takes them. The common `.afterBatch` job runs them in arm order. Both orders are valid today; the core's is deterministic.

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
20. A quiescence waiter returns true when, at the check point that woke it, more than `atMost` of its kinds were pending; or it is still waiting after a check point at which at most `atMost` were pending.

## 7. Public API

Additive. Two qualifications and one new enum case, stated below; nothing existing changes signature or behaviour.

- `TurnMachine.FollowUpSlot: Hashable & Sendable`, an associated type with default `Never`. A defaulted associated type keeps existing conformances, with one exception: a conformer that already has a nested type or typealias named `FollowUpSlot` makes it the witness, and it must then be `Hashable & Sendable`. No conformer in this repository has one.
- `public enum FollowUpTrigger<Effect: Sendable>: Sendable { case afterBatch, afterWork(Effect, deadline: Duration?) }`.
- `public enum FollowUpArming: Sendable, Equatable { case armed(RequestID), joined(RequestID), refused }`.
- On `Turn`:
  - `followUp(_:_:of:_:) -> FollowUpArming` (`@discardableResult`);
  - `consumeFollowUp(_:of:) -> M.Input?` (`@discardableResult`);
  - `followUpPending(_:of:) -> RequestID?`.
- On `TurnActor` (extension): `pendingWork(_:of:) -> Int` and `waitForQuiescence(_:of:atMost:) async -> Bool`.
- `public struct TurnWork: OptionSet, Sendable` with `RawValue == UInt8` and `followUps`, `requests` and `timers`. An empty mask counts nothing (§3.5).
- `TurnStats.pendingFollowUps: Int`, a stored property with a default. `TurnStats()` is an explicit public init, so it keeps compiling. `TurnStats` declares `Equatable` and synthesizes `==`, so two stats now also compare `pendingFollowUps`: a test that compares a whole `TurnStats` against an expected value built field by field sees the new field at its default, zero, which a core with no follow-ups also reports.
- **`TurnDiagnostic.staleFollowUp`: a new case.** A gate returned for a follow-up already consumed or closed. It breaks source for an adopter that switches over `TurnDiagnostic` without a `default`: such a switch needs the new case, or a `default`. The enum is public, but its only producer is the `package` hook `onDiagnostic`, so in practice this package's tests; the known exhaustive switch is `Tests/SwiftStateTurnsTests/Support/Fixture.swift:85–100`, which gains the case. Reusing `.staleTimer` (rev 1) would have mislabelled it.

The wait is public, not `package`: adopters outside this package test their machines too. If Review prefers `package` for the first release, the switch costs nothing.

## 8. Implementation notes

- **`Runtime`:**
  - `followUps: [FollowUpKey: FollowUpRecord]`, keyed by `(key, slot)`; a record holds the arm's id, its input, whether its gate is still out, and whether it has a deadline;
  - `followUpIDs: [RequestID: FollowUpKey]`;
  - `dueFollowUps` (ids in arm order);
  - `followUpGates` (the gates staged for launch);
  - `closeFollowUps(of:)`, called next to `closeRequests(of:)` in `start`, `end` and `endAll`; it returns at once when the table is empty.
- **`TurnCore`:**
  - no task table: a gate's task is held strongly until it returns, as an effect's is, and a deadline's sleep goes in `deadlineTasks`;
  - `quiescenceWaiters` (by id) and its id counter;
  - `followUpJobScheduled`, and the job's snapshot of due ids.

  Every new stored var carries the `@exclusivity(unchecked)` attribute under the core's condition (`scripts/lint-turns.sh`, rule `unchecked-state`). The restrictions that rule documents for `M.Key`'s `==` and `hash(into:)` (they run inside mutations of `rt`, so they must not reach back into the core) extend to `M.FollowUpSlot`'s, which run inside mutations of the follow-up table.
- **Driver:**
  - `drainProducts` launches the staged gates, filtered against their pending arms, and a gate's deadline task.
  - The gate's return and the `.afterBatch` job enter through their own actor entries (`gateReturned`, `continueFollowUps`), each starting with the incarnation check where a task carries one.
  - `runSegment`'s loop steps the due ids after the drain, the abandoned, the queued and the releasable, re-checking each.
  - When `dueFollowUps` isn't empty at the end of `runSegment`, it schedules one `Task { self.continueFollowUps() }`, as `continueDrain` is scheduled.
  - The quiescence check is the last thing in `runSegment` (§3.5).
- **What a machine without follow-ups pays (`FollowUpSlot == Never`).** It can't arm one, so every table stays empty and nothing marks the runtime dirty on the follow-ups' account. Per segment it pays four empty-collection tests:
  - the due-ids queue in the loop;
  - `dueFollowUps` at the end;
  - the staged gates in `drainProducts`;
  - the waiter table in the check point.

  Per `start`, `end` and `endAll`, it pays one more: `closeFollowUps(of:)` on an empty table. A deadline sweep, which runs only when a request with a deadline closed, makes one lookup in the empty `followUpIDs` per remaining deadline task. No allocation and no extra dictionary hashing reach the `call` and `send` paths. §10 measures this.
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
  - the slot freed after the step instead of before (cases 7 and 15);
  - the waiter checked mid-step (case 7);
  - `endAll` not waking waiters (case 26, a waiter registered before it);
  - launch not filtered (case 18);
  - a gate's return or deadline matched by slot instead of by arm id (cases 19 and 20);
  - the due ids not re-checked before each step (cases 23 and 24);
  - the check point only on dirty `submit`, with a consume in a query's answer not marking dirty (a case: a query whose answer step consumes the last follow-up wakes a registered waiter).
- **`TurnsBench`** gains "arm and run one `.afterBatch` follow-up" and "arm and join".
- **The cost to machines without follow-ups, measured (Main; #621).** The PR body carries a `TurnsBench` before/after of the existing `call` and `send` paths, in instructions, both sides built in release from the pinned `swift:6.2.4-noble` image (base `main` and the PR head, rebuilt in one container, `swift --version` recorded). The expectation from §8 is a few instructions per segment; a larger change is a finding, not noise, and blocks the PR until explained, so #621's numbers don't regress silently.

## 11. Steps

One PR, in reviewable commits:
1. Values, `Turn` API, `Runtime` records, closing on `end`/`start`/`endAll`;
2. the triggers in the driver (the `.afterBatch` job, the `.afterWork` gates, their deadlines, the launch filter and the revalidation);
3. the quiescence wait and `TurnStats.pendingFollowUps`;
4. the tests (§4) and the generator's new operations;
5. DocC and `docs/turns/`, the bench, the inlinable list.

## 12. Open questions for review

1. Reuse `RequestID` for follow-ups (proposed), or a new `FollowUpID`. Reuse keeps `handleAbandoned`'s signature.
2. Step `handleAbandoned` when a follow-up is closed unrun (proposed, as #702 says), or close it silently. Silent would mean a machine can't release what it counted at arm time.
3. `.afterBatch` as the actor's next job (proposed), or the end of the current batch. A job matches #695's `Task` hop and bounds a chain.
4. The wait public (proposed) or `package`.

Settled in rev 4 (Review on rev 3): 1–4 as proposed; a public wait is fine with no outside adopters yet.

Settled in rev 2 (Main):
- `TurnDiagnostic` gets the new case `.staleFollowUp`. A new public enum case needs no maintainer ask; §7 states the switch break.
- **YAGNI on the triggers.** `.held` and `.after(Duration)` are dropped: after L2d neither has a user (§5.6). `.held`'s only user, the latch, is deleted in L2d. The keeper's only delayed follow-up, the join-sync turn, passes `.zero`. `releaseFollowUp` goes with `.held`. `.afterWork` stays: its user, the writer-drain retry, survives L2c and L2d. A later user adds a dropped trigger back as a new case, with its own cases in §4.
