// The machine: the state a turn changes, and the four steps that change it.

/// A value type whose steps are synchronous. Every stored field is plain data (`@PlainData`), so
/// a machine holds nothing it can call through or that changes behind it.
///
/// A machine is changed only inside a step, and a step can't await: work it needs done is a
/// request, and the request's result comes back as an input.
public protocol TurnMachine: Sendable {
    /// External inputs and effect results alike.
    associatedtype Input: Sendable
    /// Asynchronous work, as data; the adopter's `perform` does it.
    associatedtype Effect: Sendable
    /// What a step leaves for the adopter's synchronous `flush`.
    associatedtype Output
    associatedtype Key: Hashable & Sendable
    associatedtype Reply: Sendable
    /// A synchronous collaborator's questions, answered as a step (`TurnActor.ask`).
    associatedtype Query = Never
    associatedtype Answer = Never

    /// How `input` is admitted. Default: external, with no hold and no scope.
    func admission(of input: Input) -> Admission<Key>
    mutating func handle(_ input: Input, _ turn: inout Turn<Self>)
    /// A request closed without its completion. Default: nothing.
    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>)
    /// The result of a request that had already closed: its worker has retired. Default: nothing.
    mutating func handleStale(_ input: Input, _ turn: inout Turn<Self>)
    mutating func answer(_ query: Query, _ turn: inout Turn<Self>) -> Answer
}

extension TurnMachine {
    @inlinable public func admission(of input: Input) -> Admission<Key> { .external(hold: nil, scope: nil) }
    @inlinable public mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<Self>) {}
    @inlinable public mutating func handleStale(_ input: Input, _ turn: inout Turn<Self>) {}
}

extension TurnMachine where Query == Never, Answer == Never {
    @inlinable public mutating func answer(_ query: Never, _ turn: inout Turn<Self>) -> Never {
        switch query {}
    }
}
