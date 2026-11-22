// The adopter's side: the actor that owns a core, its entries, and the driver.

/// An actor that runs a machine on a `TurnCore`.
///
/// The core's timer task (one per core, for every deadline and timer) doesn't keep the actor
/// alive: it holds it weakly, so a periodic timer doesn't outlive the actor's last owner. An
/// effect's task does, until its result has been handled, so launched work is never dropped.
/// Released with no effect in flight, the actor and its core go away, and the core cancels its
/// timer task. A `sendAndWait` still waiting then is a bug (a debug
/// assertion), so an adopter ends its keys (`endAll`) and answers its callers first.
public protocol TurnActor: Actor {
    /// `PlainData`: only a machine that `@PlainData` checked can be run.
    associatedtype M: TurnMachine & PlainData
    /// A stored `let` (a lint checks it; the core's incarnation covers what a replaced core
    /// could otherwise do).
    var core: TurnCore<M> { get }
    /// The asynchronous work of an effect, off the actor. It doesn't throw: nil means nothing to
    /// report, and an error is a case of the input. Its result comes back as an input.
    @concurrent nonisolated func perform(_ effect: M.Effect) async -> M.Input?
    /// The synchronous sink of a step's outputs, called between steps.
    func flush(_ outputs: consuming [M.Output])
}

extension TurnActor {
    /// Submits `input`. Steps now when the core is idle; queued when a step or batch runs.
    /// Refused (closed, withdrawn, over the queue limit), it is dropped and counted.
    @inlinable public func send(_ input: M.Input) {
        submit(input, caller: nil)
    }

