// The adopter's side: the actor that owns a core, its entries, and the driver.

/// An actor that runs a machine on a `TurnCore`.
///
/// A deadline's or a timer's task doesn't keep the actor alive: it holds it weakly, so a periodic
/// timer doesn't outlive the actor's last owner. An effect's task does, until its result has been
/// handled, so launched work is never dropped. Released with no effect in flight, the actor and
/// its core go away, and the core cancels its deadline and timer tasks. A `sendAndWait` still waiting then is a bug (a debug
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
            let isControl: Bool
            if case .control = core.machine.inputPolicy(for: input) { isControl = true } else { isControl = false }
            if Task.isCancelled, isControl {
                // Cancelled before entry: a control input is still submitted and stepped (rule 16),
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
        if core.inStep || core.inSegment {
            core.queued.push((input, caller))
            // Made from inside a step: the batch that follows the step picks it up.
            core.rt.dirty = true
            return
        }
        beginEntry()
        admit(input, caller: caller)
        if core.rt.dirty { runSegment() }
    }

    @inlinable func admit(_ input: M.Input, caller: InputID?) {
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

    /// A deadline's task woke. It abandons the request only if that request is still open.
    @inlinable func deadlineFired(_ id: RequestID, incarnation: UInt64) {
        let core = self.core
        guard core.incarnation == incarnation else {
            core.counters.foreignCompletions += 1
            core.onDiagnostic?(.foreignCompletion)
            return
        }
        core.deadlineTasks.removeValue(forKey: id)
        guard core.rt.open[id] != nil else {
            core.onDiagnostic?(.staleDeadline)
            return
        }
        beginEntry()
        core.rt.closeRequest(id, .deadline)
        runSegment()
    }

    /// A timer's task woke. It fires only if it is still its key's current timer.
    @inlinable func timerFired(_ key: M.Key, generation: UInt64, _ input: M.Input, incarnation: UInt64) {
        let core = self.core
        guard core.incarnation == incarnation else {
            core.counters.foreignCompletions += 1
            core.onDiagnostic?(.foreignCompletion)
            return
        }
        if core.timerTasks[key]?.generation == generation { core.timerTasks.removeValue(forKey: key) }
        guard core.rt.timers[key] == generation else {
            core.onDiagnostic?(.staleTimer)
            return
        }
        core.rt.timers.removeValue(forKey: key)
        beginEntry()
        core.step(input, caller: nil)
        runSegment()
    }

    @inlinable func continueDrain() {
        core.drainScheduled = false
        beginEntry()
        runSegment()
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
        while true {
            drainProducts()
            if !core.rt.abandoned.isEmpty {
                let (id, why) = core.rt.abandoned.removeFirst()
                core.stepAbandoned(id, why)
                continue
            }
            if let next = core.queued.pop() {
                admit(next.0, caller: next.1)
                continue
            }
            if let key = core.rt.nextReleasable() {
                if budget == 0 {
                    // The rest steps in a later batch, as the actor's own job. Until then the
                    // key counts as blocked: a new input for it queues behind the ones still queued.
                    if !core.drainScheduled {
                        core.drainScheduled = true
                        core.counters.drainContinuations += 1
                        Task { self.continueDrain() }
                    }
                    break
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
            break
        }
        if released > 0 { core.onDiagnostic?(.batchEnded(released: released)) }
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
            if core.rt.deadlinesToCancel {
                core.rt.deadlinesToCancel = false
                for id in Array(core.deadlineTasks.keys) where core.rt.open[id] == nil {
                    core.deadlineTasks.removeValue(forKey: id)?.cancel()
                }
            }
            if core.rt.timersToCancel {
                core.rt.timersToCancel = false
                for key in Array(core.timerTasks.keys) {
                    if let entry = core.timerTasks[key], core.rt.timers[key] != entry.generation {
                        entry.task.cancel()
                        core.timerTasks.removeValue(forKey: key)
                    }
                }
            }
            if !core.rt.timersToArm.isEmpty {
                var timers: [PendingTimer<M>] = []
                swap(&timers, &core.rt.timersToArm)
                for timer in timers where core.rt.timers[timer.key] == timer.generation {
                    arm(timer)
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
            let clock = core.clock
            core.deadlineTasks[id] = Task { [weak self] in
                // Woken early (cancelled) or on time, the core re-checks the request.
                await clock.sleep(until: instant)
                await self?.deadlineFired(id, incarnation: incarnation)
            }
        }
    }

    @inlinable func arm(_ timer: PendingTimer<M>) {
        let core = self.core
        let incarnation = core.incarnation
        let clock = core.clock
        let key = timer.key
        let generation = timer.generation
        let instant = timer.instant
        let input = timer.input
        core.timerTasks[key]?.task.cancel()
        core.timerTasks[key] = (generation, Task { [weak self] in
            // Woken early (cancelled) or on time, the core re-checks the timer. Held weakly: a
            // periodic timer doesn't keep a released actor alive.
            await clock.sleep(until: instant)
            await self?.timerFired(key, generation: generation, input, incarnation: incarnation)
        })
    }
}
