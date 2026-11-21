# Turn core: a nonisolated post lane that the next step takes first (#725)

**Status:** rev 1, plan only, for review. No code until Review's GO.

## 1. The problem

`TurnActor`'s entries (`send`, `sendAndWait`, an effect's result, a timer) are actor-isolated. A collaborator on another actor that has to tell the machine something hops onto the turn actor and awaits. Until the hop lands, the turn actor can run a step that should already have seen the report: the step's isolation is free to run whatever job comes first.

#696/#704's plan (`2026-11-21-closed-gate-replies-and-pending-failure.md` §2.2–2.3) meets this on the keeper. The transport adapter closes the land's output gate on a failure outside a turn. Before the queued `.landFailure` input arrives, the keeper can still run a sync phase, either behind the hop or behind a queued item. #732 closes the window with a keeper-specific box, `LandFailureMailbox`. It is set-once, lock-protected and `nonisolated`, and the keeper reads it at each step boundary (`applyPendingTransportFailure`, from `finishApply`, `runSyncOnlyTurn` and `runTurnOutputs`). The awaited `submitLandFailure` stays only to wake a keeper that has no turn due.

When LandKeeper moves onto `TurnCore` (#700), that box should be a capability of the core rather than a side channel next to it. This plan specifies that capability.

## 2. Prior art

- **Akka (classic) mailboxes** keep system messages (supervision, termination, watch) in a separate queue next to the user mailbox. `Mailbox.run` processes all system messages first, then user messages, and checks the system queue again after each user message, so a stop or a failure is seen before the next user message. An enqueue sets a "scheduled" flag with a compare-and-set, and only the enqueue that sets it schedules the mailbox, which avoids both a lost wakeup and a double run. This is the shape proposed here: a second lane, taken before each step, with a scheduled flag cleared in the same critical section as the take.
- **Erlang/OTP 28 priority messages ([EEP 76](https://www.erlang.org/eeps/eep-0076), [OTP 28 highlights](https://www.erlang.org/blog/highlights-otp-28/))**: a receiver opts in with `alias([priority])`, and messages a sender marks `priority` through that alias go ahead of ordinary messages in the queue. Selected exit and monitor signals can be priority messages too. Two points carry over: the receiver opts in per alias, and the lane is meant for a few control messages, not for traffic.
- **Swift actors** have no second lane. Task priority changes scheduling order but promises nothing about which job runs first, so an awaited call can't promise "before your next step".
- **The repository's own precedents:**
  - the keeper's `isDraining`, and #732's `LandFailureMailbox`: a lock-protected box any isolation reads without an await;
  - #719's waiter registration (`2026-11-21-a-closure-that-captures-only-actor-state-runs-off-the-actor.md`): a check-then-register against state another segment settles must happen in one isolated segment;
  - the budget-break lesson (`2026-11-20-a-budget-break-strands-the-work-kinds-after-it.md`): a new work kind in the driver's loop has to say where it sits against every budget and exit;
  - the feature-path cost lesson (`2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md`): a feature keyed on an associated type with a `Never` default gets a static gate, and machines that don't use it pay nothing.

## 3. Design

### 3.1 What the lane carries: a `Report`, not any input

A machine opts in with a new associated type, `associatedtype Report: Sendable = Never`, and a handler, `mutating func handle(report: Report, turn: inout Turn<Self>)`. Its default is unreachable for `Never`.

A report is not an `M.Input`, for three reasons:
- **It steps as a control input.** Holds, `close`, the queue limit and withdrawal don't apply, as for a timer's input or a follow-up. A terminal report must reach a closed core, which an `M.Input` with a `.normal` policy wouldn't.
- **It has no caller.** A post doesn't wait, so there is no reply and no `TurnError`. A general input lane would be a second, unordered submit path beside `send`, and the "inputs from one connection keep their order" rule (the order section of `docs/turns/README.md`) would have to name both.
- **It stays small.** The lane is for the few things a collaborator must report before the machine's next step: a failure found outside a turn, or a stop from a supervisor. A type of its own keeps it that way, and it lets the lint and the docs tell lane traffic from ordinary inputs.

**Rejected: a set-once box only.** It covers #732, but a second report kind (a supervisor's stop beside a transport failure) would need a second box and a second read point. The lane is a bounded FIFO instead, and set-once is what it does at capacity 1 (§3.5).

### 3.2 Where the lane lives

`TurnLane<Report>` is a `final class`, `Sendable`, lock-protected, with:
- the posted reports, in post order;
- a `wakePending` flag;
- a capacity.

The adopter's actor declares it as a stored `nonisolated let lane = TurnLane<M.Report>(capacity: …)`. `TurnActor` gains `nonisolated var lane: TurnLane<M.Report>? { get }`, with a default of `nil` in an extension, so a machine with `Report == Never` declares nothing. The lint that checks `core` is a stored `let` checks `lane` the same way.

`TurnCore<M>.usesLane` is `M.Report.self != Never.self`, a constant once the core is specialized, as `usesFollowUps` is. Every lane path in the driver checks it first, so on a machine without reports it folds away.

### 3.3 Posting and the wakeup

`nonisolated func post(_ report: M.Report) -> Bool` on `TurnActor`:
1. Under the lane's lock, it appends the report; a lane at capacity refuses it (§3.5). If `wakePending` is false, it sets it and remembers to schedule.
2. Outside the lock, if it set the flag, it schedules one wake job: `Task { await self.laneWoke() }`.

`laneWoke()` is an ordinary entry: `beginEntry()`, then a segment if the lane holds reports.

**The take.** The driver takes the lane in one critical section: it moves every posted report out and clears `wakePending`.

**No lost wakeup.** Every post is in one of two cases:
- It lands before a take. That take steps it.
- It lands after a take. The take cleared `wakePending`, so this post sets the flag again and schedules a new wake.

The flag and the reports change under one lock, so no post can find the flag set by a wake that has already taken. A wake job that finds the lane empty (an entry took it first) does nothing and counts `counters.emptyLaneWakes`.

**A post from inside a step.** The machine, or a collaborator it calls synchronously, may post. The report goes to the lane, and the driver's next check takes it in this segment, after this step's products drain. The wake it schedules then finds the lane empty.

**Rejected: wakeup by the poster's awaited submit.** That is #732's current fallback. It makes every poster await, and the lane would still depend on a second path for liveness. The lane wakes itself, and #700 drops the awaited submit (§4).

### 3.4 Order: the lane is taken before every step

**The rule.** Before each step the driver makes, it takes the lane and steps the reports first, in post order, each one's products drained before the next. That covers:
- each step of a segment's loop;
- the direct step of an entry: `submit`'s `admit`, `query`'s answer, an effect's result, a timer's input, a gate's return.

This is Akka's "system messages before each message": a post that lands at any point is seen before the next step that starts after it.

- **In `runSegment`.** The take sits right after `drainProducts()`, before abandonments, queued inputs, releases and follow-ups. So the order is: products, lane, abandoned, queued, releases (capped), follow-ups.
  - Reports aren't parked inputs, so `maxReleasesPerBatch` doesn't bound them. They are bounded by the lane's capacity, as follow-ups are bounded by their arms.
  - A capped segment still takes the lane: the budget-break lesson's rule.
- **At an entry that steps directly.** If `usesLane`, the entry checks the lane before its own step. With reports posted, it steps them first, then its own input; then it goes on as today.
  - The common case, an empty lane, costs one locked read of a count per step on a machine with reports, and nothing on one without (§3.8).
  - With reports posted, `submit` could instead queue its own input and run a segment. That moves a non-control input behind the reports, as the rule requires, but it also changes where `admit` runs. The direct form is simpler to reason about. Q2.
- **Against the queued batch.** Reports go ahead of everything not yet stepped when the take runs: queued sends, parked releases, due follow-ups. They never interrupt a step. Two reports keep their post order. A report and an ordinary input from two different tasks have no order beyond "taken before the next step that starts after the post", the same as Swift's order between calls from different tasks.

### 3.5 Capacity and set-once

`TurnLane(capacity: n)`. A post to a full lane returns `false` and isn't stored. The lane counts the refusal under its lock, because a nonisolated post can't touch the core, and the next take adds it to `counters.refusedReports`.
- **Capacity 1 is set-once.** The first report wins until a step takes it, which is #732's rule.
- **First wins, not last.** For terminal reports the first cause matters, and a later one is a consequence.
- **Default capacity: 8.** It is small on purpose. A machine that needs more says so.

A report that a step has taken is gone, so after a take a lane with capacity 1 accepts a new post. A machine that must keep the first report for its lifetime (the keeper's `failLand` keeps the first cause) does that in its own state. The lane doesn't need to.

### 3.6 Taking the lane inside a step: `turn.takeReports()`

#732 reads its box in the middle of a turn: after the apply, before anything of the turn goes out. A report posted on another thread while the step runs must still stop that step's outputs. The pre-step take of §3.4 can't do that, because the step has already begun.

So a step may take the lane itself. `turn.takeReports() -> [M.Report]` takes the lane in the same critical section as the driver's take, and returns the reports in post order. The step then handles them before it emits anything. They are not stepped again.

This is the keeper's `finishApply` → `applyPendingTransportFailure` in core terms (§4). Without the call, a report that lands during a step is taken before the next step, which is enough for any machine that doesn't need the mid-step read.

### 3.7 `close`, `endAll`, a replaced core, re-evaluation

- **`close` and `endAll`.** Reports step as control inputs through `close`, and after `endAll`, as a timer's input does. A machine that wants to ignore reports once ended does so in its handler.
- **A replaced core.** The lane belongs to the actor, not to the core. A report taken after a core is replaced steps into the new core. Whether a report should carry the poster's incarnation, and be dropped as `.foreignCompletion` by a core that didn't exist when it was posted, is Q3. The keeper doesn't replace its core, so #700 doesn't need it.
- **Re-evaluation.** Replay has no transport and no poster. A recorded report reaches the machine from the record, not from the lane (§3.9).

### 3.8 Cost

- **Without reports (`Report == Never`).** Every lane path is behind `usesLane`, so `runSegment`, the entries and the wake fold away. The §10 cells of the follow-ups plan (`2026-11-20-turn-core-follow-ups.md`: `emit`, `call`, `idle`, on the bench's machine, which declares neither follow-ups nor reports) must not move. They are measured with that plan's procedure (`perf stat -e instructions:u`, n minus n = 0, five runs per side, threshold max(0.5 %, 3 × spread)), while holding the measurement lock.
- **With reports, on an empty lane.** One lane read per step.
  - `Synchronization.Atomic` would make that read a plain load, but it needs macOS 15, and the package targets macOS 14 (#711 met the same limit with `Mutex`).
  - So the read is `NSLock` around an `isEmpty`. A new `TurnsBench` cell, `report-idle`, records its cost on a lane machine: `emit` on a machine with a `Report` type and an empty lane. It isn't compared against base; it only records the figure.
  - If the lock shows up, the fallback is a second flag on the lane that a step reads without the lock, safe only because a missed flag is caught by the wake. Q4.
- **With reports, on a post.** One lock round trip per post, and one `Task` per wake. Wakes coalesce through `wakePending`.

### 3.9 Replay and recording

The core records nothing; the adopter records its inputs. A report gets no special path. It is recorded where the machine sees it:
- **A report the driver steps** goes through `handle(report:turn:)`. That handler records it, as the keeper records a server-originated input (#387): one record entry, at its position in the tick.
- **A report a step takes** (`turn.takeReports()`) is recorded inside that step's entry, at the take. For #732's case, the step's record then holds the failure that ended its inputs, which is what replay does at a failure that ended a tick's inputs (#732's `finishApply`, `endsInputs: true`).
- **Replay feeds the recorded report** to the machine at the same position, through the record source. Nothing is posted. A live post's position depends on timing, and the record fixes it.

The generated-orders harness gains a `post` operation from a task off the actor, with a hold point between the post and the wake, so seeds cover "posted during a step", "posted between steps" and "posted while the wake is in flight".

### 3.10 The reentrancy rule in CLAUDE.md

The "Outside turns" bullet gains one line, in the PR that adds the lane:

> A report that the keeper must see before its next step (a failure found while closing the output gate) is posted to the core's lane (`post`, nonisolated, no await), which the next step takes first; an awaited submit can't promise that, because the keeper may run a step before the hop lands.

Until #700 moves the keeper, the line names #732's `LandFailureMailbox` as the keeper's stand-in.

## 4. How #732's mailbox maps onto the lane (at #700)

| #732 (keeper, today) | The core's lane (#700) |
|---|---|
| `LandFailureMailbox`, set-once, `nonisolated let` on the keeper | `nonisolated let lane = TurnLane<LandReport>(capacity: 1)` on the keeper's actor |
| `notePendingFailure(_:)`, called by the adapter's `failOutsideTurn` in the segment that closes the gate | `keeper.post(.transportFailure(f))`, from the same place |
| `applyPendingTransportFailure()` from `finishApply`, after the apply and before the turn's outputs | `turn.takeReports()` in the step's end-of-apply, before any `turn.emit` (#716's rule) |
| the read at the start of `runSyncOnlyTurn` and `runTurnOutputs` | the driver's pre-step take (§3.4): a sync-only turn is a step |
| the awaited `submitLandFailure`, which wakes a keeper with no turn due | dropped: the lane's wake (§3.3). The hold point `.failureSubmit` becomes a hold between the post and the wake |
| first failure wins (`note` keeps the first; `failLand` keeps the first cause) | capacity 1, first wins (§3.5); `failLand` unchanged |
| empty in re-evaluation | the same: no poster in replay (§3.7, §3.9) |
| `scripts/gate-close-census.sh` | unchanged: the closers still go through `failOutsideTurn`, which now posts |

#732's tests carry over as lane tests on the keeper: the window tests (`ClosedGatePendingFailureTests`) keep their holds, with `.failureSubmit` moved to the post-to-wake hold.

## 5. Tests (SwiftStateTurnsTests; holds, never timing; each must fail with the feature removed)

1. A report posted between two queued sends steps before the second: the queue holds A and B, the post lands after A's step, and the log reads A, report, B.
2. A post during a step (from a collaborator the step calls) is taken after that step's products drain, before the next step in the segment.
3. A post from another executor, held after the append and before the wake is scheduled: the next entry takes it, and the wake later finds the lane empty (`emptyLaneWakes == 1`).
4. No lost wakeup: a post while a wake is in flight but after its take is stepped by a second wake. A hold sits between the wake job's take and its segment's end, a post lands there, and a `bounded` wait sees the report stepped.
5. A capped segment (`maxReleasesPerBatch: 1`) still takes the lane before each step it makes.
6. Capacity 1: a second post before the take returns `false`, and the first is the one stepped; `refusedReports == 1`.
7. `turn.takeReports()` in a step returns a report posted, under a hold, during that step. The step emits nothing, and the report isn't stepped again.
8. Through `close` and after `endAll`, a report still steps (a control input).
9. Order of two reports, and of reports against a direct entry: an effect's result with reports posted steps after them.
10. A machine with `Report == Never` compiles with no `lane` declaration, and its `TurnsBench` cells are unchanged (§3.8).
11. Generated orders: the `post` operation in every seed family, including the budget-2 seeds.

Mutants, each to fail a named test above:
- the pre-step take removed from the loop (1, 5);
- the take at a direct entry removed (9);
- `wakePending` cleared outside the take's lock (4);
- the capacity check inverted (6);
- `takeReports` returning `[]` (7).

## 6. Steps

1. **One SwiftStateTurns PR** (core path): `Report`, `TurnLane`, `post`, `laneWoke`, the pre-step take, `turn.takeReports()`, counters, the tests and mutants above, the bench cell, and the docs (`docs/turns/README.md` and `.zh-TW.md`, the DocC CoreConcepts page). The CLAUDE.md line (§3.10) goes in the same PR. No keeper change.
2. **#700** maps #732's mailbox onto the lane (§4) when LandKeeper moves onto `TurnCore`. #700's plan names this plan.

#696/#704 (#732) ships the keeper box now and isn't blocked by this plan.

## 7. Questions for Review

- **Q1.** Is a separate `Report` type right, against a lane of `M.Input` that steps with the input's own policy? Recommended: `Report` (§3.1).
- **Q2.** At a direct entry with reports posted: step the reports and then the entry's own input directly, or queue the input and run a segment? Recommended: direct (§3.4).
- **Q3.** Should a report carry the poster's incarnation, so a replaced core drops one posted before it existed? Recommended: no, until a user needs it (§3.7).
- **Q4.** On a machine with reports, is a locked read per step acceptable until the package can use `Atomic` (macOS 15)? Recommended: yes, with the `report-idle` cell recording the figure (§3.8).
