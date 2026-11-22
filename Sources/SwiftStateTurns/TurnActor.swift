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
    /// mail, and an error is a case of the input. Its result comes back as an input.
    @concurrent nonisolated func perform(_ effect: M.Effect) async -> M.Input?
    /// The synchronous sink of a step's outputs, called between steps.
    func flush(_ outputs: consuming [M.Output])
    /// The core's mailbox, for `post`: a stored `nonisolated let` assigned from `core.mailbox` (a lint
    /// checks it). A machine without mail gets nil by default.
    nonisolated var mailbox: TurnMailbox<M.Mail>? { get }
}

extension TurnActor where M.Mail == Never {
    @inlinable public nonisolated var mailbox: TurnMailbox<Never>? { nil }
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
                submit(input, caller: id, readControl: isControl)
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
                    self.submit(input, caller: id, readControl: isControl)
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

    /// A new entry from outside: a new batch, so the next `Turn.now` reads the clock. It takes
    /// the mailbox first (`takeMailBeforeStep`), under a fresh mailbox budget, so the entry's own checks
    /// read the state after the mail. Every entry that calls it ends through the segment
    /// epilogue (`if core.rt.dirty { runSegment() }`), its stale returns included.
    @inlinable func beginEntry() {
        let core = self.core
        core.cachedNow = nil
        if TurnCore<M>.usesMailbox, let mailbox = core.mailbox {
            core.mailBudget = mailbox.capacity
            takeMailBeforeStep()
        }
    }

    /// An entry's boundary, after its mailbox take and before its own work (a completion, a
    /// deadline, a timer, a gate's return), as an admission is (plan §3.9): it takes an
    /// ordinal, so a mail posted between the take and the work, which steps after the work
    /// live, is keyed after the boundary and replays there too. Every such entry calls it,
    /// its stale returns included, so both sides count alike.
    @inlinable func entryBoundary() {
        let core = self.core
        guard TurnCore<M>.usesMailbox else { return }
        core.noteDispatch()
        core.onEntryBoundaryForTesting?()
    }

    // MARK: The mailbox

    /// Posts `mail` to the core's mailbox, from any thread, without awaiting: the core steps it
    /// (`handleMail`) before the next step after the check that sees it, within an entry's
    /// budget. A mail posted after a check's watermark, or while an entry is admitting its
    /// own input, steps after that step, at the next check. False when the mailbox is
    /// full: the mail isn't stored (the first pending mail wins) and the refusal is counted.
    /// The post that finds the mailbox empty schedules one wake (`mailboxWoke`).
    @inlinable public nonisolated func post(_ mail: M.Mail) -> Bool {
        guard let mailbox else { fatalError("TurnActor: post on an actor whose machine takes no mail") }
        guard let wasEmpty = mailbox.append(mail) else { return false }
        if wasEmpty { Task { await self.mailboxWoke() } }
        return true
    }

    /// Tests: `post`, with `beforeAppend` awaited before the mailbox's critical section (its "was
    /// empty" read and the append) and `afterAppend` between the append and the wake, so a test
    /// can hold a post at either point.
    @inlinable package nonisolated func postForTesting(
        _ mail: M.Mail,
        beforeAppend: @Sendable () async -> Void = {},
        afterAppend: @Sendable () async -> Void = {}
    ) async -> Bool {
        guard let mailbox else { fatalError("TurnActor: post on an actor whose machine takes no mail") }
        await beforeAppend()
        guard let wasEmpty = mailbox.append(mail) else { return false }
        await afterAppend()
        if wasEmpty { Task { await self.mailboxWoke() } }
        return true
    }

    /// The mailbox's wake: an ordinary entry. It finds the mailbox empty when an entry took the
    /// mail first (`emptyMailboxWakes`), and ends through the epilogue either way. `remainder`:
    /// the epilogue's wake for mail a spent budget left, which owns `mailboxWakeScheduled`; a
    /// post's wake leaves the flag alone, so it can't clear it while a remainder wake is pending.
    @inlinable func mailboxWoke(remainder: Bool = false) {
        let core = self.core
        core.onMailboxWakeForTesting?()
        if remainder { core.mailboxWakeScheduled = false }
        if let mailbox = core.mailbox, mailbox.isEmpty { core.counters.emptyMailboxWakes += 1 }
        beginEntry()
        if core.rt.dirty { runSegment() }
    }

