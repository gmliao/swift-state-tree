// What a handler may do to the core during its step.

/// A step's access to the core. It can't be made, copied or moved away by a handler, so it
/// exists only for the step that received it.
///
/// `unowned(unsafe)`: sound only because of that; the core outlives the step that made it.
public struct Turn<M: TurnMachine>: ~Copyable {
    @usableFromInline unowned(unsafe) let core: TurnCore<M>
    /// The caller of this step's input, when it came through `sendAndWait`.
    public let input: InputID?

    @inlinable init(core: TurnCore<M>, input: InputID?) {
        self.core = core
        self.input = input
    }

    /// The machine's behavior (`TurnMachine.Behavior`): its handlers and fixed configuration,
    /// as given to `TurnCore.init(machine:behavior:…)`. Read-only: a behavior is fixed for the
    /// machine's lifetime, and every change goes to the model (there is no `become`). A
    /// reference the behavior holds (a `Sendable` class) can still change, so keep it to values
    /// and functions over them.
    @inlinable public var behavior: M.Behavior { core.behavior }

    /// The core's clock, read at most once per batch: the first use reads it, later uses in
    /// the same batch (and a `Duration` deadline) see that instant.
    @inlinable public var now: TurnInstant {
        mutating get { core.segmentNow() }
    }

    /// Takes every mail in the mailbox now, oldest first, so this step can act on a mail
    /// posted while it runs (a failure that must stop the step's outputs). Taken mail doesn't
    /// step through `handleMail`. A mail's own step has no take (its `MailTurn` has none), so
    /// mail posted meanwhile steps at the next check. An environment read, like `now`: a replay
    /// serves the recorded take.
    @inlinable public mutating func takeMail() -> [M.Mail] {
        guard TurnCore<M>.usesMailbox, let mailbox = core.mailbox else { return [] }
        let key = MailRecordKey.inside(step: core.currentOrdinal, take: core.takeIndex)
        core.takeIndex += 1
        if core.mailReplay != nil { return core.serveTake(key) }
        let taken = mailbox.removeAll()
        if !taken.isEmpty { core.onMailTaken?(key, taken, nil) }
        return taken
    }

    // MARK: Lifetimes

    /// Starts a generation of `key`. True: it superseded a live one, whose requests are closed
    /// (also ones made earlier in this step), whose follow-ups close unrun, whose timer is
    /// dropped, and whose not-yet-stepped inputs scoped to `key` are withdrawn, as by `end`:
    /// queued ones now, deferred ones (sent while a step or batch ran) when they are admitted.
    /// An input carries no generation, so one sent under the old generation would otherwise
    /// step under the new one.
    ///
    /// Limit: an input that arrives while `key` isn't live (before its first `start`, or after
    /// an `end`) isn't withdrawn by this `start`; it steps under the new generation. Use a fresh
    /// key per binding (a connection or session id) when inputs sent between an `end` and the
    /// next `start` must not step.
    ///
    /// After `endAll` it does nothing and returns false: a handler that runs late (a stale
    /// completion) can call it, and then finds no live key to work under.
    @inlinable @discardableResult
    public mutating func start(_ key: M.Key) -> Bool {
        if core.rt.ended {
            core.rt.ignoredAfterEnd += 1
            return false
        }
        let superseded = core.rt.live[key] != nil
        if superseded {
            core.rt.closeRequests(of: key)
            core.rt.closeFollowUps(of: key)
            core.rt.dropTimer(of: key)
            if core.rt.parkedCount != 0 { core.rt.withdraw { $0.scope == key && !$0.pinned } }
            core.scopeEnded(key)
        }
        core.rt.counter &+= 1
        core.rt.live[key] = core.rt.counter
        return superseded
    }