    /// Submits `input` and waits for its reply (`Turn.reply`). Refused, it throws `TurnError`.
    /// `cancellation` says what this call's task cancellation does; see `CallerCancellation`.
    @inlinable public func sendAndWait(_ input: M.Input, cancellation: CallerCancellation) async throws -> M.Reply {
        let core = self.core
        core.nextInput &+= 1
        let id = InputID(raw: core.nextInput)
        switch cancellation {
        case .ignoresCancel:
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<M.Reply, any Error>) in
                core.waiters[id] = continuation
                self.submit(input, caller: id)
            }
        case .cancelsCall:
            // Through `read`, as every access to the machine outside a step: from inside a step
            // (a task started synchronously on the actor) it stops instead of reading mid-write.
            let isControl = core.read { machine in
                if case .control = machine.inputPolicy(for: input) { return true } else { return false }
            }
            if Task.isCancelled, isControl {
                // Cancelled before entry: a control input is still submitted and stepped,
                // but its caller doesn't wait. A reply from its step finds no waiter.
                core.counters.cancelledCalls += 1
                submit(input, caller: id)
                throw CancellationError()
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<M.Reply, any Error>) in
                    if Task.isCancelled, !isControl {
                        core.counters.cancelledCalls += 1
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    core.waiters[id] = continuation
                    self.submit(input, caller: id)
                }
            } onCancel: {
                Task { await self.callerCancelled(id) }
            }
        }
    }

    /// A synchronous collaborator's question, answered as a step. Between steps only: from
    /// inside a step it stops the process.
    ///
    /// Called outside a batch, what the answer's step produced (outputs, replies, effects) has
    /// left the core when this returns. Called from inside a batch (a collaborator the driver
    /// called between two steps), it leaves when that batch drains, after the return.
    @inlinable public func query(_ query: M.Query) -> M.Answer {
        let core = self.core
        if !core.inSegment { beginEntry() }
        let answer = core.stepAnswer(query)
        if !core.inSegment, core.rt.dirty { runSegment() }
        return answer
    }

    // MARK: Entries

    /// A new entry from outside: a new batch, so the next `Turn.now` reads the clock.
    @inlinable func beginEntry() {
        core.cachedNow = nil
    }

    @inlinable func callerCancelled(_ id: InputID) {
        let core = self.core
        guard let waiter = core.waiters.removeValue(forKey: id) else { return }
        _ = core.rt.withdraw(caller: id)
        core.counters.cancelledCalls += 1
        waiter.resume(throwing: CancellationError())
    }

    @inlinable func submit(_ input: M.Input, caller: InputID?) {
        let core = self.core
        if core.borrows < 0 || core.inSegment {
            core.queued.push((input, caller, core.scopeEndClock))
            // Made from inside a step (the machine borrowed for writing): not a step entry, so no
            // borrow stop. The batch that follows the step picks it up.
            core.rt.dirty = true
            return
        }
        beginEntry()
        admit(input, caller: caller)
        if core.rt.dirty { runSegment() }
    }

    /// `arrival`: a deferred input's scope-end clock when it arrived; nil when admitted on arrival.
    @inlinable func admit(_ input: M.Input, caller: InputID?, arrival: UInt64? = nil) {
        let core = self.core
        switch core.machine.inputPolicy(for: input) {
        case .control:
            core.step(input, caller: caller)
        case .normal(let hold, let scope, let token):
            if core.rt.closed {
                refuse(caller, .closed)
                return
            }
            if let token, token.isWithdrawn {
                refuse(caller, .withdrawn)
                return
            }
            if let arrival, let scope, let ended = core.scopeEndsWhileDeferred[scope], ended > arrival {
                // Its scope ended or was superseded while it was deferred.
                refuse(caller, .withdrawn)
                return
            }
            if let hold, core.rt.isBlocked(hold) {
                if core.rt.parkedCount >= core.queueLimit {
                    refuse(caller, .queueFull)
                    return
                }
                core.rt.park(Parked(input: input, caller: caller, scope: scope, token: token), behind: hold)
                core.rt.parkEvents += 1
                core.onDiagnostic?(.queued(total: core.rt.parkEvents))
                return
            }
            core.step(input, caller: caller)
        }
    }

    @inlinable func refuse(_ caller: InputID?, _ error: TurnError) {
        let core = self.core
        guard let caller else {
            core.counters.droppedSends += 1
            return
        }
        if let waiter = core.waiters.removeValue(forKey: caller) {
            waiter.resume(throwing: error)
        }
    }

    /// An effect's result. Never gated by `close`: only by its request being open.
    @inlinable func complete(_ id: RequestID?, _ input: M.Input?, incarnation: UInt64) {
        let core = self.core
        guard core.incarnation == incarnation else {
            core.counters.foreignCompletions += 1
            core.onDiagnostic?(.foreignCompletion)
            return
        }
        beginEntry()
        if let id {
            if let record = core.rt.open[id] {
                let waiting = core.rt.repliesAfter.removeValue(forKey: id)
                // The hold stays owned through the completion step, so a handover (a new request
                // on the same hold in that step) never leaves the key free in between.
                if let hold = record.hold { core.rt.held[hold, default: 0] += 1 }
                core.rt.closeRequest(id, nil)
                if let input { core.step(input, caller: nil) }
                if let hold = record.hold { core.rt.releaseHold(hold) }
                if let waiting { core.rt.replies.append(contentsOf: waiting) }
                core.rt.dirty = true
            } else {
                // The request closed before its worker returned: the worker has returned.
                core.rt.retire(id)
                if let input { core.stepStale(input) }
            }
        } else if let input {
            core.step(input, caller: nil)
        }
        runSegment()
    }

    /// The core's timer woke for `target` (#621 item 2, Notes/plans/2026-11-21-turns-shared-
    /// deadline-timer.md §3.4). It steps the entries due at `target`, each as its own entry and
    /// batch, in (instant, arm order), and returns the instant to sleep until next; nil ends the
    /// sleeper (nothing is armed, or the wake is foreign or superseded). The wake itself changes
    /// no machine state: only a live entry begins an entry.
    ///
    /// Its work is bounded twice: at most `maxFiresPerWake` live entries step, and at most
    /// `maxStalePopsPerWake` stale entries are popped. The rest is due at once, so the next wake
    /// follows without a sleep, and other work queued on the actor can run before it. A
    /// compaction runs before the due list is taken and after it is stepped, never while a due
    /// entry is outside the heap, so the stale count stays exact.
    @inlinable func timerWoke(_ target: TurnInstant, generation: UInt64, incarnation: UInt64) -> TurnInstant? {
        let core = self.core
        guard core.incarnation == incarnation else {
            core.counters.foreignCompletions += 1
            core.onDiagnostic?(.foreignCompletion)
            return nil
        }
        // A sleeper that a re-arm, `endAll` or the core's deinit replaced: the current one owns
        // every entry.
        guard core.sleeperGeneration == generation else {
            core.supersededWakesForTesting &+= 1
            core.onTimerWakeForTesting?(true)
            return nil
        }
        core.timerWakesForTesting &+= 1
        core.onTimerWakeForTesting?(false)
        core.compactDeadlinesIfStale()
        core.sleeperAwake = true
        // The due list is taken first: an entry a step arms during this wake isn't due in it,
        // even at or before `target`. A due entry already stale is popped here, reported, and
        // left out of the count of live entries.
        var due: [DeadlineEntry] = []
        var stalePops = 0
        while let head = core.deadlines.first, head.instant <= target.nanoseconds {
            if core.deadlineIsLive(head) {
                if due.count == TurnCore<M>.maxFiresPerWake { break }
                due.append(head)
            } else {
                if stalePops == TurnCore<M>.maxStalePopsPerWake { break }
                stalePops &+= 1
                if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
                core.onDiagnostic?(head.isTimer ? .staleTimer : .staleDeadline)
            }
            _ = core.deadlines.popFirst()
        }
        for entry in due {
            // `endAll` in an earlier entry's step stopped the timer: the rest is dropped.
            if core.sleeperGeneration != generation { break }
            fireDeadline(entry)
        }
        core.sleeperAwake = false
        if core.sleeperGeneration != generation { return nil }
        core.compactDeadlinesIfStale()
        // Stale heads after `target` are dropped silently, as a compaction drops them, within
        // the same budget. A stale head at or before it (armed and closed during this wake, or
        // past the budget) waits for the next wake, which reports it.
        while stalePops < TurnCore<M>.maxStalePopsPerWake, let head = core.deadlines.first,
              head.instant > target.nanoseconds, !core.deadlineIsLive(head) {
            _ = core.deadlines.popFirst()
            stalePops &+= 1
            if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
        }
        guard let head = core.deadlines.first else {
            core.sleeper = nil
            core.sleeperTarget = nil
            return nil
        }
        // At or before `target` (a capped wake's rest, or an entry armed during it): the sleep
        // returns at once, and other entries queued on the actor can run before the next wake.
        let next = TurnInstant(nanoseconds: head.instant)
        core.sleeperTarget = next
        return next
    }

    /// One due entry of a wake, live when the wake took it. The ticket is checked again here, at
    /// its turn, before the entry begins: an entry an earlier entry of this wake made stale (its
    /// request or gate closed, its timer replaced or dropped) only reports `.staleDeadline` or
    /// `.staleTimer`. A live timer steps its input as a control input. The timer stays in the
    /// runtime's table until after `beginEntry()`, as a request stays open until its close.
    @inlinable func fireDeadline(_ entry: DeadlineEntry) {
        let core = self.core
        if entry.isTimer {
            guard let key = core.rt.timerKeys[entry.ticket], let armed = core.rt.timers[key],
                  armed.generation == entry.ticket else {
                if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
                core.onDiagnostic?(.staleTimer)
                return
            }
            beginEntry()
            core.rt.timers.removeValue(forKey: key)
            core.rt.timerKeys.removeValue(forKey: entry.ticket)
            core.step(armed.input, caller: nil)
            runSegment()
            return
        }
        let id = RequestID(raw: entry.ticket)
        if core.rt.open[id] != nil {
            beginEntry()
            core.rt.closeRequest(id, .deadline)
            // The close counted this entry stale, but it has left the heap already.
            if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
            runSegment()
        } else if TurnCore<M>.usesFollowUps, core.rt.gateDeadlineLive(id) {
            // A follow-up's gate deadline: the follow-up closes unrun.
            beginEntry()
            core.rt.closeFollowUp(id, .deadline)
            if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
            runSegment()
        } else {
            if core.rt.staleDeadlines > 0 { core.rt.staleDeadlines -= 1 }
            core.onDiagnostic?(.staleDeadline)
        }
    }

    /// Arms a deadline entry on the core's one timer, after the step that made it was flushed.
    /// A sleeper is started when there is none, or re-armed when the entry is due before the
    /// instant it sleeps until and no wake is being serviced (that wake returns the next target).
    @inlinable func armDeadline(_ instant: TurnInstant, ticket: UInt64, isTimer: Bool) {
        let core = self.core
        // Not during a wake: its due entries are outside the heap and still counted.
        if !core.sleeperAwake { core.compactDeadlinesIfStale() }
        core.nextArm &+= 1
        core.deadlines.push(DeadlineEntry(instant: instant.nanoseconds, order: core.nextArm, ticket: ticket, isTimer: isTimer))
        if core.sleeper == nil {
            startSleeper(until: instant)
        } else if !core.sleeperAwake, let target = core.sleeperTarget, instant < target {
            core.sleeper?.cancel()
            startSleeper(until: instant)
        }
    }

    /// Starts the core's one sleeping task. It touches no core state: it sleeps, hops to
    /// `timerWoke` and sleeps until the instant that returns. Held weakly between hops, so it
    /// doesn't keep a released actor alive. Woken early (cancelled) or on time, it still hops,
    /// and the actor drops a superseded wake by its generation. Detached at `.medium`: it serves
    /// every later deadline and timer, so it takes neither the priority nor the task-locals of
    /// the step that happened to arm the first one.
    @inlinable func startSleeper(until instant: TurnInstant) {
        let core = self.core
        core.sleeperGeneration &+= 1
        core.sleeperTarget = instant
        core.sleeperStartsForTesting &+= 1
        let generation = core.sleeperGeneration
        let incarnation = core.incarnation
        let clock = core.clock
        core.sleeper = Task.detached(priority: .medium) { [weak self] in
            var target = instant
            while true {
                await clock.sleep(until: target)
                guard let actor = self else { return }
                guard let next = await actor.timerWoke(target, generation: generation, incarnation: incarnation) else { return }
                target = next
            }
        }
    }

    /// The core's one continuation job, a new batch. A segment schedules it when it leaves
    /// parked inputs past the release cap, or `.afterBatch` follow-ups due, or both; at most one is
    /// pending. It takes the follow-ups due at its start, in arm order, and runs a segment, which
    /// releases parked inputs under a fresh budget and steps those follow-ups, each re-checked.
    /// What its own steps arm, and what the cap leaves parked, goes to the next job.
    @inlinable func continueBatch() {
        let core = self.core
        core.continuationScheduled = false
        core.onContinuationJobForTesting?()
        beginEntry()
        if TurnCore<M>.usesFollowUps {
            for id in core.rt.dueFollowUps { core.followUpsToStep.push(id) }
            core.rt.dueFollowUps.removeAll(keepingCapacity: true)
        }
        runSegment()
    }

    /// Schedules `continueBatch`, unless one is already pending.
    @inlinable func scheduleContinuation() {
        let core = self.core
        if core.continuationScheduled { return }
        core.continuationScheduled = true
        core.counters.continuationJobs += 1
        Task { self.continueBatch() }
    }

    /// A follow-up's gate returned. The follow-up, if this arm's is still pending, becomes due
    /// now. The gate's own result steps first (a control input, as a `run`'s result), and its
    /// products drain as after any step; the follow-up steps after that, from the driver's loop,
    /// which re-checks that this arm is still pending (the result's step may have consumed it,
    /// ended its key or called `endAll`). A gate whose follow-up was already consumed or closed
    /// reports `.staleFollowUp`; its result still steps, and may arm new work.
    @inlinable func gateReturned(_ id: RequestID, _ input: M.Input?, incarnation: UInt64) {
        let core = self.core
        guard core.incarnation == incarnation else {
            core.counters.foreignCompletions += 1
            core.onDiagnostic?(.foreignCompletion)
            return
        }
        beginEntry()
        if let name = core.rt.followUpIDs[id], core.rt.followUps[name]?.waiting == true {
            core.rt.followUps[name]?.waiting = false
            if core.rt.followUps[name]?.hasDeadline == true {
                core.rt.followUps[name]?.hasDeadline = false
                core.rt.staleDeadlines &+= 1
            }
            core.followUpsToStep.push(id)
        } else {
            core.onDiagnostic?(.staleFollowUp)
        }
        if let input { core.step(input, caller: nil) }
        core.rt.dirty = true
        runSegment()
    }

    // MARK: Quiescence

    /// Pending work of `kinds`, of `key` (every key when nil): follow-ups armed and not yet
    /// stepped, consumed or closed; open requests; armed timers.
    @inlinable public func pendingWork(_ kinds: TurnWork = .followUps, of key: M.Key? = nil) -> Int {
        core.rt.pendingCount(kinds, of: key)
    }

    /// Tests: returns true once at most `atMost` of `kinds` are pending (of `key`, or every key),
    /// at once if that holds already. Checked at the end of each of the actor's synchronous
    /// segments, so a step that retires a follow-up and arms its successor never shows a gap.
    /// `endAll` closes every request, follow-up and timer, so a waiter never outlives an ended
    /// core's work. A cancelled waiting task returns false once its cancellation's hop to the
    /// actor is serviced, unless a segment met the condition first (then true); a call already
    /// satisfied when made returns true, even from a cancelled task. The default counts
    /// follow-ups only: a periodic timer is never quiet.
    @inlinable @discardableResult
    public func waitForQuiescence(_ kinds: TurnWork = .followUps, of key: M.Key? = nil, atMost: Int = 0) async -> Bool {
        let core = self.core
        // `fatalError`, not `precondition`: its message prints in release builds too.
        if atMost < 0 { fatalError("TurnCore: waitForQuiescence's atMost must not be negative") }
        if core.rt.pendingCount(kinds, of: key) <= atMost { return true }
        core.nextQuiescenceWaiter &+= 1
        let id = core.nextQuiescenceWaiter
        // Both closures reach the core through `self`: a closure inherits an actor instance's
        // isolation only when it captures that instance, and one that captured only `core` would
        // check and register off the actor, racing the segment that settles the waiters.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                self.registerQuiescenceWaiter(id, QuiescenceWaiter(kinds: kinds, key: key, atMost: atMost, continuation: continuation))
            }
        } onCancel: {
            Task { await self.quiescenceWaiterCancelled(id) }
        }
    }

    /// Registers `waiter`, or resumes it at once: re-checked here, because a cancellation or a
    /// settle may land between the wait's first check and this entry.
    @inlinable func registerQuiescenceWaiter(_ id: UInt64, _ waiter: QuiescenceWaiter<M>) {
        // The check and the entry must share the segment that settles waiters: off the actor,
        // a settle between them loses the wake.
        self.preconditionIsolated("TurnCore: a quiescence wait registered off its actor")
        let core = self.core
        if Task.isCancelled {
            waiter.continuation.resume(returning: false)
            return
        }
        if core.rt.pendingCount(waiter.kinds, of: waiter.key) <= waiter.atMost {
            waiter.continuation.resume(returning: true)
            return
        }
        core.onQuiescenceRegistrationForTesting?()
        core.quiescenceWaiters[id] = waiter
    }

    @inlinable func quiescenceWaiterCancelled(_ id: UInt64) {
        core.quiescenceWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    /// Wakes the waiters whose condition holds, in the order they started waiting.
    @inlinable func settleQuiescence() {
        let core = self.core
        if core.quiescenceWaiters.isEmpty { return }
        let reached = core.quiescenceWaiters.filter { core.rt.pendingCount($0.value.kinds, of: $0.value.key) <= $0.value.atMost }
        for id in reached.keys.sorted() {
            core.quiescenceWaiters.removeValue(forKey: id)?.continuation.resume(returning: true)
        }
    }

    // MARK: The driver

    /// Not recursive. After every step: outputs are flushed, replies published and effects
    /// launched, before the next step. Then one step at a time: an abandoned request, a queued
    /// send, a released queued input (at most `maxReleasesPerBatch` per batch).
    @inlinable func runSegment() {
        let core = self.core
        if core.inSegment { return }
        core.inSegment = true
        defer { core.inSegment = false }
        var budget = core.maxReleasesPerBatch
        var released = 0
        // Set once a releasable key is left at the cap: releases stop, due follow-ups still step.
        var capped = false
        while true {
            drainProducts()
            if !core.rt.abandoned.isEmpty {
                let (id, why) = core.rt.abandoned.removeFirst()
                core.stepAbandoned(id, why)
                continue
            }
            if let next = core.queued.pop() {
                admit(next.0, caller: next.1, arrival: next.2)
                if core.queued.isEmpty, !core.scopeEndsWhileDeferred.isEmpty {
                    core.scopeEndsWhileDeferred.removeAll()
                }
                continue
            }
            if !capped, let key = core.rt.nextReleasable() {
                if budget == 0 {
                    // The rest steps in a later batch, as the actor's own job. Until then the
                    // key counts as blocked: a new input for it queues behind the ones still queued.
                    scheduleContinuation()
                    // Follow-ups aren't parked inputs: the cap doesn't apply to them, so the ones
                    // this segment holds still step before it ends.
                    if !TurnCore<M>.usesFollowUps { break }
                    capped = true
                    continue
                }
                budget -= 1
                if let parked = core.rt.popParked(key) {
                    if let token = parked.token, token.isWithdrawn {
                        refuse(parked.caller, .withdrawn)
                    } else {
                        core.step(parked.input, caller: parked.caller)
                        released += 1
                    }
                }
                continue
            }
            if TurnCore<M>.usesFollowUps, let id = core.followUpsToStep.pop() {
                // Skipped when it was consumed or closed after its job took it.
                if let name = core.rt.followUpIDs[id], core.rt.followUps[name]?.waiting == false,
                   let record = core.rt.removeFollowUp(id) {
                    core.step(record.input, caller: nil)
                }
                continue
            }
            break
        }
        if released > 0 { core.onDiagnostic?(.batchEnded(released: released)) }
        if TurnCore<M>.usesFollowUps, !core.rt.dueFollowUps.isEmpty, !core.continuationScheduled {
            scheduleContinuation()
        }
        // Checked here, not in the call: an empty check inline costs a load, a call per segment
        // costs the whole frame.
        if !core.quiescenceWaiters.isEmpty { settleQuiescence() }
        core.rt.dirty = false
    }

    @inlinable func drainProducts() {
        let core = self.core
        while true {
            var progressed = false
            if !core.rt.outputs.isEmpty {
                var outputs: [M.Output] = []
                swap(&outputs, &core.rt.outputs)
                flush(outputs)
                progressed = true
            }
            if !core.rt.replies.isEmpty {
                var replies: [(InputID, Result<M.Reply, any Error>)] = []
                swap(&replies, &core.rt.replies)
                for (caller, result) in replies {
                    if let waiter = core.waiters.removeValue(forKey: caller) {
                        waiter.resume(with: result)
                    }
                }
                progressed = true
            }
            if !core.rt.withdrawn.isEmpty {
                var withdrawn: [InputID] = []
                swap(&withdrawn, &core.rt.withdrawn)
                for caller in withdrawn {
                    if let waiter = core.waiters.removeValue(forKey: caller) {
                        waiter.resume(throwing: TurnError.withdrawn)
                    }
                }
                progressed = true
            }
            if core.rt.closing {
                core.rt.closing = false
                for caller in core.rt.dropAllParked() {
                    if let waiter = core.waiters.removeValue(forKey: caller) {
                        waiter.resume(throwing: TurnError.closed)
                    }
                }
                progressed = true
            }
            if !core.rt.timersToArm.isEmpty {
                var timers: [PendingTimer<M>] = []
                swap(&timers, &core.rt.timersToArm)
                for timer in timers where core.rt.timers[timer.key]?.generation == timer.generation {
                    armDeadline(timer.instant, ticket: timer.generation, isTimer: true)
                }
                progressed = true
            }
            if TurnCore<M>.usesFollowUps, !core.rt.followUpGates.isEmpty {
                var gates: [PendingEffect<M>] = []
                swap(&gates, &core.rt.followUpGates)
                // A gate whose follow-up closed in the step that armed it isn't launched.
                for gate in gates {
                    if let id = gate.request, core.rt.followUpIDs[id] != nil { launchGate(gate) }
                }
                progressed = true
            }
            if !core.rt.effects.isEmpty {
                var effects: [PendingEffect<M>] = []
                swap(&effects, &core.rt.effects)
                for effect in effects {
                    launch(effect)
                }
                progressed = true
            }
            if !progressed { break }
        }
    }

    @inlinable func launch(_ pending: PendingEffect<M>) {
        let core = self.core
        let incarnation = core.incarnation
        let effect = pending.effect
        let id = pending.request
        // Held strongly: an effect, once launched, runs and its result is handled (a weak
        // capture would drop an effect whose task hadn't started when the actor was released).
        Task {
            let input = await self.perform(effect)
            self.complete(id, input, incarnation: incarnation)
        }
        if let id, let instant = pending.deadline, core.rt.open[id] != nil {
            armDeadline(instant, ticket: id.raw, isTimer: false)
        }
    }

    @inlinable func launchGate(_ pending: PendingEffect<M>) {
        let core = self.core
        let incarnation = core.incarnation
        let effect = pending.effect
        guard let id = pending.request else { return }
        #if DEBUG
        core.gateLaunchesForTesting &+= 1
        #endif
        // Held strongly, as an effect's task: a launched gate runs and its return is handled.
        Task {
            let input = await self.perform(effect)
            self.gateReturned(id, input, incarnation: incarnation)
        }
        if let instant = pending.deadline {
            armDeadline(instant, ticket: id.raw, isTimer: false)
        }
    }
}