    /// The entry's mailbox take. It steps the mail posted before it, in the segment's mode
    /// (`inSegment` set, so a send from `flush` queues and a query answers in place), draining
    /// each one's products before the next. When it stepped a mail or left some, the entry
    /// runs a segment now, before its own checks and step (products first, plan §3.4): the
    /// whole loop, so what the mail caused (queued sends, releases, abandonments, due
    /// follow-ups, mail posted meanwhile) steps before the entry's own work, as a wake's
    /// segment would have stepped it before any later entry. That is what replay relies on: it
    /// steps a wake's mail at the next entry's take. Leaving mail (a post after the
    /// watermark) happens only live; running the segment for it too is a live ordering choice,
    /// mail before the entry's work, not a replay need. Inside a segment, the enclosing loop
    /// steps the products instead.
    @inlinable func takeMailBeforeStep() {
        let core = self.core
        // Not from inside a step or a read (a `query` from a collaborator a step calls): that
        // call stops in its own step's borrow check, with its own message.
        guard TurnCore<M>.usesMailbox, core.borrows == 0, let mailbox = core.mailbox else { return }
        let replaying = core.mailReplay != nil
        if !replaying, mailbox.isEmpty { return }
        let wasInSegment = core.inSegment
        core.inSegment = true
        let stepped = replaying ? takeStaged(keepingNow: !wasInSegment) : takeMail(mailbox)
        core.inSegment = wasInSegment
        if stepped || !mailbox.isEmpty {
            core.rt.dirty = true
            if !wasInSegment { runSegment() }
        }
        // The entry's own work reads its own `now`.
        core.productsNow = nil
    }

    /// One check: the mail at or below the mailbox's watermark now, one head at a time, each
    /// stepped and its products drained before the next is removed. Spends the entry's budget.
    /// True when it stepped any.
    @inlinable func takeMail(_ mailbox: TurnMailbox<M.Mail>) -> Bool {
        let core = self.core
        if core.mailBudget == 0 { return false }
        let watermark = mailbox.watermark
        core.onMailboxCheckForTesting?()
        var stepped = false
        while core.mailBudget > 0, let mail = mailbox.removeHead(atOrBelow: watermark) {
            core.mailBudget -= 1
            let key = MailRecordKey.before(step: core.nextOrdinal, index: core.beforeIndex)
            core.beforeIndex += 1
            if let record = core.onMailTaken { record(key, [mail], core.segmentNow()) }
            core.stepMail(mail)
            drainProducts()
            stepped = true
        }
        return stepped
    }

    /// A replay's check: the staged mail for the next step's `before` keys, in order, each
    /// with its recorded `now`. The budget doesn't apply: the record fixed where each one steps.
    /// `keepingNow`: the last mail's `now` stays served (`productsNow`) for the entry's
    /// products-first segment, which the caller ends; a loop check's mail was recorded with
    /// the entry's own `now`, so it doesn't keep it.
    @inlinable func takeStaged(keepingNow: Bool = false) -> Bool {
        let core = self.core
        var stepped = false
        while let head = core.mailReplay?.first,
              head.key == .before(step: core.nextOrdinal, index: core.beforeIndex) {
            core.mailReplay?.removeFirst()
            core.beforeIndex += 1
            core.productsNow = head.now
            for mail in head.mail {
                core.stepMail(mail)
                drainProducts()
            }
            stepped = true
        }
        // A loop check that stepped nothing leaves the products-first segment's `now` served.
        if stepped, !keepingNow { core.productsNow = nil }
        return stepped
    }

    /// Replay: called once after the record's last input. It steps the mail staged after
    /// the last step (`before` the next ordinal, which no step takes) as a check would, then
    /// reports any entry still staged as `leftover`.
    package func finishReplay() {
        let core = self.core
        guard TurnCore<M>.usesMailbox, core.mailReplay != nil else { return }
        beginEntry()
        if core.rt.dirty { runSegment() }
        while let head = core.mailReplay?.first { core.diverged(.leftover(head.key)) }
    }

    @inlinable func callerCancelled(_ id: InputID) {
        let core = self.core
        guard let waiter = core.waiters.removeValue(forKey: id) else { return }
        _ = core.rt.withdraw(caller: id)
        core.counters.cancelledCalls += 1
        waiter.resume(throwing: CancellationError())
    }

    /// `readControl`: what `sendAndWait(.cancelsCall)` read from `inputPolicy(for:)` before it
    /// submitted; debug builds check that the policy still says the same after the mailbox.
    @inlinable func submit(_ input: M.Input, caller: InputID?, readControl: Bool? = nil) {
        let core = self.core
        if core.borrows < 0 || core.inSegment {
            core.queued.push((input, caller, core.scopeEndClock))
            // Made from inside a step (the machine borrowed for writing): not a step entry, so no
            // borrow stop. The batch that follows the step picks it up.
            core.rt.dirty = true
            return
        }
        beginEntry()
        #if DEBUG
        if TurnCore<M>.usesMailbox, let readControl {
            let isControl: Bool
            if case .control = core.machine.inputPolicy(for: input) { isControl = true } else { isControl = false }
            assert(isControl == readControl, "TurnCore: inputPolicy's control or normal choice changed with the machine's state")
        }
        #endif
        admit(input, caller: caller)
        if core.rt.dirty { runSegment() }
    }