    /// Ends `key`: its requests close, their `.untilRequestCloses` holds are released, its
    /// follow-ups close unrun (`handleAbandoned(id, .keyEnded)`), its timer is dropped, and
    /// not-yet-stepped inputs scoped to it are withdrawn (queued ones now, deferred ones when
    /// they are admitted), whether or not the key is live.
    @inlinable public mutating func end(_ key: M.Key) {
        core.rt.closeRequests(of: key)
        core.rt.closeFollowUps(of: key)
        core.rt.dropTimer(of: key)
        core.rt.live.removeValue(forKey: key)
        if core.rt.parkedCount != 0 { core.rt.withdraw { $0.scope == key } }
        core.scopeEnded(key)
    }

    /// Ends `token`, in this step: a queued input that carries it is withdrawn now, and one that
    /// arrives later is withdrawn when it arrives.
    @inlinable public mutating func revoke(_ token: WithdrawToken) {
        token.withdraw()
        if core.rt.parkedCount != 0 { core.rt.withdraw { $0.token === token } }
    }

    /// Ends every key, for good (a teardown), and closes intake from outside.
    /// - Every open request is abandoned, then every pending follow-up. A worker that keeps a
    ///   hold until it returns still keeps it, and its completion steps as stale.
    /// - Queued inputs with a scope are withdrawn, what a step queued (`queue`) is dropped, and
    ///   every other queued call is answered `closed`, as by `close`. A caller the machine itself
    ///   keeps waiting is the machine's to answer, in this same step.
    /// - Every barrier wait ends: each steps `handleWaitEnded(.ended)` with its payload, oldest
    ///   first, after this step; a later `wait` is refused `.ended`.
    /// - From here on no key can be started, so no request is made, no timer armed and no keyed
    ///   output emitted, `queue` drops its input and `followUp` refuses. `run`, `query`, control
    ///   inputs and the completions of work in flight still step, and what this step produced
    ///   still leaves.
    @inlinable public mutating func endAll() {
        let ids = core.rt.open.keys.sorted { $0.raw < $1.raw }
        for id in ids { core.rt.closeRequest(id, .keyEnded) }
        core.rt.closeFollowUps(of: nil)
        core.rt.live.removeAll()
        core.rt.timers.removeAll()
        core.rt.timerKeys.removeAll()
        core.rt.timersToArm.removeAll()
        // Every barrier wait ends, each payload handed back through `handleWaitEnded` in a step of
        // its own after this one: no timeout can answer it once the deadlines stop. The driver
        // moves the entries after it has published this step's replies, so a caller whose reply
        // is staged (`reply(after:)` of a request this end closes, or one staged in this step) is
        // claimed by that reply (`.answered`), and the rest end `.ended`, oldest first. A caller
        // the machine means to answer otherwise is released (`release(where:)`) in this step.
        if TurnCore<M>.usesBarriers, !core.rt.barrierWaiters.isEmpty { core.rt.endingWaits = true }
        core.rt.barrierTimersToArm.removeAll()
        // No entry can be live again: the core's timer stops here, in this step (plan §3.7).
        core.stopDeadlines()
        core.rt.ended = true
        core.rt.withdraw { $0.scope != nil || $0.pinned }
        close()
    }

    @inlinable public func isLive(_ key: M.Key) -> Bool { core.rt.live[key] != nil }

    @inlinable public func generation(of key: M.Key) -> Generation? {
        core.rt.live[key].map(Generation.init(raw:))
    }

    // MARK: Work

    /// Asynchronous work owned by `key`'s current generation that keeps `holding`'s key busy:
    /// normal inputs that name it as their hold queue until the hold ends. The hold carries the
    /// request's deadline. Nil: `key` isn't live.
    @inlinable @discardableResult
    public mutating func request(_ effect: M.Effect, for key: M.Key, holding: Hold<M.Key>) -> RequestID? {
        makeRequest(effect, for: key, hold: holding.key, untilRetire: holding.untilRetire, deadline: holding.deadline)
    }

