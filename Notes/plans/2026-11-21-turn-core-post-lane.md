# Turn core: a nonisolated post lane that the next step takes first (#725)

**Status:** rev 3, GO from Review on the design and on §6's Public API, with §3.9's must-fix folded in below (Review glances, no new round). Main approved the additive API on 2026-11-21. Main approves the additive API once this revision holds: `LaneReport = Never`, the default `handleReport` where `LaneReport == Never`, and `TurnStats`' two new fields (§6).

**Rev 3** (Review's NOT GO on rev 2: 3 must-fix, 8 should, 1 nit; the direction was right: the lane on the core, the helper from `beginEntry()`, checkpoints per turn):
- §3.4: the driver removes one report at a time from the lane's head, bounded by a sequence watermark read at the check. Unstepped reports stay in the lane, so a step's `takeReports()` sees them in order: with A and B posted and C posted while A steps, A's take returns B, C. There is a test for that order. Two ordering exceptions are stated and tested: a query from `flush` inside a batch, and a report posted by a report's own step during an entry's helper (MF 1).
- §3.4: every entry that ran the helper ends through the segment epilogue (`if rt.dirty { runSegment() }`), its stale returns included, and so does `laneWoke` with an empty lane. There is a test for a report-induced stale deadline with no later entry (MF 2).
- §3.9: replay keys each take by its step's ordinal and the take's ordinal. The core records the take when the step dispatches it, and replay serves it the same way. An unconsumed or overdrawn stage is a divergence and fails fast. Empty takes aren't recorded, and replay serves `[]` when nothing is staged (MF 3).
- Shoulds:
  - one budget from the outer entry through the helper and the segment's loop, and one owner of the remainder wake (§3.3, §3.4);
  - the lost-wake mutant is producer-side (§5);
  - the lane's identity can't go wrong: the core makes the lane, and the actor stores `core.lane` (§3.2);
  - §4.1's rows: a pre-output checkpoint for the tickless input turn, initialize's checkpoint with no `OnInitialize`, `.failed(f)` for an already-applied failure, and outputs staged until the last checkpoint, to be refined in #700's plan;
  - `.cancelsCall`'s policy read: the control or normal choice must depend on the input alone (§3.4);
  - Q5 = `fatalError` (§3.5).
- Nit: "set-once" is now "the first pending report wins".
- After Review's GO on rev 3, these follow:
  - §3.9's must-fix: driver-stepped reports are keyed `before(n, i)` in the same staged map as mid-step takes, and served from the check in replay. `replayReport` is dropped. Test 13 gains a report stepped between two releases.
  - The shoulds:
    - the step ordinal counts only when `usesLane` holds;
    - the epilogue wakes whenever reports remain;
    - `TurnReplayDivergence` is `package`.
  - Review's glance on §3.9: trailing reports, stepped after the last dispatch, are keyed for an ordinal replay never reaches. `finishReplay()` steps them at the end of the record and fails on any leftover entry. A mid-run `laneWoke` report replays at the next dispatch's check, with its recorded `now`; the moved segment boundary is accepted. Test 13 gains both cases.
  - The prior art is corrected: "was empty, so kick" (the kernel's lock-free list queues, not `prepare_to_wait`); NAPI's `napi_poll` weight within `netdev_budget`; and the signal loop against the lane's budget.
- Prior art (the maintainer): Unix signal delivery at a safe point, receive livelock and NAPI's budget, check-then-sleep, and FIFO across two takes, each tied to the section it shapes.

**Rev 2** (Review's NOT GO on rev 1: 5 must-fix, 10 should, 2 nit):
- §3.2, §3.6: the lane lives on the core. The driver's take and a step's `turn.takeReports()` see one ordered queue, so FIFO holds across a mid-step take. A mid-step take is an environment read, like `turn.now`, with a replay source (§3.9) (MF 1, way (b)).
- §3.4: every direct entry is listed, `stepStale` and `deadlineFired` included. The take comes before each entry's eligibility checks. One helper, called from `beginEntry()`, marks the core in-segment and drains after each report, so a send or a query from `flush` doesn't recurse (MF 2; Q2 = direct, decided).
- §4: each keeper turn kind maps to explicit checkpoints, with what each suppresses. Callers get `landClosed` before `Turn.reply` publishes (MF 3).
- §4.2: the record shape after migration changes. A pre-step report fails the land before inputs that were queued earlier, where today's awaited submit queues `.landFailure` behind them. #696's enqueue gate, the census and the first cause across a rebind stay (MF 4).
- §3.2: the nil `lane` default is only in `extension TurnActor where M.LaneReport == Never`. A `post` with a nil lane traps. lint-turns gets a `[let-lane]` rule (MF 5).
- Shoulds:
  - Q1's reason is now the static fold;
  - the associated type is `LaneReport`, so a machine's nested `Report` type can't opt in by accident;
  - `TurnStats` gains fields;
  - a per-check snapshot plus a per-segment budget prevent a livelock;
  - there is no `wakePending` flag (it is derived from the lane being non-empty), and capacity < 1 is rejected;
  - quiescence doesn't count reports;
  - the unlocked fallback is dropped (`ManagedAtomic` if needed);
  - lane-on vs lane-off is measured;
  - a package hook on `TurnLane`, and a post during apply in the carried-over tests.
- Nit: `handleReport(_:_:)`. Q3 = no incarnation, decided.

## 1. The problem

`TurnActor`'s entries (`send`, `sendAndWait`, an effect's result, a timer) are actor-isolated. A collaborator on another actor that has to tell the machine something hops onto the turn actor and awaits. Until the hop lands, the turn actor can run a step that should already have seen the report.

#696/#704's plan (`2026-11-21-closed-gate-replies-and-pending-failure.md` §2.2–2.3) meets this on the keeper. The transport adapter closes the land's output gate on a failure outside a turn. Before the queued `.landFailure` input arrives, the keeper can still run a sync phase, either behind the hop or behind a queued item. #732 closes the window with a keeper-specific box, `LandFailureMailbox`. It is set-once, lock-protected and `nonisolated`. The keeper reads it in `finishApply` (after each apply segment), at the start of `runSyncOnlyTurn`, and in `runTurnOutputs`. The awaited `submitLandFailure` stays to wake a keeper that has no turn due.

When LandKeeper moves onto `TurnCore` (#700), that box should be a capability of the core rather than a side channel next to it. This plan specifies the capability.

## 2. Prior art

- **Akka (classic) mailboxes** keep system messages (supervision, termination, watch) in a separate queue next to the user mailbox.
  - `Mailbox.run` processes all system messages first, then user messages, and checks the system queue again after each user message. So a stop or a failure is seen before the next user message.
  - An enqueue that finds the mailbox idle schedules it with a compare-and-set on its status, which avoids both a lost wakeup and a double run.
  - The shape proposed here is the same: a second queue, taken before each step, and scheduled by the post that finds it empty.
- **Erlang/OTP 28 priority messages ([EEP 76](https://www.erlang.org/eeps/eep-0076), [OTP 28 highlights](https://www.erlang.org/blog/highlights-otp-28/)).** A receiver opts in with `alias([priority])`, and messages a sender marks `priority` through that alias go ahead of ordinary ones. Selected exit and monitor signals can be priority messages too. Two points carry over: the receiver opts in, and the lane is for a few control messages, not for traffic.
- **Unix signals: delivery at a safe point.**
  - The kernel never delivers a signal in the middle of an instruction. It checks the pending flag (`TIF_SIGPENDING`) on the way back to user mode (`exit_to_user_mode_loop`), where the task's state is consistent.
  - The lane's safe point is the step boundary: `takeLaneBeforeStep()`, before each step (§3.4).
  - One difference: the kernel loops in `exit_to_user_mode_loop` until no work flag is set. The lane bounds each entry's delivery by a budget instead, which is NAPI's choice, for the same livelock reason (next item).
  - A step's own `turn.takeReports()` is the exception, a delivery inside the unit of work, and it needs its own justification. Here that is #732's case: a failure that lands during a turn must stop the turn's outputs, which go out after the step. The read is made only at checkpoints the machine names (§3.6, §4.1), and it is recorded as an environment read for replay (§3.9).
- **Receive livelock, and NAPI's budget.**
  - Mogul and Ramakrishnan ("[Eliminating Receive Livelock in an Interrupt-driven Kernel](https://www.usenix.org/conference/usenix-1996-annual-technical-conference/eliminating-receive-livelock-interrupt-driven)", USENIX 1996) showed that work run at a fixed higher priority than everything else (there, interrupt-driven packet input) starves the rest under load: the system spends all its time accepting work it never completes.
  - Reports step ahead of everything (§3.4), so a stream of reports, or a report whose handler posts its successor, is the same hazard.
  - The fix follows [Linux NAPI](https://docs.kernel.org/next/networking/napi.html). `net_rx_action` runs each device's `napi_poll` up to its weight, within the softirq's `netdev_budget`. Work left at the end re-raises `NET_RX_SOFTIRQ`, or goes to `ksoftirqd`: it is rescheduled, not looped over. The lane's budget is NAPI's: one budget per entry, the poll, spent by the helper and by every check in that entry's segment. The epilogue is its single owner: when reports remain at the budget's end, it reschedules them with a wake, including when the budget was already zero (§3.3, §3.4).
  - Test 11 pins the split: a self-reposting report splits exactly at the budget.
- **Lost wakeup: "was empty, so kick".**
  - The lane has no sleeper, so the match isn't `prepare_to_wait` (the sleeper's side of the check-then-sleep race). It is the kernel's lock-free list queues, where the producer that makes the queue non-empty owns the kick:
    - `__smp_call_single_queue` does `if (llist_add(node, queue)) send_call_function_single_ipi(cpu)`, and `llist_add` returns true only when the list was empty;
    - `irq_work_queue` does the same.
  - Every other producer finds work already queued and a kick already owed. The consumer drains the whole list, so a later add again finds it empty.
  - The lane works the same way. `post`'s "was the lane empty" check and its append are one critical section (§3.3), and only the post that found it empty schedules the wake. The mutant splits the two with a hook between (§5, test 4).
- **FIFO across two takes.** A consumer that detaches a batch and steps it from a private copy lets a nested consumer (a step's `takeReports()`) take later reports ahead of the batch's rest. So a check dequeues one head at a time, bounded by the watermark read at the check (§3.4), and never holds a detached batch.
- **Swift actors** have no second lane. Task priority changes scheduling but promises nothing about which job runs first, so an awaited call can't promise "before your next step".
- **The repository's own precedents:**
  - the keeper's `isDraining`, and #732's `LandFailureMailbox`;
  - `2026-11-21-a-closure-that-captures-only-actor-state-runs-off-the-actor.md`: a check-then-register against state another segment settles happens in one isolated segment;
  - `2026-11-20-a-budget-break-strands-the-work-kinds-after-it.md`: a new work kind in the driver's loop says where it sits against every budget and exit;
  - `2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md`: a feature keyed on an associated type with a `Never` default gets a static gate.

## 3. Design

### 3.1 What the lane carries: a `LaneReport`, not any input

A machine opts in with a new associated type, `associatedtype LaneReport: Sendable = Never`, and a handler, `mutating func handleReport(_ report: LaneReport, _ turn: inout Turn<Self>)`. Its default implementation is in `extension TurnMachine where LaneReport == Never`, and it is unreachable there.
- **The name.** A machine that already has a nested `Report` type would satisfy an associated type named `Report` without meaning to, and so opt in to the lane by accident. One test harness already has `struct Report` (`DifferentialHarnessTests.swift:33`, not a machine). `LaneReport` makes that unlikely.
- **Why not `M.Input` (Q1, decided).** The reason is cost. A lane of `M.Input` would be open to every machine, so the driver would need a per-step load (`lane != nil`) on every machine. A separate type with a `Never` default gives a static gate, `TurnCore<M>.usesLane = M.LaneReport.self != Never.self`, which folds every lane path away on a machine that doesn't use it, as `usesFollowUps` does.
- **The other differences follow.** A report steps as a control input: holds, `close`, the queue limit and withdrawal don't apply. It has no caller, so no reply and no `TurnError`.

### 3.2 Where the lane lives: the core makes it, the actor stores it

`TurnLane<Report>` is a `final class`, `Sendable`, lock-protected (`NSLock`). It holds:
- the posted reports in post order, each with a sequence number the lane assigns at the post;
- a capacity;
- a refusal count.

**One instance, made by the core.** `TurnCore.init(…, laneCapacity:)` makes the lane when `usesLane` holds and stores it as `let lane: TurnLane<M.LaneReport>?`. A capacity below 1 stops the process with `fatalError("TurnLane: capacity must be at least 1")`, as `TurnCore`'s other configuration checks do (`TurnCore.swift:231–233`). The driver and `Turn` reach the lane through the core (`Turn.swift:8` holds only the core).

**The actor stores the same instance.** `post` is nonisolated and can't read `core`, so the actor keeps its own reference:
- the protocol requirement is `nonisolated var lane: TurnLane<M.LaneReport>? { get }`;
- the adopter's init makes the core first, then assigns `self.lane = core.lane`, so there is no second instance to confuse with the core's;
- lint-turns `[let-lane]` checks, as `[let-core]` does, that `lane` is a stored `nonisolated let` assigned from `core.lane`, never a `var`, a computed property or another value. Its negative controls go in the lint's self-test.

**The `nil` default** is only in `extension TurnActor where M.LaneReport == Never`. A machine with reports has no default, so its actor doesn't compile without a `lane`. `post` on an actor whose `lane` is nil traps (`fatalError`). With the lint, that can only be a core made for `Never`, which can't happen for a machine with reports.

### 3.3 Posting and the wakeup: no separate flag

`nonisolated func post(_ report: M.LaneReport) -> Bool` on `TurnActor`:
1. Under the lane's lock, in one critical section:
   - if the lane is at capacity, it counts a refusal and returns `false`;
   - otherwise it reads whether the lane is empty, assigns the next sequence number and appends the report.
2. Outside the lock, if the lane was empty, it schedules one wake: `Task { await self.laneWoke() }`.

**Who schedules a wake.** The post that makes the lane non-empty schedules it. "A wake is due" is derived from the lane holding reports, so there is no `wakePending` flag.

**The other owner of a wake.** A segment's epilogue schedules a wake whenever reports remain in the lane at its end, whatever left them there: a spent budget, or reports posted after the segment's last check. Every entry that ran the helper ends through that epilogue (§3.4), so this owner always runs. A zero remaining budget counts: a segment that stepped no report because the entry's budget was already spent still schedules the wake.

**No lost wakeup.** The read of "was empty" and the append are in one critical section, so a post can't see the lane as non-empty because of a report that a take is removing at the same moment. Every post that leaves the lane non-empty has one of two owners for its wake:
- the post that made it non-empty;
- an epilogue that left reports behind.

**`laneWoke()`** is an ordinary entry. It runs the helper and ends through the epilogue, also when it finds the lane empty because an entry took it first. It then counts `emptyLaneWakes`.

**A post from inside a step** goes to the lane with a sequence number past the current check's watermark (§3.4). It steps at the next check, within the same budget.

**Rejected: the poster's awaited submit as the wakeup.** That is #732's current fallback. Every poster would await, and the lane would depend on a second path for liveness.

### 3.4 Order: the lane is taken before every step

**The rule.** Before each step the driver makes, it steps the reports posted before that check, in post order, draining each one's products before the next. A post that lands at any point is seen before the next step that starts after it, within the budget below. That is Akka's "system messages before each message".

**The check: a watermark, one head at a time.**
1. A check reads the lane's last sequence number: its watermark.
2. It removes the head only while the head's sequence number is at or below the watermark, one report at a time, and steps it before removing the next.
3. Reports not yet stepped stay in the lane.

So the driver and a step's `takeReports()` take from one queue, and nothing is ever detached ahead of its step:
- A and B are posted, and a check reads watermark B. A is removed and steps.
- C is posted while A steps.
- A's `takeReports()` returns B, C: B was still in the lane, and nothing passes it.
- The check then finds the lane empty and stops.

The order is A, B, C, and no report is seen twice. A report posted during a check, with a sequence number past the watermark, waits for the next check, so a report whose handler posts its successor can't extend the check it is in.

**One helper, `takeLaneBeforeStep()`.** It does nothing unless `usesLane` holds and the lane isn't empty.
1. It saves `inSegment` and sets it.
2. It runs a check.
3. It restores `inSegment`.

Setting `inSegment` is what makes reentrancy safe. While a report's products flush, `flush` may call the actor:
- a `send` from `flush` sees `inSegment` and queues, as it does from inside a segment today;
- a `query` from `flush` answers in place, as a query from inside a batch does, with no check. Reports posted before it wait for the next check. **This is exception 1**, and test 10 pins it.

**One budget per entry.** `beginEntry()` sets a lane budget of `capacity` reports. The helper and every check in the segment's loop spend it. When it runs out, checks stop stepping reports. The epilogue sees reports left and schedules a wake (§3.3), and the rest step in a new batch with a fresh budget. A finite self-reposting script therefore ends where its script ends, over as many batches as its length needs.

**Where checks run.**
- **In `runSegment`'s loop**, right after `drainProducts()`, before abandonments, queued inputs, releases and follow-ups. The order is: products, lane, abandoned, queued, releases (capped), follow-ups. A capped segment still checks the lane, which is the budget-break lesson's rule.
- **At every entry, from `beginEntry()`**, after the incarnation check and before the entry's own eligibility checks. A report's step can change exactly what those checks read, so they read the state after it:

  | Entry | Its eligibility check, which now comes after the helper |
  |---|---|
  | `submit` (also behind `sendAndWait`) | `admit`'s `close`, withdrawal, scope and hold checks |
  | `query` (outside a batch) | none; the answer step follows |
  | `complete` | `rt.open[id]`; a closed request takes the `stepStale` path |
  | `deadlineFired` | `rt.open[id]` and `gateDeadlineLive(id)`. Today its stale path returns before `beginEntry()`; now the helper runs first |
  | `timerFired` | `rt.timers[key] == generation`, the same way |
  | `gateReturned` | `followUpIDs[id]` and the arm's `waiting` |
  | `continueDrain`, `continueFollowUps` (#723: `continueBatch`), `laneWoke` | none; their segment follows |
  | `callerCancelled` | none, and no helper: it steps nothing (a withdraw and a resume) |

  An entry with a foreign incarnation returns before the helper, as it returns before touching the core today. The lane's own wake covers it.

**Every entry that ran the helper ends through the epilogue.**
- **The problem it solves.** Suppose a report the helper steps closes request R. That queues R's abandonment, and the report's flush may queue a send. A `deadlineFired(R)` that then sees R stale and returns at once would strand both, because the lane is empty and no wake comes.
- **The rule.** Every return of such an entry, its stale returns included, goes through `if core.rt.dirty { runSegment() }`, the epilogue that schedules the remainder wake. `laneWoke` does the same with an empty lane.
- **Test 15** pins it: a report-induced stale deadline with a queued abandonment and a flush-queued send, and no later entry.

**The direct form (Q2, decided).** An entry runs the helper, then its own checks, then its own step, as today.

**Exception 2: a report posted by a report's own step during an entry's helper.**
- Suppose B is posted by A's step while the helper of an entry with its own input X runs. B is past the helper's watermark, so the helper stops after A.
- X then steps, and B steps at the loop's first check. The order is A, X, B.
- B is still taken before the loop's next step; X had been admitted already.
- Test 16 pins it.

**`.cancelsCall`'s policy read.** `sendAndWait(.cancelsCall)` reads `inputPolicy(for:)` before it submits, to choose between the control and normal paths, and the helper then runs inside `submit`.
- **The rule.** The control or normal choice must depend on the input alone, never on the machine's state, so a report stepped in between can't change it. The `.normal` case's hold, scope and token may depend on state, because `admit` reads them after the helper.
- **Where the rule is stated and checked.** `inputPolicy(for:)`'s doc says so. In debug, `admit` checks that the case it reads matches what the caller read, and asserts if not.

**Against queued work.** Reports go ahead of everything not yet stepped at the check: queued sends, parked releases, due follow-ups. They never interrupt a step, except through a step's own `takeReports()` (§3.6). Two reports keep their post order. A report and an ordinary input from two different tasks have no order beyond "taken before the next step that starts after the post", within the budget, the same as Swift's order between calls from different tasks.

### 3.5 Capacity, and the first pending report wins

- **At capacity 1, the first pending report wins.** It stays until something takes it, which is #732's rule.
- **First wins.** A post to a full lane returns `false` and isn't stored: for terminal reports the first cause matters. The lane counts the refusal under its lock, and the next check adds it to `TurnStats.refusedReports`.
- **Default capacity: 8.** A capacity below 1 is a `fatalError` (§3.2).
- **A taken report is gone.** A machine that must keep the first report for its lifetime (the keeper's `failLand` keeps the first cause) does that in its own state.

### 3.6 Taking the lane inside a step: `turn.takeReports()`

#732 reads its box in the middle of a turn: after the apply, before anything of the turn goes out. A report posted on another thread while the step runs must still stop that step's outputs. The pre-step check can't do that, because the step has already begun.

`turn.takeReports() -> [M.LaneReport]` removes every report in the lane, from the head, through `core.lane`:
- **FIFO holds.** The driver never detaches a report ahead of its step (§3.4), so the lane's head is always the oldest report not yet handled. A mid-step take returns the reports from there on, and the driver's next check starts after them.
- **It is an environment read.** Like `turn.now`, the step's result depends on something outside its input. The core records each take and replay serves it (§3.9), so a replayed step sees the same reports at the same point.
- **It doesn't spend the entry's budget.** A step takes what is there at fixed points, so it can't loop on its own posts.

A machine that never calls `takeReports()` gets only the pre-step checks, which is enough for any machine that doesn't need the mid-step read.

### 3.7 `close`, `endAll`, a replaced core, quiescence

- **`close` and `endAll`.** Reports step as control inputs through `close`, and after `endAll`, as a timer's input does. A machine that wants to ignore reports once ended does so in its handler.
- **A replaced core (Q3, decided: no incarnation).** Each core makes its own lane (§3.2), and posts carry no incarnation. Only a test actor replaces its core, through `[let-core]`'s lint-allow. A machine with reports doesn't support that: its actor's `lane` would still be the first core's. The same lint-allow can't be used with `[let-lane]`. The keeper doesn't replace its core.
- **Quiescence.** `waitForQuiescence` doesn't count lane reports. They come from outside, as sends do, which it doesn't count either. No `TurnWork` kind is added.

### 3.8 Cost

- **Without reports (`LaneReport == Never`).** Every lane path is behind `usesLane`, so `runSegment`, the entries and the wake fold away.
  - The follow-ups plan's §10 cells (`2026-11-20-turn-core-follow-ups.md`: `emit`, `call`, `idle`, on the bench's machine) must not move.
  - They are measured with that plan's procedure: `perf stat -e instructions:u`, n minus the n = 0 run, five runs per side, alternating, threshold max(0.5 %, 3 × spread), while holding the measurement lock.
- **With reports, on an empty lane.** A dirty `emit` takes the lock twice: once at the entry, once at the loop's first check.
  - The measure is lane-on against lane-off. Two new `TurnsBench` cells run the same machine with an empty lane: `report-emit` and `report-call`. Their baseline is that machine built with `LaneReport == Never`, so the figure is the lane's own cost.
  - The cells are recorded, not gated.
  - If the second lock shows, the loop's first check is skipped when the entry has just taken the lane and nothing has stepped since. That is one `Bool` in the segment.
- **Atomics.** `Synchronization.Atomic` needs macOS 15, and the package targets macOS 14. If the locked read is too dear, `ManagedAtomic` from swift-atomics is the option, and adding that dependency would be its own decision. No unlocked flag is used.
- **With reports, on a post.** One lock round trip per post, and one `Task` per wake; wakes coalesce, because only the post that makes the lane non-empty schedules one.
- **`TurnStats`.** It gains `emptyLaneWakes` and `refusedReports`. `TurnStats` is `Equatable`, so a test that compares whole stats values sees two new fields at 0. The PR checks the suites for such comparisons.

### 3.9 Replay and recording

Replay can't point a report at its place from outside. The driver can step a report between two core-dispatched steps in one segment: between two released parked inputs, before a captured follow-up, after a send that a flush queued. Some steps are themselves dispatched by the core: a follow-up, a released input, a query asked from `flush`. So the core keys every report it hands out, both kinds, by the steps it dispatches.

**Step ordinals.**
- The core numbers every non-report step it dispatches: `stepOrdinal`, counted from the core's start, for inputs, releases, follow-ups, answers, completions, timers and abandonments alike.
- For one input sequence, live and replay dispatch those steps in the same order, so an ordinal names the same step on both.
- A report's own step doesn't take an ordinal. Its place is given relative to the next one (below).
- **The counter's cost.** It counts only when `usesLane` holds, so it folds away on a machine with `LaneReport == Never`. The gated `emit` and `call` cells don't pay it (§3.8).

**The keys.** One staged map serves both kinds of report:
- `before(n, i)`: the i-th report the driver stepped at the check that ran before step n's dispatch. The checks of an entry's helper and of the segment's loop all count. A check after the segment's last step counts for the next step the core dispatches.
- `inside(n, t)`: what take t of step n's `turn.takeReports()` returned, with t counted from 0 in that step.
- Inside a report's own step, `takeReports()` returns `[]` and isn't recorded. Any reports posted meanwhile step at the next check.

**Live.**
- The core's report source is `.live(lane)`. Each report the driver steps is passed to the adopter's recorder (`onReportsTaken`) under its `before` key, before `handleReport` runs. Each non-empty mid-step take is passed under its `inside` key.
- The adopter writes them into its record at those keys, as the keeper records a server-originated input (#387). Empty takes aren't recorded.

**Replay.**
- The source is `.replay(staged)`, the map read back from the record, and nothing is posted. There is no separate `replayReport` entry.
- Before it dispatches step n, the check steps the reports staged under `before(n, 0…)`, in order. That covers both the entry's helper and the segment's loop, in replay mode whether or not the lane is empty.
- `turn.takeReports()` in step n is served from `inside(n, t)`, or `[]` when nothing is staged for that key.

**Divergence.** `TurnReplayDivergence` is `package`, like the replay source. It names the key and the case, and goes to the adopter's replay through a package hook, `onReplayDivergence`, which fails the replay run. With no hook set, it is a `fatalError`. The cases are:
- **unconsumed:** step n dispatches while an entry for an ordinal below n is still staged;
- **overdrawn:** a take finds nothing under its key, but a later take of the same step has an entry;
- **leftover:** at the end of the record, an entry is still staged after `finishReplay()` (below).

**Trailing reports.** A check that runs after the last step the core ever dispatches steps its reports under `before(n, i)`, where n is the next ordinal, which no step takes. That happens for a `laneWoke` with no turn due (#704's idle failure is one), and for reports posted at the end of a record. Replay never dispatches step n, so no check steps them, and the unconsumed check, which runs only at a dispatch, never sees them.
- The core gains a package `finishReplay()`. The adopter's replay calls it once, after the record's last input. It steps the reports staged under `before(n, 0…)` for the core's current next ordinal n, in order, through the same path as a check. Then any entry still staged fails the replay as **leftover**.
- A replay that never calls it can't tell a trailing report from a missing one, so the adopter's replay must call it. That is part of the adopter's replay contract; for the keeper, §4.2's re-evaluation item.

**Where a trailing report replays.** The same keying covers a report a `laneWoke` stepped mid-run, with no turn due: it is keyed `before(n)` for the next dispatch, and replay steps it at that dispatch's check, not at its own live entry. This is accepted, with two consequences:
- **The segment boundary differs.** Live, the report steps in its own segment and that segment's epilogue runs. Replay steps it in the next dispatch's segment. Replay compares outputs, not settlement points, so a quiescence waiter's wake point is the only thing that moves, and replay has no waiters.
- **`turn.now` would differ.** The report's step would read the next dispatch's time, not the wake's. So each `before` entry records the `now` of the check that stepped it, and replay serves that `now` inside the report's step. It applies to every `before` entry, trailing or not; for the others it is the same value the entry reads anyway.

A live post's position depends on timing; the record fixes it.

The generated-orders harness gains a `post` operation from a task off the actor, through a package async hook on `TurnLane`. The hook has hold points:
- between the "was empty" read and the append, in a mutant build only, for the mutant;
- between the append and the wake;
- between a check's watermark and its first removal.

The seeds cover "posted during a step", "posted between steps" and "posted while a wake is in flight", the budget-2 seeds included.

### 3.10 The reentrancy rule in CLAUDE.md

The "Outside turns" bullet gains one line, in the PR that adds the lane:

> A report that the keeper must see before its next step (a failure found while closing the output gate) is posted to the core's lane (`post`, nonisolated, no await), which the next step takes first; an awaited submit can't promise that, because the keeper may run a step before the hop lands.

Until #700 moves the keeper, the line names #732's `LandFailureMailbox` as the keeper's stand-in.

## 4. #732's mailbox on the lane (at #700)

### 4.1 Checkpoints per keeper turn

On the core, each keeper turn is one step. A tick turn's apply, handler, hash and outputs are one step, so the pre-step check alone can't replace #732's reads inside the turn. Each turn kind gets explicit checkpoints. A checkpoint is a `turn.takeReports()` call, and a report it returns calls `failLand` in that step.

**The turn's events and replies are staged until its last checkpoint.** The core flushes a step's outputs and publishes its replies only after the step, so whatever a later checkpoint suppresses hasn't gone out. #700's plan refines how the keeper stages them. These rows give the checkpoints, not that staging.

| Turn kind | Checkpoints (today's #732 read) | What a report taken there suppresses |
|---|---|---|
| any | the driver's pre-step check (no read today; the awaited submit's turn) | the whole step: the report steps first, and the land has failed before the turn starts |
| initialize | after the apply (`finishApply`). It runs with no `OnInitialize` handler too, because the land's first sync is still an output | the turn's events, its sync phase and its record hash |
| tick turn | after the apply and the handler (`finishApply`), and before the sync phase (`runTurnOutputs`) | after the apply: events, sync and hash. Before the sync phase: the phase and what follows |
| tickless input turn | after `takePassOrdinal`, before `if failure != nil` (`finishApply`), and before the outputs (`runTurnOutputs`'s read) | events and sync. Every consumed caller's result becomes `landClosed`, written to `inputTurnResults` in the step, before `Turn.reply` publishes in the drain after it |
| sync-only turn | the start of the step (`runSyncOnlyTurn`) | the phase; the turn returns `.failed(f)` |
| freeze settle (L2d-1, a sync-only turn) | the start of the step | the phase. The settle returns `.failed(f)`, not `.skipped`, also when the failure was applied by an earlier step and this one only finds the land failed |

The awaited `submitLandFailure` goes, and so does its hold point `.failureSubmit`, which becomes the lane's hook between the append and the wake (§3.9).

### 4.2 What changes, and what stays

**The record's shape changes.**
- **Today.** `submitLandFailure` appends `.landFailure` to `pendingItems` behind every item queued before it (`LandKeeper.swift:5541`). The record shows the failure after those items, and they are applied first (#732's box can end the inputs earlier, at a boundary it reaches first).
- **On the lane.** A report taken before a step fails the land before any input still queued at the take. Those inputs aren't applied, and their callers get `landClosed`. The record shows the failure at the take's position, before them.
- **Replay** reproduces either shape, because the record fixes the position. A record made before the migration replays as before.
- **For the #700 PR body.** It states the change, and a test pins it: two inputs queued, a post, then the turn. The record holds the failure first, and both inputs are refused.

**What stays.**
- **#696's enqueue gate.** The output gate is read where each frame is enqueued, and that read stays. The lane stops the keeper's next turn. The gate stops frames already on their way.
- **The census.** `scripts/gate-close-census.sh` is unchanged: the closers still go through `failOutsideTurn`, which now posts.
- **The first cause, across a rebind.** The report is posted to the keeper's lane, not to an adapter, so a rebind doesn't lose it. `failLand` keeps the first cause.
- **Re-evaluation.** Replay has no poster. A recorded failure comes from the record (§3.9). The keeper's replay calls `finishReplay()` after the record's last input, so a failure posted after the last step (a trailing report) is stepped and a stray staged entry fails the run.

| #732 (keeper, today) | The core's lane (#700) |
|---|---|
| `LandFailureMailbox` (the first failure wins), `nonisolated let` on the keeper | `TurnLane<LandReport>(capacity: 1)`, on the core and the keeper's actor |
| `notePendingFailure(_:)`, from `failOutsideTurn` in the segment that closes the gate | `keeper.post(.transportFailure(f))`, from the same place |
| `applyPendingTransportFailure()` in `finishApply`, `runSyncOnlyTurn`, `runTurnOutputs` | the checkpoints of §4.1 |
| awaited `submitLandFailure` | dropped: the lane's wake |
| first failure wins | capacity 1, first wins; `failLand` unchanged |

#732's tests carry over as lane tests on the keeper (`ClosedGatePendingFailureTests`). They keep their holds: a post during the apply (a hold inside the apply segment), a post during the handler, and a post with no turn due. `.failureSubmit` moves to the lane's hook.

## 5. Tests (SwiftStateTurnsTests; holds, never timing; each must fail with its feature removed)

1. A report posted after A's step, with B still queued, steps before B: the log reads A, report, B.
2. A post during a step (from a collaborator the step calls) is taken after that step's products drain, before the next step in the segment.
3. A post from another executor, held after the append and before the wake is scheduled: the next entry takes it, and the wake later finds the lane empty (`emptyLaneWakes == 1`).
4. No lost wakeup: posts from another executor, at every hold point of the lane's hook, are each stepped (`bounded` waits).
5. A capped segment (`maxReleasesPerBatch: 1`) still checks the lane before each step it makes. A post lands during a step through the hook.
6. At capacity 1, a second post before the check returns `false`, and the first is the one stepped; `refusedReports == 1`. (`capacity < 1` is a `fatalError`, with no test.)
7. `turn.takeReports()` in a step returns a report posted, under a hold, during that step. The step emits nothing, and the report isn't stepped again. A later post is stepped by the driver after it.
8. Through `close` and after `endAll`, a report still steps.
9. Each direct entry with a report posted steps the report first, then runs its own eligibility check against the state after it:
   - `complete` of a request the report closes takes the stale path;
   - `timerFired` of a timer the report cancels is stale;
   - `deadlineFired` of a request the report closes is stale;
   - `gateReturned` of a follow-up the report consumes is stale;
   - `submit`'s input is refused when the report closes the core.
10. Reentrancy and exception 1: a report whose output's `flush` sends an input and asks a query, with another report posted before the query. The send queues and steps after the report. The query answers in place with no check, and the other report steps at the next check. A recursion counter stays at 1.
11. NAPI's split: a finite self-reposting script (each report's handler posts the next, five in all), with capacity 2. Each batch steps exactly two, which is the budget. The epilogue's wake runs the next batch, and the chain ends where its script ends, in three batches (2, 2, 1). The job hook and `TurnStats` witness the batch boundaries.
12. A machine with `LaneReport == Never` compiles with no `lane`, and its `TurnsBench` cells are unchanged (§3.8).
13. Replay with the same outputs, live then replayed with the recorded takes:
    - a mid-step take in an input's step;
    - a mid-step take in a follow-up's step;
    - a mid-step take in a query's answer asked from `flush`;
    - a driver-stepped report ahead of a direct input in one segment;
   - a report stepped between two releases in one segment: posted under the hook while the first release steps, with `maxReleasesPerBatch: 2`;
   - trailing reports: a post with no turn due, stepped by `laneWoke` with a clock advanced since the last step, then a later input; and a post after the record's last input. Replay with `finishReplay()` steps both, the first at the later input's check with the wake's recorded `now` (the handler logs `turn.now`).

    A replay with one take removed from the stage fails as overdrawn. One with an extra take staged fails as unconsumed. One with an extra report staged after the last input fails as leftover at `finishReplay()`.
14. FIFO across the two takes (MF 1): A and B posted, C posted while A steps (a hold inside A's handler). A's `takeReports()` returns B, C, and the log is A, B, C, with no report stepped twice.
15. A report-induced stale deadline (MF 2): the report closes R, queues R's abandonment, and its flush queues a send. `deadlineFired(R)` runs the helper and finds R stale. The abandonment and the send both step with no later entry (`bounded` wait).
16. Exception 2: an entry with input X, while the helper steps A and A posts B. The log is A, X, B.
17. Generated orders: the `post` operation in every seed family, the budget-2 seeds included.

Mutants, each to fail a named test:
- the loop's check removed (1, 5);
- the helper moved after the entry's eligibility checks (9);
- **lost wake, producer-side:** `post`'s "was empty" read and its append in two critical sections, with the hook between them (4);
- the capacity check inverted (6);
- `takeReports` returning `[]` (7);
- `inSegment` not set by the helper (10);
- the budget removed (11, which then ends only by the hang bound);
- the check detaching its whole snapshot instead of one head at a time (14);
- a stale return in `deadlineFired` skipping the epilogue (15);
- the replay stage served by position, ignoring the step ordinal (13);
- the `before` key taken from the entry instead of the step (13's between-releases case);
- `finishReplay()` that skips the leftover check (13's leftover case), and one that doesn't step the staged trailing reports (13's trailing case);
- the report step reading the replaying entry's `now` instead of the recorded one (13's trailing case).

## 6. Steps

1. **One SwiftStateTurns PR** (core path). It adds:
   - `LaneReport`, `TurnLane`, `post`, `laneWoke`, the helper, `turn.takeReports()`, the report source with its staged map and its divergence hook, the step ordinal, and the counters;
   - lint-turns `[let-lane]`;
   - the tests and mutants above, and the bench cells;
   - the docs: `docs/turns/README.md` and `.zh-TW.md`, and the DocC CoreConcepts page;
   - the CLAUDE.md line (§3.10).

   No keeper change.

   **Public API**, listed in the PR body:
   - `associatedtype LaneReport: Sendable = Never` on `TurnMachine`;
   - `handleReport(_:_:)`, with a default where `LaneReport == Never`;
   - `TurnLane`;
   - `TurnActor.lane` and `post(_:)`;
   - `Turn.takeReports()`;
   - `TurnCore.init`'s `laneCapacity:`;
   - `TurnStats.emptyLaneWakes` and `TurnStats.refusedReports`. `TurnStats` is `Equatable`, so whole-value comparisons see the two fields.

   The report source, the step ordinal, `onReportsTaken`, `TurnReplayDivergence` and `onReplayDivergence` are `package`.
2. **#700** maps #732's mailbox onto the lane (§4) when LandKeeper moves onto `TurnCore`. Its plan names this plan, states the record change (§4.2), and refines the staging of §4.1.

#696/#704 (#732) ships the keeper box now and isn't blocked by this plan.

## 7. Questions

Decided:
- Q1 = `LaneReport` (§3.1);
- Q2 = the direct form with the helper (§3.4);
- Q3 = no incarnation (§3.7);
- Q5 = `fatalError` for a capacity below 1 (§3.5).

Q4 (the unlocked fallback) is dropped. None open.