    /// `arrival`: a deferred input's scope-end clock when it arrived; nil when admitted on arrival.
    @inlinable func admit(_ input: M.Input, caller: InputID?, arrival: UInt64? = nil) {
        let core = self.core
        // A boundary, whatever the outcome: a mail keyed after a parked or refused admission
        // can't replay ahead of it (plan §3.9).
        core.noteDispatch()
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
        entryBoundary()
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
        // With a mailbox, its mail steps before the checks below, which read the state after it.
        if TurnCore<M>.usesMailbox {
            beginEntry()
            entryBoundary()
        }
        if core.rt.open[id] == nil, core.rt.gateDeadlineLive(id) {
            // A follow-up's gate deadline: the follow-up closes unrun.
            if !TurnCore<M>.usesMailbox { beginEntry() }
            core.rt.closeFollowUp(id, .deadline)
            runSegment()
            return
        }
        guard core.rt.open[id] != nil else {
            core.onDiagnostic?(.staleDeadline)
            if TurnCore<M>.usesMailbox, core.rt.dirty { runSegment() }
            return
        }
        if !TurnCore<M>.usesMailbox { beginEntry() }
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
        if TurnCore<M>.usesMailbox {
            beginEntry()
            entryBoundary()
        }
        guard core.rt.timers[key] == generation else {
            core.onDiagnostic?(.staleTimer)
            if TurnCore<M>.usesMailbox, core.rt.dirty { runSegment() }
            return
        }
        core.rt.timers.removeValue(forKey: key)
        if !TurnCore<M>.usesMailbox { beginEntry() }
        core.step(input, caller: nil)
        runSegment()
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
        if TurnCore<M>.usesMailbox {
            // The follow-ups due at the job's start, captured before the mailbox's take: an
            // `.afterBatch` follow-up a mail arms becomes due after this, so it steps in the
            // next job, in a new batch as `.afterBatch` promises. They are pushed after the take,
            // so the mail's products-first segment steps before them. The swap moves the
            // buffer out and back, so the capture doesn't allocate.
            var due: [RequestID] = []
            if TurnCore<M>.usesFollowUps { swap(&due, &core.rt.dueFollowUps) }
            beginEntry()
            if TurnCore<M>.usesFollowUps {
                for id in due { core.followUpsToStep.push(id) }
                due.removeAll(keepingCapacity: true)
                due.append(contentsOf: core.rt.dueFollowUps)
                core.rt.dueFollowUps = due
            }
        } else {
            beginEntry()
            if TurnCore<M>.usesFollowUps {
                for id in core.rt.dueFollowUps { core.followUpsToStep.push(id) }
                core.rt.dueFollowUps.removeAll(keepingCapacity: true)
            }
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
        entryBoundary()
        if let name = core.rt.followUpIDs[id], core.rt.followUps[name]?.waiting == true {
            core.rt.followUps[name]?.waiting = false
            if core.rt.followUps[name]?.hasDeadline == true {
                core.rt.followUps[name]?.hasDeadline = false
                core.rt.deadlinesToCancel = true
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
            // The mailbox before every step, a capped segment's included; a check that stepped a
            // mail comes round again, so a mail its step posted is checked before the next.
            if TurnCore<M>.usesMailbox, let mailbox = core.mailbox,
               core.mailReplay != nil ? takeStaged() : (!mailbox.isEmpty && takeMail(mailbox)) { continue }
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
        // Mail that the entry's spent budget left in the mailbox steps in a new batch, with a fresh
        // budget. Only a spent budget leaves mail with no wake: while it lasts, every check
        // steps up to its watermark and the loop comes round, so the first mail posted after
        // the mailbox empties finds it empty and schedules its own wake. The budget test keeps the
        // lock off an entry that spent none.
        if TurnCore<M>.usesMailbox, core.mailBudget == 0, !core.mailboxWakeScheduled, let mailbox = core.mailbox, !mailbox.isEmpty {
            core.mailboxWakeScheduled = true
            let hold = core.onRemainderWakeForTesting?()
            Task {
                await hold?()
                await self.mailboxWoke(remainder: true)
            }
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
            if core.rt.deadlinesToCancel {
                core.rt.deadlinesToCancel = false
                for id in Array(core.deadlineTasks.keys) where core.rt.open[id] == nil && !(TurnCore<M>.usesFollowUps && core.rt.gateDeadlineLive(id)) {
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
            let clock = core.clock
            core.deadlineTasks[id] = Task { [weak self] in
                // Woken early (cancelled) or on time, the core re-checks the request.
                await clock.sleep(until: instant)
                await self?.deadlineFired(id, incarnation: incarnation)
            }
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
            let clock = core.clock
            core.deadlineTasks[id] = Task { [weak self] in
                // Woken early (cancelled) or on time, the core re-checks the follow-up.
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