    /// Asynchronous work owned by `key`'s current generation, holding nothing. `deadline`, if
    /// given, abandons the request when it passes. Nil: `key` isn't live.
    @inlinable @discardableResult
    public mutating func request(_ effect: M.Effect, for key: M.Key, deadline: Duration? = nil) -> RequestID? {
        makeRequest(effect, for: key, hold: nil, untilRetire: false, deadline: deadline)
    }

    @inlinable mutating func makeRequest(
        _ effect: M.Effect, for key: M.Key, hold: M.Key?, untilRetire: Bool, deadline: Duration?
    ) -> RequestID? {
        guard core.rt.live[key] != nil else { return nil }
        assert(!core.rt.ended, "TurnCore: a key is live after endAll")
        core.rt.nextRequest &+= 1
        let id = RequestID(raw: core.rt.nextRequest)
        if let hold { core.rt.held[hold, default: 0] += 1 }
        core.rt.open[id] = RequestRecord(key: key, hold: hold, untilRetire: untilRetire, hasDeadline: deadline != nil)
        let instant = deadline.map { core.segmentNow() + $0 }
        core.rt.effects.append(PendingEffect(effect: effect, request: id, deadline: instant))
        core.noteEffect()
        core.rt.dirty = true
        return id
    }

    /// Abandons `request` with `.cancelled`; its late result steps as stale.
    @inlinable public mutating func cancel(_ request: RequestID) {
        core.rt.closeRequest(request, .cancelled)
    }

    /// Untracked work. Its result comes back as a control input.
    @inlinable public mutating func run(_ effect: M.Effect) {
        core.rt.effects.append(PendingEffect(effect: effect, request: nil, deadline: nil))
        core.noteEffect()
        core.rt.dirty = true
    }

    /// Queues `input` behind `key`'s hold, after the inputs already queued there: it steps when
    /// the hold is free, in that order. For a step's own follow-up that has to keep its place
    /// among the held work. It can't be refused: `close`, the queue limit, scopes and tokens
    /// don't apply. Only `endAll` drops it, and after `endAll` this does nothing.
    ///
    /// The core puts no bound on these: the adopter does, by what it queues. They count as
    /// queued, so a burst of them can make a normal input find the queue full.
    ///
    /// False: the core has ended, and the input was not queued.
    @inlinable @discardableResult
    public mutating func queue(_ input: M.Input, behind key: M.Key) -> Bool {
        if core.rt.ended {
            core.rt.ignoredAfterEnd += 1
            return false
        }
        core.rt.park(Parked(input: input, caller: nil, scope: nil, token: nil, pinned: true), behind: key)
        if core.rt.held[key] == nil, !core.rt.releasable.contains(key) { core.rt.releasable.append(key) }
        core.rt.dirty = true
        return true
    }

    /// Arms `key`'s timer: `input` steps as a control input at `instant`. One timer per key; a
    /// new one replaces it. Ending or superseding the key drops it, also when its fire is already
    /// on its way. Does nothing when `key` isn't live. The machine puts the instant into `input`
    /// if it schedules the next fire from it (skip ahead: `max(instant + period, now)`).
    @inlinable public mutating func timer(at instant: TurnInstant, for key: M.Key, _ input: M.Input) {
        guard core.rt.live[key] != nil else { return }
        if let old = core.rt.timers[key] {
            core.rt.timerKeys.removeValue(forKey: old.generation)
            core.rt.staleDeadlines &+= 1
        }
        core.rt.nextTimer &+= 1
        let generation = core.rt.nextTimer
        core.rt.timers[key] = ArmedTimer(generation: generation, input: input)
        core.rt.timerKeys[generation] = key
        core.rt.timersToArm.append(PendingTimer(key: key, generation: generation, instant: instant))
        core.rt.dirty = true
    }

    // MARK: Follow-ups

