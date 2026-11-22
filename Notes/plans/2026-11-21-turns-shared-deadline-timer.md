# Turn core: one timer for all deadlines (#621 item 2)

**Status:** Rev 3: step 0 passed (continue, §5.1); the wake's per-entry rule follows #738 round 4's stale-arrival rule (§3.4). Rev 2 GO. Implemented on `refactor/621-shared-deadline-timer`; it takes #738 when that merges (the live entry's re-check after `beginEntry()` and `entryBoundary()` come with #738's lane).

## Implementation notes (where the code differs from this plan)

- **Commit order.** GeneratedOrder's monotonic ops and `OrderModel`'s relative timer instants (§4.4, planned as commit 4) are in the deadlines commit: the monotonic `TestClock` no longer wakes a sleep for a gate opened by name, so the harness would fail at that commit otherwise.
- **A wake hook.** `onTimerWakeForTesting` (package, one nil check per wake) is called at each wake that isn't foreign, with whether it was superseded. The tests wait for "timer wake #n" and "superseded wake #n" instead of polling the counters, which stay. `TestClock` also opens "sleeping deadline N #k" when a sleep starts waiting.
- **`liveTimerInputsForTesting`** is in every build, not DEBUG only: it is `rt.timers.count`, with nothing recorded, so a release test run needs no gate (`Notes/solutions/2026-11-22-a-test-that-reads-a-debug-only-probe-fails-in-a-release-test-run.md`).
- **Test 4.** A release horizon at 9 makes a later sleep until 5 return at once, so the new sleeper fires 5 then 9 without a release through 5. The superseded wake is checked by its hook and count; the log is 5, then 9.
- **Mutants not run.** "A rebuild that re-arms the sleeper" needs a structural change to apply; "a timer's input kept on the heap entry" can't be written while `DeadlineEntry` is plain data. 9's wasted-hop variant still pins the first (`sleeperStartsForTesting == 1`, no `"cancelled deadline 5"`).

## Rev 3: what changed

- **Step 0 done (§5.1): continue.** The deadline machinery costs at least about 3,550 instr/op of `park`'s 23,234 at base `3bceb649`, against the 2k floor.
- **A stale entry takes no entry ordinal (§3.4 step 4, §3.9).** #738's round 4 found that a stale deadline, timer or cancellation arrival takes an entry ordinal at a point the scheduler picks, so a replay can move mail onto another entry (#738, must-fix 1 on `TurnActor.swift:382`). Its rule: a stale arrival changes no state, so it gets no ordinal and behaves like a wake. The arrival checks staleness before `beginEntry()`, runs `beginEntry()` and re-checks only when it is live, and calls `entryBoundary()` only on the branches that change state. The wake's per-entry step follows that rule.
- **What the one timer removes by construction (§3.9).** Today a closed request's deadline task is cancelled and still hops to `deadlineFired`, at a time the scheduler picks. With one sleeper, a closed request's entry never hops: it is compacted, or the wake reaches it at its instant as a stale entry, without an ordinal. The same holds for a replaced or dropped timer. That doesn't make #738's fix unneeded. Until this PR lands, `deadlineFired` and `timerFired` are the live paths. After it, a stale entry the wake reaches still has to skip the ordinal, and `callerCancelled` is outside this PR.

## Rev 2: what changed

