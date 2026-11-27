// The machine: the state a turn changes, and the four steps that change it.

/// A value type whose steps are synchronous. Every stored field is plain data (`@PlainData`), so
/// a machine holds nothing it can call through or that changes behind it.
///
/// A machine is changed only inside a step, and a step can't await: work it needs done is a
/// request, and the request's result comes back as an input.
public protocol TurnMachine: Sendable {
    /// Normal inputs and effect results alike.
    associatedtype Input: Sendable
    /// Asynchronous work, as data; the adopter's `perform` does it.
    associatedtype Effect: Sendable
    /// What a step leaves for the adopter's synchronous `flush`.
    associatedtype Output
    associatedtype Key: Hashable & Sendable
    associatedtype Reply: Sendable
    /// A synchronous collaborator's questions, answered as a step (`TurnActor.query`).
    associatedtype Query = Never
    associatedtype Answer = Never
    /// Names a key's coalesced follow-ups apart (`Turn.followUp`): one pending per key and slot.
    /// Default: none.
    associatedtype FollowUpSlot: Hashable & Sendable = Never
    /// What another thread tells the machine through the core's mailbox (`TurnActor.post`), taken
    /// before the next step. Default: none, and the mailbox's paths fold away.
    associatedtype Mail: Sendable = Never
    /// What the machine does, as distinct from what it holds: functions and fixed configuration
    /// (handlers, resolver lists, limits) that every step reads through `Turn.behavior` and
    /// `MailTurn.behavior`. It is given once, to `TurnCore.init(machine:behavior:…)`, and no step
    /// can write it. A behavior is fixed for the machine's lifetime; every change goes to the
    /// model (there is no `become`). Its functions run inside a step, so they are synchronous,
    /// touch nothing outside the model, and are deterministic: anything that waits or does I/O
    /// goes out as an effect, and its result comes back as an input. Only the first rule is
    /// checked by the compiler, and it doesn't stop a behavior from holding a reference with
    /// mutable state (a `Sendable` class, such as one that owns a `Mutex`): keep it to values and
    /// functions over them. It isn't recorded: a replay builds the same behavior from the same
    /// definition and config, and a different behavior replays a different machine; nothing in
    /// the record shows it. Default: none (`Void`).
    associatedtype Behavior: Sendable = Void
    /// The keys a caller waits on (`Turn.wait`). Default: none, and the barrier paths fold away.
    associatedtype BarrierKey: Hashable & Sendable = Never
    /// What a waiting caller holds; handed back to the machine however its wait ends.
    associatedtype BarrierPayload: Sendable = Never

    /// How `input` is admitted. Default: normal, with no hold and no scope.
    ///
    /// Whether it is `.control` or `.normal` must depend on the input alone, never on the
    /// machine's state: `sendAndWait(.cancelsCall)` reads it before the entry takes the mailbox, so
    /// a mail stepped in between must not change it (debug builds check). A `.normal` case's
    /// hold, scope and token may depend on state; they are read after the mailbox.
    func inputPolicy(for input: Input) -> InputPolicy<Key>
    mutating func handle(_ input: Input, _ turn: inout Turn<Self>)
    /// A request closed without its completion. Default: nothing.
    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>)
    /// The result of a request that had already closed: its worker has returned. Default: nothing.
    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Self>)
    mutating func answer(_ query: Query, _ turn: inout Turn<Self>) -> Answer
    /// A mail from the mailbox, stepped as a control input: holds, `close`, the queue limit and
    /// withdrawal don't apply, and it has no caller to reply to. Its `MailTurn` can't arm
    /// `.afterBatch` work (plan §3.9).
    mutating func handleMail(_ mail: Mail, _ turn: inout MailTurn<Self>)
    /// A registered barrier wait ended without a release (`WaitEnd`): its entry and timer are
    /// gone, and `ended.payload` is the machine's to clean up. Stepped after the step or entry
    /// that ended it, before the caller's answer leaves the core (after this step's outputs). For
    /// `.timedOut` and `.ended` the machine answers the caller, unless another reply was published
    /// for it first, which is then its answer; for `.withdrawn` and `.answered` the caller has its
    /// answer, and a reply from here is dropped. Default: answers `.failure(error)` when
    /// `why.error` has one.
    mutating func handleWaitEnded(_ ended: ReleasedWait<Self>, _ why: WaitEnd, _ turn: inout Turn<Self>)
}

extension TurnMachine {
    @inlinable public func inputPolicy(for input: Input) -> InputPolicy<Key> { .normal(waitsFor: nil, belongsTo: nil) }
    @inlinable public mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>) {}
    @inlinable public mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Self>) {}
}

extension TurnMachine {
    @inlinable public mutating func handleWaitEnded(_ ended: ReleasedWait<Self>, _ why: WaitEnd, _ turn: inout Turn<Self>) {
        if let error = why.error { turn.reply(to: ended.caller, .failure(error)) }
    }
}

extension TurnMachine where Query == Never, Answer == Never {
    @inlinable public mutating func answer(_ query: Never, _ turn: inout Turn<Self>) -> Never {
        switch query {}
    }
}

extension TurnMachine where Mail == Never {
    @inlinable public mutating func handleMail(_ mail: Never, _ turn: inout MailTurn<Self>) {
        switch mail {}
    }
}