    /// Arms a coalesced follow-up for `key` and `slot`, owned by `key`'s current generation:
    /// `input` steps as a control input when `trigger` says. One is pending per key and slot: an
    /// arm while one is pending joins it and changes nothing (the first arm's input and trigger
    /// stand). Ending or superseding `key` closes it unrun (`handleAbandoned(id, .keyEnded)`),
    /// also when it was armed earlier in the same step. The slot is freed before the follow-up
    /// steps, so its step may arm a successor.
    ///
    /// The returned id names the follow-up in `handleAbandoned` only. It isn't a request id:
    /// `cancel(id)` does nothing for it, and `reply(after: id)` publishes at once.
    ///
    /// `.refused`: `key` isn't live, or the core has ended (counted in `ignoredAfterEnd`).
    @inlinable @discardableResult
    public mutating func followUp(
        _ input: M.Input,
        _ slot: M.FollowUpSlot,
        of key: M.Key,
        _ trigger: FollowUpTrigger<M.Effect>
    ) -> FollowUpArming {
        if core.rt.ended {
            core.rt.ignoredAfterEnd += 1
            return .refused
        }
        guard core.rt.live[key] != nil else { return .refused }
        let name = FollowUpKey<M>(key: key, slot: slot)
        if let pending = core.rt.followUps[name] { return .joined(pending.id) }
        core.rt.nextRequest &+= 1
        let id = RequestID(raw: core.rt.nextRequest)
        switch trigger {
        case .afterBatch:
            core.rt.followUps[name] = FollowUpRecord(id: id, input: input, waiting: false, hasDeadline: false)
            core.rt.dueFollowUps.append(id)
        case .afterWork(let effect, let deadline):
            core.rt.followUps[name] = FollowUpRecord(id: id, input: input, waiting: true, hasDeadline: deadline != nil)
            let instant = deadline.map { core.segmentNow() + $0 }
            core.rt.followUpGates.append(PendingEffect(effect: effect, request: id, deadline: instant))
            core.noteEffect()
        }
        core.rt.followUpIDs[id] = name
        core.rt.dirty = true
        return .armed(id)
    }

    /// Retires the pending follow-up for `key` and `slot` without stepping it, and returns its
    /// input; nil when none is pending. No `handleAbandoned` follows. A gate still in flight
    /// finds it gone when it returns, and steps nothing for it.
    @inlinable @discardableResult
    public mutating func consumeFollowUp(_ slot: M.FollowUpSlot, of key: M.Key) -> M.Input? {
        guard let pending = core.rt.followUps[FollowUpKey<M>(key: key, slot: slot)] else { return nil }
        return core.rt.removeFollowUp(pending.id)?.input
    }

    /// The pending follow-up for `key` and `slot`, if any.
    @inlinable public func followUpPending(_ slot: M.FollowUpSlot, of key: M.Key) -> RequestID? {
        core.rt.followUps[FollowUpKey<M>(key: key, slot: slot)]?.id
    }

    // MARK: Output and answers

    /// Dropped, and counted, unless `key` is live.
    @inlinable public mutating func emit(_ output: M.Output, for key: M.Key) {
        guard core.rt.live[key] != nil else {
            core.rt.droppedOutputs += 1
            return
        }
        core.rt.outputs.append(output)
        core.rt.dirty = true
    }

    /// Answers a `sendAndWait`. `after`: published once that request's completion step has ended, or
    /// the request was abandoned.
    @inlinable public mutating func reply(
        to caller: InputID,
        _ result: Result<M.Reply, any Error>,
        after request: RequestID? = nil
    ) {
        if let request, core.rt.open[request] != nil {
            core.rt.repliesAfter[request, default: []].append((caller, result))
        } else {
            core.rt.replies.append((caller, result))
            core.rt.dirty = true
        }
    }

    /// Closes intake from outside: queued normal calls are answered `closed`, later ones refused.
    /// Inputs a step queued (`queue`), completions, control inputs, `query` and `run` still step.
    /// Barrier waits are left alone: those callers have stepped, and a release, their timeout or
    /// `endAll` ends them.
    @inlinable public mutating func close() {
        core.rt.closed = true
        core.rt.closing = true
        core.rt.dirty = true
    }
}