Review gave rev 1 GO on the shape and the semantics. Changes:
- **Q2 overturned (§3.6, test 8).** The per-wake cap is a fixed internal constant, `maxFiresPerWake = 64`, not `maxReleasesPerBatch`. That knob bounds parked releases per batch, and reusing it would couple release fairness to timer fairness.
- **Decided:** Q3 (fire on `target`, no clock read), Q4 (internal constants: rebuild at half, with a floor of 64), Q5 (`park-64` as a recorded cell, its own commit), Q6 (keep `.staleDeadline`/`.staleTimer`; the docs say compacted or `endAll`-dropped entries emit nothing), Q7 (timers in scope). Q1 decided by the maintainer: now, as foundation work, right after L2d-3, with step 0 first and the 2k instr/op floor as the stop rule.
- **Should 1 (§1.2, §3.4, §6).** `TurnClock.sleep(until:)`'s doc contract becomes "returns no earlier than the instant unless cancelled", and so does the WorkedExample clock's comment. The wake fires on `target` without reading the clock, so a clock that returned early would fire deadlines early.
- **Should 2 (§3.1, test 12, §4.5).** A DEBUG `liveTimerInputsForTesting` count, pinned by a test: a replaced or dropped timer releases its input at once (the retention class of `ScheduledThreadPoolExecutor`'s lazy cancel).
- **Should 3 (test 9, §4.5).** Test 9 asserts the wasted hop when a rebuild removes the sleeper's target. The wake finds nothing due, re-sleeps to the new head and emits no stale diagnostic. Two mutants, "re-arm on rebuild" and "drop the next target", must fail it.
- **Should 4 (§4.1).** `TestClock.set(seconds:)` must not move `now` backwards; it asserts.
- **Nit (§3.7, §3.8, §7).** `endAll`'s stop runs inside its step. §3.8 and step 2 now say so: the heap changes only in actor-isolated synchronous code, between steps, with that one terminal exception.

Code references are at `origin/main` `311d540a`. The post lane (#725, PR #738) is open and not on that SHA; §3.9 says what changes when it lands first.

## 1. Today

### 1.1 Where a deadline is set

There are three sources of a sleeping task, and all of them are staged by a step and armed by the driver after the step's flush.

- **A request with a deadline.**
  - `Turn.request(_:for:holding:)` (`Turn.swift:113–117`) passes the hold's deadline. Every hold has one (`Hold`, `Values.swift:69–92`).
  - `Turn.request(_:for:deadline:)` (`Turn.swift:119–124`) passes an optional one.
  - Both go through `makeRequest` (`Turn.swift:126–140`). It records `RequestRecord(hasDeadline:)` in `rt.open` (`:134`), computes the instant from the batch's one clock read (`core.segmentNow() + duration`, `:135`) and stages `PendingEffect(effect:request:deadline:)` (`:136`).
- **A follow-up's `.afterWork` gate with a deadline.** `Turn.followUp` (`Turn.swift:222–225`) records `FollowUpRecord(waiting: true, hasDeadline:)`, computes the instant the same way and stages the gate in `rt.followUpGates`.
- **A timer.** `Turn.timer(at:for:_:)` (`Turn.swift:179–187`) bumps `rt.nextTimer`, stores the generation in `rt.timers[key]` and stages `PendingTimer` in `rt.timersToArm`. A replaced timer sets `rt.timersToCancel`.

A request and a gate share one id space (`rt.nextRequest`), and ids are never reused within a core.

### 1.2 The sleeping task

- **Requests.** `launch` (`TurnActor.swift:511–530`) starts the effect's task. Then, if the request is still open (`:522`), it stores `core.deadlineTasks[id] = Task { [weak self] in await clock.sleep(until: instant); await self?.deadlineFired(id, incarnation:) }` (`:524–528`).
- **Gates.** `launchGate` (`:532–553`) does the same, unconditionally once the gate is launched (`:545–552`).
- **Timers.** `arm` (`:555–570`) cancels the key's previous timer task and stores `core.timerTasks[key] = (generation, Task { … timerFired … })`.
- **The bookkeeping.**
  - `core.deadlineTasks: [RequestID: Task<Void, Never>]` is at `TurnCore.swift:161`, with the package test hook `deadlineTasksForTesting` at `:163`.
  - `core.timerTasks: [M.Key: (generation:, task:)]` is at `:172`.
- **Who owns the actor.** Every sleeping task holds the actor weakly, so a periodic timer doesn't outlive the actor. The protocol doc says so (`TurnActor.swift:5–9`).
- **What the sleep is.** The sleep is the injected `TurnClock.sleep(until:)` (`Values.swift:205–213`). It returns at the instant, or earlier when its task is cancelled (rev 2 tightens the doc to "no earlier than the instant unless cancelled", §6). SwiftStateTurns doesn't depend on SwiftStateTree, so it can't call `safeTaskSleep` itself. A production adopter's clock sleeps with it (`WorkedExample.md:153–167`).

### 1.3 Cancellation and abandonment

- **A request closes** in `Runtime.closeRequest` (`Runtime.swift:249–266`). That covers a completion, `cancel`, `end`, a supersede, `endAll` and a deadline. Closing removes it from `rt.open` in the same synchronous segment, and if `hasDeadline` it sets `rt.deadlinesToCancel` (`:251`).
- **A follow-up closes or is consumed** in `removeFollowUp` (`:194–199`, `:196`). When its gate returns, `gateReturned` clears `hasDeadline` (`TurnActor.swift:276–279`). Both set the same flag.
- **The sweep.** `drainProducts` sweeps after every step that set the flag (`TurnActor.swift:467–472`). It cancels each task in `deadlineTasks` whose request isn't open and whose gate deadline isn't live (`Runtime.gateDeadlineLive`, `Runtime.swift:215–218`).
- **Timers.** `timersToCancel` sweeps `timerTasks` against `rt.timers` the same way (`TurnActor.swift:473–481`). It is set by a replace, by `dropTimer` (`Runtime.swift:274–279`, from `end` and a supersede, `Turn.swift:49`, `:65`) and by `endAll` (`Turn.swift:92–95`).
- **The core's deinit** cancels every deadline and timer task (`TurnCore.swift:249–253`).
- **The cancellation is an optimization.** The guarantee "an abandoned request's deadline never fires" comes from the re-check on the actor (§1.4). Closing removes the request from `rt.open` in the step's own segment. Cancelling only ends the sleep early, so the task doesn't live until its instant.

### 1.4 A fired deadline steps as its own input

- **Requests and gates.** `deadlineFired(_:incarnation:)` (`TurnActor.swift:191–213`) is an actor entry.
  1. A foreign incarnation is counted and dropped (`:193–197`).
  2. It removes the task's entry.
  3. A follow-up whose gate deadline is still live is closed (`:199–205`).
  4. A request that is no longer open reports `.staleDeadline` and does nothing (`:206–209`).
  5. Otherwise it runs `beginEntry()`, `closeRequest(id, .deadline)` and `runSegment()` (`:210–212`). The abandonment steps first in that segment's loop (`:374–378`) as `handleAbandoned(id, .deadline)`.

  So each fired deadline is one entry and one batch, with a fresh clock read on first use.
- **Timers.** `timerFired` (`:216–232`) does the same against `rt.timers[key] == generation`, and steps the timer's input as a control input.
- **The ticket.** The re-check runs in the segment where the fire lands. The request id (or the timer generation) is the ticket, and `rt.open` (or `rt.timers`) is the generation table. That is the shape `CLAUDE.md`'s reentrancy rule asks for.

### 1.5 The tests that pin it

The test clock is `TestClock` (`Tests/SwiftStateTurnsTests/Support/Fixture.swift:148–189`).
- **How it sleeps.** A sleep until N seconds waits at the gate `"deadline N"`, and returns early when its task is cancelled (`waitUnlessCancelled`, `:39–62`). On return it opens `"woke deadline N"` or `"cancelled deadline N"`.
- **Its stale events.** `Fixture.observe` turns `.staleDeadline` and `.staleTimer` into counted events (`:100–103`).
- **What it assumes.** Every gate is independent, so a test can let the deadline at 9 pass while the one at 5 hasn't.

| Test (file:line) | What it pins about deadlines and timers |
|---|---|
| ClockAndTimer 26 `timerFiresReplacesAndDrops` (`ClockAndTimerTests.swift:9`) | a timer fires once, carrying its instant; a replace cancels the old sleep (`"cancelled deadline 6"`, `:25`); ending the key drops a fire already woken (`"stale timer #2"`); one clock read |
| ClockAndTimer 27 `timerSkipsAhead` (`:55`) | a late fire schedules after now; nothing sleeps until the missed instants; ending the key cancels the next sleep (`"cancelled deadline 10"`, `:71`) |
| ClockAndTimer 29 `wakeRecheck` (`:78`) | a wake that lands after the completion abandons nothing (`"stale deadline #1"`); a replaced timer fires nothing; a cancelled request cancels its sleep (`"cancelled deadline 9"`, `"stale deadline #2"`, `:105–106`) |
| ClockAndTimer 30 `oneClockReadPerSegment` (`:119`) | a `Duration` deadline is the batch's one read plus the duration; each fire is its own batch (`"now 3"` after the first abandonment) |
| Lifetime `timerDoesNotRetain` (`LifetimeTests.swift:8`) | a released actor's core cancels both sleeps (`"cancelled deadline 2"` and `"30"`, `:20–21`); no stale timer |
| Lifetime `effectRetainsOnlyWhilePerforming` (`:25`) | a deadline's sleep doesn't hold the actor; cancelled at deinit (`:44`) |
| OrderedChecks 3 `deadlineAbandonsAndReleases` (`OrderedChecksTests.swift:46`) | a deadline abandons, releases the hold; the late result is stale |
| OrderedChecks 4 `retiringHoldOutlivesDeadline` (`:63`) | an `.untilWorkerReturns` hold outlives the deadline |
| OrderedChecks 9 (`:138`) | `reply(after:)` publishes at the deadline's abandonment (`:155–170`) |
| OrderedChecks 18 `endAllWithRetiringHold` (`:409`) | `endAll` cancels the deadline's sleep (`"cancelled deadline 9"`, `"stale deadline #1"`, `:421–422`); opening the gate later wakes nothing (count 1, `:434`) |
| FollowUp 8 `afterWork` (`FollowUpTests.swift:102`) | a gate deadline closes the follow-up with `.deadline` |
| FollowUp 18 (`:257`) | armed and closed before launch: no gate, so no deadline |
| FollowUp 19 `consumeVersusDeadline` (`:280`) | consume and gate deadline, both orders |
| FollowUp 28 `gateReturnCancelsItsDeadline` (`:465`) | a gate's return cancels its deadline (`"cancelled deadline 5"`) and keeps a live request's (`!"cancelled deadline 7"`, then it fires) |
| FollowUp 29 `obsoleteDeadlineLeavesSuccessor` (`:483`) | the sweep keeps a live gate deadline and cancels a consumed one (`deadlineTaskCount() == 2`, then `1`, `:498–500`) |
| FollowUp 32 `deadlineSharesClockRead` (`:580`) | a gate deadline is the arming batch's read plus the duration |
| FollowUp 34 `foreignGateReturnAndDeadline` (`:511`) | the old core's deadline wake is foreign after a core replace (`ReplaceableCoreActor`, `DemoActor.swift:246–279`) |
| Concepts `room` (`ConceptsTests.swift:129`) | a worker-returns save with a 5 s deadline, then an idle timer at 60 s that fires when `"deadline 60"` opens (`:161–163`) |
| GeneratedOrder (`GeneratedOrderTests.swift:284–288`, `:329–339`, `:408`) | a random open request's deadline gate is opened in any order; a random current timer's gate likewise ("timer instants are far from request deadlines, so their gates never meet") |

### 1.6 The benchmarks

`Sources/TurnsBench` (`main.swift`, `BenchMachine.swift`).
- **`park`** (`main.swift:77–82`) runs three sends per op:
  - `takeHold` makes a request holding key 1 with `deadline: .seconds(3600)` (`BenchMachine.swift:59`);
  - `held` parks behind it;
  - `releaseHold` cancels the request (`:61–64`), which releases the parked input.

  Per op that is one effect task, one deadline task, one cancel, one sweep, and the cancelled task's later hop to `deadlineFired`, which finds the request stale.
- **`BenchClock`** (`main.swift:12–24`) sleeps until cancelled, so no bench lets a deadline pass.
- **`request`** (`BenchMachine.swift:65–69`) makes a request **without** a deadline, so this item doesn't touch it. Its gap is the effect launch and hop (#621 item 3).
- **The counts.** After #624 (the issue's comment), `park` is 23201 instr/op against 3039 direct, and `request` is 13504 against 399. So `park`'s gap is about 20.2k: its effect costs roughly what `request`'s does (about 13k, item 3), and the deadline task and its cancel make up most of the rest.

## 2. Prior art

This is a classic problem: many timeouts, most of them cancelled before they fire.

- **Varghese and Lauck**, "Hashed and Hierarchical Timing Wheels: Data Structures for the Efficient Implementation of a Timer Facility" (SOSP 1987).
  - **What it is.** The reference taxonomy: an unordered list, an ordered list, a tree or heap (O(log n) start, O(1) expiry check), and timing wheels (O(1) start, stop and per-tick work).
  - **When a wheel pays.** For very many timers at a fixed resolution with a periodic tick.
- **Netty `HashedWheelTimer`.**
  - One worker thread and a wheel of `ticksPerWheel` buckets (512 by default), at a `tickDuration` (100 ms by default). Its documentation calls the timing approximate.
  - `newTimeout` goes through a queue into a bucket on the next tick.
  - `cancel()` puts the timeout on a `cancelledTimeouts` queue that the next tick processes: deferred deletion.
  - Netty's event loops schedule their own tasks differently: in a priority queue (a heap) whose tasks keep their heap index, so a cancel removes in O(log n).
- **Tokio's timer driver.**
  - A hierarchical wheel: 6 levels of 64 slots, at 1 ms resolution, with intrusive per-slot lists, so insert and cancel are O(1).
  - The driver parks the runtime until the next expiration and re-registers a `Sleep` that is reset.
- **The Go runtime's timers.**
  - A 4-ary min-heap per P, keyed by `when`. Since 1.14 a deleted or modified timer is marked rather than removed.
  - Since 1.23 the per-P `timers` keep a `zombies` count. Zombies are dropped when they reach the head (`cleanHead`), and the heap is rebuilt (`adjust`) when zombies pass a quarter of it.
  - The scheduler's netpoll sleeps until the earliest `when`, and adding an earlier timer wakes the sleeper (`wakeNetPoller`).
  - This is lazy deletion with amortized compaction, plus one sleeper re-armed only when the earliest instant moves earlier.
- **Java's `ScheduledThreadPoolExecutor`.**
  - `DelayedWorkQueue` is a binary heap whose tasks store their `heapIndex`.
  - By default a cancelled task stays in the queue until its delay elapses (lazy).
  - `setRemoveOnCancelPolicy(true)` (Java 7) removes it at once. It was added because lazy deletion of long-delay tasks retained memory, which a lazy design has to bound.
- **libuv and SwiftNIO.**
  - libuv keeps timers in a binary min-heap, and each loop iteration polls with the nearest timer as its timeout.
  - SwiftNIO's `SelectableEventLoop` keeps scheduled tasks in a priority queue (a heap), waits in the selector until the earliest deadline, and removes a task from the queue when its `Scheduled` is cancelled.
- **Swift.**
  - An actor has no run loop to block in. The equivalent of the poll timeout is one task that sleeps until the earliest deadline and then hops onto the actor.
  - The only early wake `TurnClock` offers is cancellation. So "re-arm" means cancelling that task and starting a new one. A wake signal raced against the sleep would need a second primitive per sleep, such as a task group or a child task.
- **Test clocks.** Point-Free's `swift-clocks` `TestClock` advances time with `advance(by:)`/`advance(to:)`, and resumes every suspended sleep whose deadline is at or before the new now, in deadline order. That is the model a single sleeper needs (§4.1).

**The shape that fits here.**
- **Why not a wheel.** A core holds a handful of deadlines (one per hold or gate in flight, one timer per key), not 10⁵. The tests need exact instants, not a tick's resolution. A wheel needs a periodic tick or Tokio's next-expiration search, which is more code for no gain at these counts.
- **The fit.** A **binary min-heap per core, keyed by (instant, arm order), with lazy deletion and amortized compaction (Go's zombies)**, and **one sleeper task per core, re-armed by cancel and restart only when an earlier instant arrives** (Go's `wakeNetPoller`, NIO's selector timeout).
- **Why per core.** The heap is then actor-isolated, with no lock. A per-process timer would need a lock and would still hop to each actor.
- **The alternative.** A sorted array (insert by binary search, pop from the end) would also work at these sizes. The heap is preferred because compaction rebuilds it in O(n) and stale entries otherwise make inserts O(n).

## 3. Design

### 3.1 State on the core

New stored state, actor-isolated like the rest. Each `var` carries the `@exclusivity(unchecked)` attribute under the existing condition (lint-turns `unchecked-state`).

- **`deadlines: DeadlineHeap`**, a `@usableFromInline` struct with `@inlinable` members, in a new `Sources/SwiftStateTurns/DeadlineHeap.swift`. Its elements are trivial (POD), so sifts copy no reference counts:
  ```swift
  struct DeadlineEntry {        // 24 bytes
      var instant: Int64        // TurnInstant.nanoseconds
      var order: UInt64         // the core's arm counter: ties fire in arm order
      var ticket: UInt64        // a RequestID's raw value, or a timer generation
      var isTimer: Bool
  }
  ```
  The order is (instant, order). The operations are `push`, `peek`, `pop`, `count` and `rebuild(keeping:)` (Floyd's O(n) heapify over the entries a predicate keeps).
- **`staleDeadlines: Int`**, entries invalidated and not yet removed. It is approximate on purpose, and §3.5 says how it is used.
- **The timer's input and key.** These move off the task: `rt.timers` becomes `[M.Key: (generation: UInt64, input: M.Input)]`, and `rt.timerKeys: [UInt64: M.Key]` maps a generation to its key. A replaced or dropped timer releases its input at once, even while its heap entry is still stale. `pendingCount(.timers)` counts `rt.timers` as before.
- **The sleeper:**
  - `sleeper: Task<Void, Never>?`, the one sleeping task;
  - `sleeperGeneration: UInt64`, bumped at each start;
  - `sleeperTarget: TurnInstant?`, the instant the current sleeper sleeps until;
  - `sleeperAwake: Bool`, true while a wake is being serviced on the actor.

Removed: `deadlineTasks` with `deadlineTasksForTesting`, `timerTasks`, `rt.deadlinesToCancel`, `rt.timersToCancel`, and both sweeps in `drainProducts` (`TurnActor.swift:467–481`). Removing the sweeps also takes two condition checks off every segment of every machine. A machine without deadlines then pays nothing per segment for this feature (`Notes/solutions/2026-11-21-a-feature-path-in-the-driver-costs-machines-that-do-not-use-it.md`).

### 3.2 Insert: the driver arms an entry

The arming stays where it is today, after the step's flush, so a request made and closed in one step is never inserted.
- **Requests and gates.** `launch` (`:522`) still checks `rt.open[id] != nil`, and `launchGate` (`:545`) is unchanged. Where they created a task, they call `armDeadline(instant, ticket: id.raw, isTimer: false)`.
- **Timers.** `arm` (`:555`) calls `armDeadline(instant, ticket: generation, isTimer: true)` when `rt.timers[key]?.generation == generation`.
- **`armDeadline`:**
  1. Push `(instant, nextArm, ticket, isTimer)`, after `nextArm &+= 1`.
  2. If there is no sleeper, start one until `instant`.
  3. Otherwise, if `!sleeperAwake` and `instant < sleeperTarget`, **re-arm**: cancel the sleeper and start a new one until `instant`. An equal instant doesn't re-arm: the sleeper will find it due.
  4. Otherwise do nothing. Either the sleeper sleeps until an earlier or equal instant, or it is being serviced, and the wake's return gives it its next target (§3.4).
- **Start a sleeper.** `sleeperGeneration &+= 1`, `sleeperTarget = instant`, then:
  ```swift
  let generation = core.sleeperGeneration, incarnation = core.incarnation, clock = core.clock
  core.sleeper = Task { [weak self] in
      var target = instant
      while true {
          // Woken early (cancelled) or on time, the actor re-checks: the generation, then each entry.
          await clock.sleep(until: target)
          guard let actor = self else { return }
          guard let next = await actor.timerWoke(target, generation: generation, incarnation: incarnation) else { return }
          target = next
      }
  }
  ```
  - **What the sleeper may touch.** It never reads or writes core state. It sleeps, hops and receives its next target as the wake's return value.
  - **Ownership.** It holds the actor weakly between hops, like today's tasks, and strongly only across the `timerWoke` call.
  - **A cancelled wake still hops.** The actor drops it by generation, at the cost of one extra hop per re-arm or deinit. The core's re-check, not the clock, decides, as today. It also keeps a replaced core's wake observable as foreign (§3.7).
- **What one op costs.** In the common case all deadlines share a duration, and the instants come in non-decreasing order, so an insert is a push and nothing else. In the worst case, strictly decreasing instants, it is one task per insert, which is today's cost plus a push.

### 3.3 Invalidation: cancel is a counter, not a task cancel

Every site that set `deadlinesToCancel` or `timersToCancel` now does `staleDeadlines &+= 1` instead:
- `closeRequest` with `hasDeadline` (`Runtime.swift:251`);
- `removeFollowUp` with `hasDeadline` (`:196`);
- `gateReturned` clearing `hasDeadline` (`TurnActor.swift:276–279`);
- a timer replace (`Turn.swift:181`), `dropTimer` and `endAll`'s timer clear. These also remove `rt.timerKeys[old generation]`.

The heap and the sleeper aren't touched. The guarantee **"an abandoned request's deadline never fires"** is unchanged in kind:
- the request leaves `rt.open` (the gate's `hasDeadline` clears, the timer's generation changes) in the same synchronous segment as the abandonment;
- the wake re-checks that before it acts (§3.4).

The ticket is the request id or the timer generation. Neither is ever reused in a core, so an entry can't be mistaken for a later request. This is the `GenerationTable` shape (`Notes/solutions/2026-11-05-callback-outlives-its-instance-clears-by-key.md`): the entry never clears or acts on state by key alone.

### 3.4 A wake: each due entry is its own input, in instant order

`timerWoke(_ target: TurnInstant, generation:, incarnation:) -> TurnInstant?` is a new actor entry. It is `@inlinable` internal, not public.

1. **A foreign incarnation** is counted (`foreignCompletions`), reports `.foreignCompletion` and returns nil.
2. **A superseded sleeper.** If `generation != core.sleeperGeneration`, the wake comes from a sleeper that a re-arm, `endAll` or deinit replaced. It counts in a package test counter and returns nil, so that task ends. The current sleeper owns every entry.
3. **`sleeperAwake = true`.** Take the **due list**: pop every entry with `instant <= target`, in (instant, order) order, up to the per-wake cap (§3.6). Entries a step inserts during this wake aren't in the list, even if their instant is at or before `target`.
4. **Step the due entries, each as its own entry and batch**, as `deadlineFired` and `timerFired` do today, with #738 round 4's stale-arrival rule (rev 3):
   - **check the ticket at its turn, before `beginEntry()`**, not when the list was taken. A request is live if `rt.open[id] != nil`, a gate if `gateDeadlineLive(id)`, a timer if `rt.timers[key]?.generation == ticket`. A stale entry reports `.staleDeadline` or `.staleTimer` and takes no entry: no `beginEntry()`, no ordinal, no `entryBoundary()`. So a stale entry counts the same whether the wake reaches it, a compaction drops it, or `endAll` empties the heap;
   - for a live entry, `beginEntry()`, so the next `Turn.now` reads the clock (and, with the post lane, its mail steps first). Then **re-check**, because that mail can have closed the request or replaced the timer: stale now, it reports the diagnostic and returns through the epilogue;
   - still live: `entryBoundary()` where the lane has it, then act. A request closes with `.deadline`, a gate closes its follow-up, a timer steps its input as a control input. Then `runSegment()`. Every return after a `beginEntry()` goes through `if core.rt.dirty { runSegment() }` (#725's rule).
   - **The wake itself takes no ordinal.** Its hop is like a lane wake: the foreign and superseded checks (steps 1–2) and the due-list pop change no machine state.

   An earlier due entry's step that closes a later due request (for example `handleAbandoned(A)` cancels B at the same instant) makes B stale at its turn.
5. **The next target.** `sleeperAwake = false`. Drop stale entries off the head (Go's `cleanHead`, §3.5), then peek.
   - Empty heap: clear `sleeper` and `sleeperTarget`, and return nil. The task ends, and a later insert starts a new one.
   - Otherwise `sleeperTarget = head.instant`, returned. The sleeper sleeps until it. If that instant has passed, the sleep returns at once, and so does the hop: one per distinct late instant.

**What stays the same.**
- A fired deadline steps as its own input, in its own batch, with its own clock read on first use.
- `handleAbandoned(id, .deadline)` steps in that batch's loop, as today.
- An abandoned request's deadline does nothing.

**What is now defined that wasn't.**
- **Order.** Deadlines and timers fire in instant order, and entries at one instant fire in arm order. Today each had its own task, so equal or near instants had no order.
- **Interleaving.** Due entries of one wake run back to back in one actor job, as separate batches, so no other entry interleaves between them, up to the cap. Today another entry could.
- **Due rule.** The wake uses `target`, the instant slept for, and reads no clock. It needs no clock read, so the clock-read counts that tests 26, 30 and 32 pin don't move. The cost is that a late wake fires only entries at or before `target`, and later-but-passed ones take one more immediate sleep and hop each (Q3).

### 3.5 Compaction

- **What a stale entry costs.** It stays in the heap until it reaches the head or a compaction. For `park` that is every entry: 3600 s deadlines, each cancelled within the op.
- **The bound.** In `armDeadline`, before the push, if `staleDeadlines >= 64 && staleDeadlines * 2 >= deadlines.count`, rebuild the heap keeping only valid entries and set `staleDeadlines = 0`. The validity check is the same one a wake makes. So the heap holds at most `max(64, 2 × live) + 1` entries. The O(n) rebuild runs after at least n/2 invalidations, so it is amortized O(1) per invalidation (Go 1.23's quarter rule, with a floor so small cores never compact). Q4 asks about the constants.
- **The head.** A wake drops stale heads before it peeks (step 5).
- **No re-arm.** A compaction doesn't cancel the sleeper even if it removed the sleeper's target. The sleeper wakes early, finds nothing due, and sleeps until the new head: one wasted hop, instead of a task per compaction.
- **Diagnostics.** A stale entry that is compacted, or dropped by `endAll`, emits nothing. One the wake reaches at its instant emits `.staleDeadline` or `.staleTimer`, as a woken stale task does today (§6).

### 3.6 The per-wake cap

A wake steps at most `maxFiresPerWake` due entries, and then returns `target` itself as the next target. The sleeper's sleep returns at once and hops again, so other entries queued on the actor run in between.
- **Why.** Without it, ten thousand deadlines at one instant would run ten thousand batches in one actor job. That is the same starvation that `maxReleasesPerBatch` prevents for releases, but the two bounds stay separate.
- **Who owns the rest.** The remainder has an owner, the returned target, so a capped wake can't strand it (`Notes/solutions/2026-11-20-a-budget-break-strands-the-work-kinds-after-it.md`).
- **The value.** `maxFiresPerWake = 64`, a fixed internal constant (decided, rev 2). It isn't `maxReleasesPerBatch`: that knob bounds parked releases per batch, and tying the two would make release fairness and timer fairness move together. It isn't public; a later need for a knob is its own change.

### 3.7 Stop, end and lifetime

- **`endAll`** is terminal: every request, follow-up and timer closes, and no key can start again, so no entry can ever be live again.
  - `Turn.endAll` itself does the stop, next to `rt.timersToArm.removeAll()` (`Turn.swift:97`): it empties the heap, sets `staleDeadlines = 0`, cancels the sleeper, bumps `sleeperGeneration` and clears `sleeper` and `sleeperTarget`. That is synchronous and runs once, so no segment pays a check for it. Cancelling a task from inside a step touches no machine state; the alternative, a flag for the driver, would be one more per-segment check.
  - Pending deadlines are dropped, and the cancelled sleeper's wake is superseded.
  - `launch` and `arm` after `endAll` find nothing to arm: no request can be open and no timer current.
- **`close`** changes nothing: requests stay open and their deadlines fire.
- **The core's deinit** cancels `sleeper`, replacing the two loops at `TurnCore.swift:251–252`. The cancelled sleep returns, `self` (the actor) may still exist, and the wake hops.
  - The actor released: `[weak self]` is nil and the task ends.
  - A replaced core (`ReplaceableCoreActor`): the hop reaches the actor with the old incarnation and is foreign, as today (FollowUp 34).
- **Liveness.** As today, a sleeper doesn't keep the actor alive, and an effect's task does.

### 3.8 The reentrancy rule

The sleeper is outside a turn. It holds no state, and its only act is the hop.
- **Two tickets.** Its wake carries the incarnation and the sleeper generation, which are checked first. Each entry carries the request id or timer generation, which is checked in the batch that would act on it, the same segment as the act.
- **No mutation outside a turn.** No keeper or machine state is mutated outside a turn. The heap is driver state, and only actor-isolated synchronous code changes it: the driver between steps (`armDeadline`, `timerWoke`, compaction), with one exception. `Turn.endAll` empties the heap and cancels the sleeper from inside its step (§3.7). That is synchronous, isolated and terminal: no later step can arm an entry, and touching the heap from a step reads no machine state.

This adds no exception to `CLAUDE.md`'s list.

### 3.9 The post lane (#725, PR #738)

- **The fire doesn't go through the lane.**
  - The lane carries the machine's `LaneReport`, opt-in and folded away for `Never`. Deadlines and timers exist for every machine.
  - A lane report steps before every next step, which would move a deadline ahead of queued sends. That is a semantics change with no need behind it: a deadline is "when the timer's hop lands", like any entry.
  - The lane has a capacity and refuses past it, and a deadline must never be refused.
  - The sleeper's wake already is one hop, and the lane's wake would be one more.
- **The wake is an ordinary entry.** In #725 §3.4's entry table it replaces the `deadlineFired` and `timerFired` rows. Each due entry's `beginEntry()` runs the lane helper (after the incarnation and generation checks), and every return, stale ones included, goes through the epilogue `if core.rt.dirty { runSegment() }` (step 4). #725's test 15, "a report-induced stale deadline", carries over: its `deadlineFired(R)` becomes a wake whose due entry is R.
- **Replay.** Each live due entry is one batch and takes one ordinal, as a live `deadlineFired` does. A stale one takes none (step 4), so where the scheduler lands a wake that reaches only stale entries doesn't move any mail. The instant-then-arm order makes a run's sequence of fires deterministic given where each wake lands.
- **What the one timer removes by construction.** Today every request with a deadline that closes another way leaves a cancelled task that still hops to `deadlineFired` (#738's epilogue cancel), and a replaced or ended timer leaves one that still hops to `timerFired`. With one sleeper no cancelled deadline hops: the closed entry stays in the heap without a task, and is compacted or reached at its instant as a stale entry. That removes the scheduler-placed stale `deadlineFired` and `timerFired` arrivals #738 round 4 found. It doesn't remove the need for its rule. A stale entry the wake reaches must still take no ordinal (step 4). `callerCancelled` (a cancellation for a call already answered, or the orphan of a pre-cancelled `sendAndWait`) isn't touched by this PR. And until this PR lands, the per-deadline tasks are what #738 fixes.
- **Merge order (rev 3).** #738 merges first; this PR then takes main with it (a merge, or a rebase before the first push), so the entry table and the stale-arrival helpers come from #738. This PR keeps its diff away from the lane and mailbox code: it replaces `deadlineFired` and `timerFired` with the wake, and reuses #738's stale-check shape there.

## 4. Tests

The tests use hold points and events, never timing. Each new wait is a `waitUnlessCancelled` or one of the hang-bound helpers, so a regression fails within the bound instead of parking the run (`Notes/solutions/2026-11-21-a-hang-bound-cannot-end-a-wait-that-ignores-cancellation.md`).

### 4.1 The test clock becomes monotonic

The clock is already injected (`TurnClock`, `TestClock`), so no new seam is needed in the core. What has to change is the test clock's model.
- **Why.**
  - Independent per-instant gates let a test pass time 60 while 5 hasn't passed. With one sleeper per core, a live deadline at 60 waits behind any entry the sleeper sleeps for, a stale one at 5 included, until 5 passes. In real time it always has.
  - Concepts `room` shows it: the 5 s save deadline, completed and stale, stays the head, and opening `"deadline 60"` alone fires nothing.
  - GeneratedOrder opens a random open request's gate, which is "deadline 9 passes before deadline 3", impossible in real time.
- **The new model, after `swift-clocks`' `TestClock`.**
  - `release(through: TurnInstant)` raises a horizon and wakes every sleep whose instant is at or before it, in instant order. A later sleep until an instant at or before the horizon returns at once.
  - `advance(to:)` is `set` plus `release(through:)`.
  - `set(seconds:)` stays: it moves `now` only, for "the fire ran late" (27). It never moves `now` backwards: a set below the current `now` stops the test (`precondition`, with the two values in the message). `advance(to:)` checks the same. Test 30, which set 2 and then 3, already moves forward; any site found moving back is fixed in the commit that converts it.
  - The `"woke deadline N"`, `"cancelled deadline N"` events stay. A sleep counter (`sleeps`, and `sleepsInFlight`) is added.
  - A hold point: `holdAfterWake(N)` makes the sleep that wakes for N wait at `"resume deadline N"` (cancellable) before it returns. That forces a woken sleeper's hop to land after other entries.
- **The call sites.** Every `f.open("deadline N")` becomes `clock.release(through: .seconds(N))`, or `advance(to:)` where the test also set `now`. That is about 30 sites in the files of §1.5.

### 4.2 Existing tests: what changes and why

| Test | Change |
|---|---|
| ClockAndTimer 26 | The replace no longer cancels a sleep. `reach("cancelled deadline 6")` becomes: release through 6, then `reach("stale timer #1")` (the replaced timer's entry, reached at 6). The log is unchanged, and the stale-timer count stays 2. |
| ClockAndTimer 27 | Ending the key no longer cancels the next sleep, so `"cancelled deadline 10"` goes. Instead, `release(through: 10)` reports `"stale timer #1"`. `!woke deadline 4/6` stays. |
| ClockAndTimer 29 | Part 3: a cancelled request no longer cancels a sleep. Release through 9, then `"stale deadline #2"`. The counts are unchanged (2, 1). The test's name keeps "wake re-check". |
| ClockAndTimer 30, FollowUp 32 | Gate opens become releases. The clock-read counts are unchanged, because the wake reads no clock (§3.4). |
| Lifetime `timerDoesNotRetain` | One sleep for both: `"cancelled deadline 2"` only, and `clock.sleeps == 1`. The name stays. |
| Lifetime `effectRetainsOnlyWhilePerforming` | Unchanged except the release. |
| OrderedChecks 3, 4, 9 | Gate opens become releases. |
| OrderedChecks 18 | `endAll` drops the heap and cancels the sleeper (§3.7): `"cancelled deadline 9"` stays, and `"stale deadline #1"` becomes count 0 (the superseded wake does nothing). Releasing through 9 later wakes nothing. The comment is rewritten. |
| FollowUp 8, 19 | Releases. In 19, A's consumed entry is reached at 5 (`"stale deadline #1"`, unchanged). |
| FollowUp 28 | Rename to "a gate's return invalidates its deadline and keeps a live request's deadline, which still fires". No `"cancelled deadline 5"`. Release through 5 gives `"stale deadline #1"`. `!"cancelled deadline 7"` stays, then release through 7 fires the hold's abandonment. |
| FollowUp 29 | `deadlineTaskCount()` becomes `liveDeadlinesForTesting` (2, then 1). `"cancelled deadline 5/11"` become `"stale deadline #n"` at their releases. |
| FollowUp 34 | Unchanged in shape: the deinit-cancelled sleeper's wake is foreign (§3.7), then the gate return. Foreign count 2. |
| Concepts `room` | `advance(to: 60)` releases the stale 5 s entry and the timer. |
| GeneratedOrder | §4.4. |

### 4.3 New tests (a new `DeadlineTimerTests.swift`, and `DeadlineHeapTests.swift`)

1. **The heap** (pure, no actor). Seeded random push, invalidate and pop against a sorted reference: pops come in (instant, order) order, and a rebuild keeps exactly the valid ones. It runs under a fixed seed set, as GeneratedOrder does.
2. **One sleeper.** Arm deadlines at 5, 9, 9 and 12 and a timer at 7, in that order: `sleeps == 1`, one sleeper task started (`sleeperStartsForTesting == 1`). Releasing through 12 steps them in instant then arm order, each in its own batch: the log, plus one clock read per batch whose step reads `now`.
3. **Re-arm on an earlier insert.** Arm 9, then 5: `"cancelled deadline 9"`, and the sleeper sleeps until 5. Release through 5 fires only the 5. Release through 9 fires the 9. `sleeperStartsForTesting == 2`, and the superseded counter is 1.
4. **A superseded wake that woke on time** (`holdAfterWake(9)`). Arm 9, release through 9, and hold the sleeper at `"resume deadline 9"`. Then a send arms 5, which re-arms: the held task is cancelled to no effect, and a new sleeper starts for 5. Resume. The old wake is superseded and fires nothing, even though 9 has passed. Release through 5: the log is 5, then 9, in that order.
5. **An abandoned request's deadline never fires, for each closer**: `cancel`, `end`, a supersede, a completion, `endAll`, and a request closed in the step that made it. Each is closed before the release, and nothing steps for it at the release (`.staleDeadline`, or nothing for `endAll`). The completion case also runs with the wake held after waking (`holdAfterWake`) and the completion landing before it resumes: the close and the wake's re-check meet in that order.
6. **The re-check is per entry.** A and B are due at 5, and `handleAbandoned(A)` cancels B. B is stale at its turn: no second abandonment, `.staleDeadline` once.
7. **Inserts during a wake aren't due in it.** A's abandonment step makes a request with deadline 0 s (instant = the batch's now, at or before the wake's target in the test clock). It isn't stepped in A's wake: the next sleep is for its instant (`sleeps` goes up), and it fires on that wake.
8. **The cap.** 66 deadlines at 5, on the demo actor (`maxReleasesPerBatch: 16`): the first wake steps 64, and a send queued by the first one's flush steps before the 65th. The wake count is 2 (a package counter). A second run with `maxReleasesPerBatch: 1` gives the same 64, so the cap doesn't follow the release knob.
9. **Compaction.** Arm and cancel 200 deadlines at 3600 s, one live at 10 s in the middle: the heap count stays at or below `max(64, 2 × live) + 1` throughout, and the live one still fires at 10. Mixed instants after a rebuild still fire in order.
   - **The wasted hop.** A variant makes the sleeper's target a stale entry at 5 (arm 5, arm 10, cancel 5, then enough arm-and-cancel at 3600 s to trigger a rebuild). The rebuild removes 5, and the sleeper isn't re-armed: `sleeperStartsForTesting` stays 1, and no `"cancelled deadline 5"`. Releasing through 5 gives one wake (`timerWakesForTesting` up by 1) that steps nothing and emits no `.staleDeadline`, because the entry is gone. The next sleep is for 10 (`"deadline 10"` is the next sleep's gate). Releasing through 10 fires the live one.
10. **`endAll` stops the timer.** Live deadlines and a timer, then `endAll`: heap 0, the sleeper cancelled, and releasing through every instant steps nothing.
11. **A periodic timer reuses the sleeper.** A 2 s periodic timer over five fires: `sleeperStartsForTesting == 1`, `sleeps == 5`.
12. **A replaced or dropped timer releases its input at once.** Arm a timer, replace it, arm another key's timer and end that key, then supersede a third. After each step, the DEBUG `liveTimerInputsForTesting` equals the number of current timers, while the stale heap entries are still there (`deadlines.count` larger). So no stale entry holds an input until its instant or a compaction. It is `#if DEBUG`, like `gateLaunchesForTesting`.

### 4.4 GeneratedOrder

Time becomes monotonic in the harness. Two ops change, `deadline` (`:284–288`) and `fire` (`:335–339`):
- **The op.** It picks a pending item as today (a random open request, or a current timer), computes its instant and calls `clock.advance(to: instant)`. Every pending item at or before that instant is due: open requests whose deadline instant is at or before it, and current timers likewise. The harness waits for each one's note (`"abandoned s"`, `"fired s"`), without assuming an order.
- **Instants.** The harness records each request's deadline instant as the clock's `now` at its `startHold` plus `seq` ns.
- **The model's timers.** `OrderModel`'s `.arm` moves from the absolute `TurnInstant(nanoseconds: seq)` (`OrderModel.swift:190`) to `turn.now + .nanoseconds(1_000_000 + seq)`, so a timer armed after an advance isn't due at once.
- **The mirror is unchanged.** It already accepts a deadline abandonment of any open request (`OrderModel.swift:282–286`).
- **What is lost.** The orders removed are the impossible ones (a later instant passing first). Requests made at different `now`s with different durations still give every relative order of creation and expiry.
- **The comment** at `:1–13` is updated.

### 4.5 Mutants, each with the test that kills it

| Mutant | Killed by |
|---|---|
| no re-arm on an earlier insert | 3 (the 5 never fires before 9 is released; the hang bound fails it) |
| the sleeper-generation check removed | 4 (9 fires before 5) |
| the per-entry ticket check removed (abandons a closed request) | 5, 6, ClockAndTimer 29 |
| the ticket checked once for the whole due list | 6 |
| the due list re-read until the head passes `target` (inserts fire in the same wake) | 7 |
| all due entries in one batch (one `beginEntry`) | 2 (clock reads), ClockAndTimer 30 |
| the cap removed | 8 |
| the capped wake returns the next instant instead of `target` (remainder stranded) | 8 (the hang bound) |
| compaction keeps nothing, or drops live entries | 9 |
| a rebuild that re-arms the sleeper when it removes the target | 9's wasted-hop variant (`sleeperStartsForTesting == 2`, `"cancelled deadline 5"`) |
| a wake that finds nothing due drops the next target (returns nil and ends the sleeper) | 9's wasted-hop variant (the live entry at 10 never fires; the hang bound fails it) |
| compaction never runs | 9 (the count bound) |
| `endAll` leaves the heap and sleeper | 10, OrderedChecks 18 |
| the sleeper captures the actor strongly | Lifetime `timerDoesNotRetain` |
| a cancelled wake exits without hopping | FollowUp 34 (no foreign deadline) |
| a timer's input kept on the heap entry instead of `rt.timers` (released only at its instant or a compaction) | 12 |
| the sweeps left in (dead code) | none by behavior: the §5 gated cells |

The suite runs in all three modes (`swift test`, the release mode with `-DTURNS_EXCLUSIVITY_CHECKED`, and the release default), with the generated-order fixed seeds and a `TURNS_SEEDS=2000` local run reported in the PR.

## 5. A/B

### 5.1 Step 0 result (rev 3): continue

Host run at base `3bceb649`, archive `arch-turns-park-step0-2026-11-22b`, Swift 6.2.4, `perf stat` and `perf record -e instructions:u` (call graphs `--call-graph fp --user-callchains`; the host runs `perf_event_paranoid` 2).
- **Counts.** `park` turn 23,234.12 instr/op (largest spread 0.684 %), `request` turn 13,553.39 (0.279 %).
- **The deadline's share, from the profile, × 23,234.** Every row is a deadline-only frame, checked against the callers report:
  - `swift_task_cancel`, with the sleeper's cancellation handler `CancelGate.cancel` that wakes it (children 5.09 %, called from the sweep in `drainProducts`): about 1,180;
  - the sleep's `withTaskCancellationHandler` (children 3.83 %, with `swift_task_addCancellationHandler` and the continuation init from `BenchClock.sleep`): about 890;
  - the deadline closure's `[weak self]` (`swift_weakInit` → `formWeakReference` 1.06 % self, from the launch inlined in `drainProducts`; `swift_weakLoadStrong` 0.94 %, from the deadline closure): about 465;
  - the deadline task's creation, one of two per op: about 1,010 at `request`'s one-create cost, about 1,680 at half of `park`'s `swift_task_create_common` children (14.45 %).
- **Floor: about 3,550 instr/op**; with the unquantified rest (the cancelled task's wake, hop and `deadlineFired`, its completion and deallocation, the `deadlineTasks` insert and removes, the sweep's `Array(keys)`) the estimate is 4,500–5,000. Above the 2k floor: continue. The target below (≥ 2,000, and > 3 × spread, about 480) is reachable at the floor after the heap's 100–200.
- **`park` − `request` bounds nothing.** `request` is a call with a completion (`ProcessOutOfLineJob` 68.6 % and `TurnActor.complete` 25.5 % children) that `park` doesn't make, so the 9,681 difference is neither an upper nor a lower bound.
- The children frames above `swift_job_run` are unwinder artifacts (a non-symbol root, small integers as symbols); the rows used here are below them, and the flat reports agree.

**Tier:** a host A/B. This change exists to move `park`'s numbers.

**Step 0, before any code.** `perf record -e instructions:u` of `park` (turn side) at the base, by symbol. It gives the deadline's share: task create and cancel, `BenchClock.sleep` and `CancelGate`, the cancelled task's hop and `deadlineFired`, the `deadlineTasks` dictionary, and the sweep. That share is the most this PR can save. Below 2k instr/op the PR stops and reports instead (Q1).

**The procedure** is the one #723 and the follow-ups plan used, on the measurement host, holding the measurement lock:
- `perf stat -e instructions:u`, in a throwaway container from the pinned `swift:6.2.4-noble` image;
- base is the merge base, head is the PR head, both built `swift build -c release` in that container, with `swift --version` recorded;
- 5 runs per cell and side, alternating, per-op = (n − the n = 0 run) / n;
- wall time is reported, not gated.

**The cells.**
- **Target: `park`** must fall by at least 2,000 instr/op and by more than 3 × the base's spread. The expectation is about the step-0 share minus the heap's cost: roughly 100–200 instructions per op for the push, plus the amortized compaction.
- **Gated, must not regress** (head above base by more than max(0.5 %, 3 × base's spread)): `idle` (the control), `emit`, `call`, `request`, `read1`. `emit` and `call` should fall slightly, by the two per-segment sweep checks.
- **Recorded:** `follow-up`, `follow-up-join`, `held-lookup`. A rise is explained in the PR.
- **New, recorded (decided):** `park-64`, 64 holds outstanding then released, per hold. It shows the heap at more than one live entry. It needs a second bench machine input, so it is its own commit.

The PR body carries the table with both SHAs and both `swift --version` outputs.

## 6. Public API

No public declaration is added, removed or changed. Behavior and documentation changes on public surface:
- **`TurnDiagnostic.staleDeadline` and `.staleTimer`** (`TurnCore.swift:38–43`). Their doc comments change: "the core's timer reached the entry of a request, follow-up gate or timer that had already closed or been replaced, and did nothing".
  - A closed request no longer wakes a sleep early, so the diagnostic comes at the entry's instant, or never: compacted, or dropped by `endAll`.
  - Code that waits for `.staleDeadline` right after a cancel would now wait until the instant. In this repository that is only the tests in §4.2.
- **`TurnClock`** (`Values.swift:205–213`). The sleep's doc contract is tightened to "returns no earlier than `instant`, unless its task is cancelled". The WorkedExample clock's comment (`WorkedExample.md:156`) says the same, and its `Task.sleep(until:clock:)` already meets it. The wake fires on its target without reading the clock (§3.4), so a clock that returned early would fire deadlines early. Today's per-deadline tasks relied on the same thing without stating it. A core has at most one sleep in flight, plus a superseded one finishing, instead of one per deadline and timer. Cancelling a request no longer cancels a sleep. One sentence goes into its doc comment.
- **Order.** Deadlines and timers fire in instant order, entries at one instant in arm order, each in its own batch, and up to the cap with no other entry between them. The docs gain this, in `docs/turns/README.md` § "Timers and the clock" and its `.zh-TW.md`, in the DocC `CoreConcepts.md`, and in `TurnActor`'s protocol doc (`TurnActor.swift:5–9`: "a deadline's or a timer's task" becomes "the core's timer task").
- **Package (not public).** `deadlineTasksForTesting` is removed. Added: `liveDeadlinesForTesting`, `sleeperStartsForTesting`, `supersededWakesForTesting`, `timerWakesForTesting`, and the DEBUG `liveTimerInputsForTesting`.
- **No new `TurnStats` field and no new `TurnDiagnostic` case** (decided, rev 2). The tests use package hooks. The diagnostics' docs say that a compacted or `endAll`-dropped entry emits nothing.

The PR body's "Public API" section lists the two diagnostics' doc changes and the `TurnClock` sentence as behavior changes, with "no source break".

## 7. Steps

One SwiftStateTurns PR (core path), after L2d-3 and step 0's numbers (Q1, decided). The commits:
1. `DeadlineHeap` and its unit tests.
2. Request and gate deadlines on the one timer: the core state, `armDeadline`, `timerWoke`, compaction, the stop from inside `Turn.endAll`'s step (§3.7, §3.8), and deinit. The sweeps for deadlines are removed. `TestClock`'s monotonic model, the request and gate tests of §4.2, and new tests 2–10 without the timer parts.
3. Timers on the same timer: `rt.timers` with the input, `rt.timerKeys`, the timer sweep removed, the timer tests of §4.2, and new test 11.
4. GeneratedOrder's monotonic ops and `OrderModel`'s relative timer instants.
5. Docs (§6) and, if the work turns one up, a `Notes/solutions` entry with its index row. A likely candidate: "a test clock with independent per-instant gates can't drive a single sleeper". Plus the plan index row.

Commit 6: the `park-64` bench, a recorded cell (decided, rev 2).

It can land before or after #738. Whichever is second adapts the entry table (§3.9).

## 8. Questions for the maintainer

1. **The issue's gate (decided by the maintainer, 2026-11-21).** #621 says items 2–4 wait for an A/B showing that an adopter puts holds or requests on a hot path. No adopter on `main` uses `TurnCore` deadlines yet (#546 is moving the keeper and the transport). Decided: do it now as foundation work, right after L2d-3; step 0's attribution (`perf record` of `park` at base) comes first, and the `park` −2k instr/op floor is the stop rule.

Decided in rev 2: Q2 (overturned: a fixed internal 64 per wake), Q3 (fire on `target`), Q4 (internal constants: half, with a floor of 64), Q5 (`park-64` recorded, its own commit), Q6 (keep the diagnostics, no new case), Q7 (timers in this PR, commit 3).
