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
    /// What another thread tells the machine through the core's lane (`TurnActor.post`), taken
    /// before the next step. Default: none, and the lane's paths fold away.
    associatedtype LaneReport: Sendable = Never

    /// How `input` is admitted. Default: normal, with no hold and no scope.
    ///
    /// Whether it is `.control` or `.normal` must depend on the input alone, never on the
    /// machine's state: `sendAndWait(.cancelsCall)` reads it before the entry takes the lane, so
    /// a report stepped in between must not change it (debug builds check). A `.normal` case's
    /// hold, scope and token may depend on state; they are read after the lane.
    func inputPolicy(for input: Input) -> InputPolicy<Key>
    mutating func handle(_ input: Input, _ turn: inout Turn<Self>)
    /// A request closed without its completion. Default: nothing.
    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>)
    /// The result of a request that had already closed: its worker has returned. Default: nothing.
    mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Self>)
    mutating func answer(_ query: Query, _ turn: inout Turn<Self>) -> Answer
    /// A report from the lane, stepped as a control input: holds, `close`, the queue limit and
    /// withdrawal don't apply, and it has no caller to reply to. Its `ReportTurn` can't arm
    /// `.afterBatch` work (plan §3.9).
    mutating func handleReport(_ report: LaneReport, _ turn: inout ReportTurn<Self>)
}

extension TurnMachine {
    @inlinable public func inputPolicy(for input: Input) -> InputPolicy<Key> { .normal(waitsFor: nil, belongsTo: nil) }
    @inlinable public mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>) {}
    @inlinable public mutating func handleLateResult(_ input: Input, _ turn: inout Turn<Self>) {}
}

extension TurnMachine where Query == Never, Answer == Never {
    @inlinable public mutating func answer(_ query: Never, _ turn: inout Turn<Self>) -> Never {
        switch query {}
    }
}

extension TurnMachine where LaneReport == Never {
    @inlinable public mutating func handleReport(_ report: Never, _ turn: inout ReportTurn<Self>) {
        switch report {}
    }
}
