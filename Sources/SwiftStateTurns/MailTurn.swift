// What a mail's handler may do to the core during its step.

/// A mail step's access to the core: a `Turn` without what a mail must not do. It can't
/// arm an `.afterBatch` follow-up: a replay steps a wake's mail at the next entry's take, so
/// a job that mail scheduled would run after that entry's input, not before it as live
/// (plan §3.9). For follow-up work, arm one `afterWork` (its gate's result comes back as a
/// recorded input), or `run` an effect whose result steps as an input. It has no `takeMail`
/// either: mail posted during a mail's step steps at the next check.
///
/// What the wake's segment does after the mail is not covered: a continuation job that segment
/// schedules (a capped release, or `.afterBatch` work that a product step arms: an input the
/// mail's flush sends, an answer to a query it asks, an abandonment its `end` causes, a
/// released input) can replay after the next external input, because a replay doesn't fix a
/// continuation job's order relative to that input (#745).
///
/// Like `Turn`, it can't be made, copied or moved away by a handler.
public struct MailTurn<M: TurnMachine>: ~Copyable {
    @usableFromInline var turn: Turn<M>

    @inlinable init(core: TurnCore<M>) {
        self.turn = Turn(core: core, input: nil)
    }

    /// `Turn.now`: in a replay, the recorded `now` of the mail's check.
    @inlinable public var now: TurnInstant {
        mutating get { turn.now }
    }

    /// `Turn.start`.
    @inlinable @discardableResult
    public mutating func start(_ key: M.Key) -> Bool { turn.start(key) }

    /// `Turn.end`.
    @inlinable public mutating func end(_ key: M.Key) { turn.end(key) }

    /// `Turn.revoke`.
    @inlinable public mutating func revoke(_ token: WithdrawToken) { turn.revoke(token) }

    /// `Turn.endAll`.
    @inlinable public mutating func endAll() { turn.endAll() }

    /// `Turn.isLive`.
    @inlinable public func isLive(_ key: M.Key) -> Bool { turn.isLive(key) }

    /// `Turn.generation(of:)`.
    @inlinable public func generation(of key: M.Key) -> Generation? { turn.generation(of: key) }

    /// `Turn.request(_:for:holding:)`.
    @inlinable @discardableResult
    public mutating func request(_ effect: M.Effect, for key: M.Key, holding: Hold<M.Key>) -> RequestID? {
        turn.request(effect, for: key, holding: holding)
    }

    /// `Turn.request(_:for:deadline:)`.
    @inlinable @discardableResult
    public mutating func request(_ effect: M.Effect, for key: M.Key, deadline: Duration? = nil) -> RequestID? {
        turn.request(effect, for: key, deadline: deadline)
    }

    /// `Turn.cancel`.
    @inlinable public mutating func cancel(_ request: RequestID) { turn.cancel(request) }

    /// `Turn.run`: the effect's result steps as an input.
    @inlinable public mutating func run(_ effect: M.Effect) { turn.run(effect) }

    /// `Turn.queue(_:behind:)`.
    @inlinable @discardableResult
    public mutating func queue(_ input: M.Input, behind key: M.Key) -> Bool { turn.queue(input, behind: key) }

    /// `Turn.timer(at:for:_:)`.
    @inlinable public mutating func timer(at instant: TurnInstant, for key: M.Key, _ input: M.Input) {
        turn.timer(at: instant, for: key, input)
    }

    /// `Turn.followUp` with an `afterWork` trigger, the only one a mail may arm: `input`
    /// steps when `perform(effect)` returns, or the follow-up closes with `.deadline` first.
    @inlinable @discardableResult
    public mutating func followUp(
        _ input: M.Input,
        _ slot: M.FollowUpSlot,
        of key: M.Key,
        afterWork effect: M.Effect,
        deadline: Duration?
    ) -> FollowUpArming {
        turn.followUp(input, slot, of: key, .afterWork(effect, deadline: deadline))
    }

    /// `Turn.consumeFollowUp`.
    @inlinable @discardableResult
    public mutating func consumeFollowUp(_ slot: M.FollowUpSlot, of key: M.Key) -> M.Input? {
        turn.consumeFollowUp(slot, of: key)
    }

    /// `Turn.followUpPending`.
    @inlinable public func followUpPending(_ slot: M.FollowUpSlot, of key: M.Key) -> RequestID? {
        turn.followUpPending(slot, of: key)
    }

    /// `Turn.emit`.
    @inlinable public mutating func emit(_ output: M.Output, for key: M.Key) { turn.emit(output, for: key) }

    /// `Turn.reply`: a mail has no caller of its own; this answers another call's.
    @inlinable public mutating func reply(
        to caller: InputID,
        _ result: Result<M.Reply, any Error>,
        after request: RequestID? = nil
    ) {
        turn.reply(to: caller, result, after: request)
    }

    /// `Turn.close`.
    @inlinable public mutating func close() { turn.close() }
}
