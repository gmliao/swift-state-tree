// What a handler may do to the core during its step.

/// A step's access to the core. It can't be made, copied or moved away by a handler, so it
/// exists only for the step that received it.
///
/// `unowned(unsafe)`: sound only because of that; the core outlives the step that made it.
public struct Turn<M: TurnMachine>: ~Copyable {
    @usableFromInline unowned(unsafe) let core: TurnCore<M>
    /// The caller of this step's input, when it came through `call`.
    public let input: InputID?

    @inlinable init(core: TurnCore<M>, input: InputID?) {
        self.core = core
        self.input = input
    }

    /// The core's clock, read at most once per segment: the first use reads it, later uses in
    /// the same segment (and a `Duration` deadline) see that instant.
    @inlinable public var now: TurnInstant {
        mutating get { core.segmentNow() }
    }

    // MARK: Lifetimes

    /// Starts a generation of `key`. True: it superseded a live one, whose requests are closed
    /// (also ones made earlier in this step) and whose timer is dropped. After `endAll` it does
    /// nothing and returns false: a handler that runs late (a stale completion) can call it, and
    /// then finds no live key to work under.
    @inlinable @discardableResult
    public mutating func issue(_ key: M.Key) -> Bool {
        if core.rt.ended {
            core.rt.ignoredAfterEnd += 1
            return false
        }
        let superseded = core.rt.live[key] != nil
        if superseded {
            core.rt.closeRequests(of: key)
            core.rt.dropTimer(of: key)
        }
        core.rt.counter &+= 1
        core.rt.live[key] = core.rt.counter
        return superseded
    }

    /// Ends `key`: its requests close, their `.untilRequestCloses` holds are released, its timer
    /// is dropped, and parked inputs scoped to it are withdrawn, whether or not the key is live.
    @inlinable public mutating func end(_ key: M.Key) {
        core.rt.closeRequests(of: key)
        core.rt.dropTimer(of: key)
        core.rt.live.removeValue(forKey: key)
        if core.rt.parkedCount != 0 { core.rt.withdraw { $0.scope == key } }
    }

    /// Ends `token`, in this step: a parked input that carries it is withdrawn now, and one that
    /// arrives later is withdrawn when it arrives.
    @inlinable public mutating func revoke(_ token: EndToken) {
        token.markEnded()
        if core.rt.parkedCount != 0 { core.rt.withdraw { $0.token === token } }
    }

    /// Ends every key, for good (a teardown), and closes external intake.
    /// - Every open request is abandoned. A worker that keeps a hold until it retires still
    ///   keeps it, and its completion steps as stale.
    /// - Parked inputs with a scope are withdrawn, what a step queued (`queue`) is dropped, and
    ///   every other parked call is answered `closed`, as by `close`. A caller the machine itself
    ///   keeps waiting is the machine's to answer, in this same step.
    /// - From here on no key can be issued, so no request is made, no timer armed and no keyed
    ///   output emitted, and `queue` drops its input. `run`, `ask`, control inputs and the
    ///   completions of work in flight still step, and what this step produced still leaves.
    @inlinable public mutating func endAll() {
        let ids = core.rt.open.keys.sorted { $0.raw < $1.raw }
        for id in ids { core.rt.closeRequest(id, .keyEnded) }
        core.rt.live.removeAll()
        if !core.rt.timers.isEmpty {
            core.rt.timers.removeAll()
            core.rt.timersToCancel = true
        }
        core.rt.timersToArm.removeAll()
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
    /// external inputs that name it as their hold park until the hold ends. The hold carries the
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

    /// Queues `input` behind `key`'s hold, after the inputs already parked there: it steps when
    /// the hold is free, in that order. For a step's own follow-up that has to keep its place
    /// among the held work. It can't be refused: `close`, the parked limit, scopes and tokens
    /// don't apply. Only `endAll` drops it, and after `endAll` this does nothing.
    ///
    /// The core puts no bound on these: the adopter does, by what it queues. They count as
    /// parked, so a burst of them can make an external input find the parked queue full.
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
        if core.rt.timers[key] != nil { core.rt.timersToCancel = true }
        core.rt.nextTimer &+= 1
        let generation = core.rt.nextTimer
        core.rt.timers[key] = generation
        core.rt.timersToArm.append(PendingTimer(key: key, generation: generation, instant: instant, input: input))
        core.rt.dirty = true
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

    /// Answers a `call`. `after`: published once that request's completion step has ended, or
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

    /// Closes external intake: parked external calls are answered `closed`, later ones refused.
    /// Queued inputs, completions, control inputs, `ask` and `run` still step.
    @inlinable public mutating func close() {
        core.rt.closed = true
        core.rt.closing = true
        core.rt.dirty = true
    }
}
