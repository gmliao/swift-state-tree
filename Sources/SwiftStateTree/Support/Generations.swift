// Sources/SwiftStateTree/Support/Generations.swift
//
// Generation tickets and a synchronous check-and-act, for state that isn't changed inside a
// keeper turn (adapter, transport, router, host). The keeper's own state changes only in turns;
// async work there returns as a turn input (see the "Reentrancy" rule in CLAUDE.md / AGENTS.md).

/// One key's generation, captured before an `await` and checked after it.
package struct Ticket<Key: Hashable & Sendable>: Hashable, Sendable, CustomStringConvertible {
    package let key: Key
    package let epoch: Epoch

    package var description: String { "\(key)@\(epoch.rawValue)" }
}

/// Proof that a ticket was current, handed to a check-and-act closure by
/// `GenerationTable.ifCurrent`. It can't be made elsewhere or copied out of the closure, so a
/// mutator that takes one can only run inside the check's synchronous segment.
package struct Current<Key: Hashable & Sendable>: ~Copyable {
    package let ticket: Ticket<Key>

    fileprivate init(_ ticket: Ticket<Key>) {
        self.ticket = ticket
    }
}

/// The current generation of each key. `issue` starts a new generation (a new session, a new
/// admission, a new run); `end` ends it. A ticket from an earlier generation is never current
/// again, also after its key was ended and issued anew.
///
/// Owned by one actor (a stored `var`), like `SingleFlight`.
package struct GenerationTable<Key: Hashable & Sendable>: Sendable {
    private var counter = EpochCounter()
    private var current: [Key: Epoch] = [:]

    package init() {}

    /// Starts a new generation of `key`, replacing any current one.
    @discardableResult
    package mutating func issue(_ key: Key) -> Ticket<Key> {
        let epoch = counter.next()
        current[key] = epoch
        return Ticket(key: key, epoch: epoch)
    }

    /// The current ticket of `key`, if it has one.
    package func ticket(for key: Key) -> Ticket<Key>? {
        current[key].map { Ticket(key: key, epoch: $0) }
    }

    package func isCurrent(_ ticket: Ticket<Key>) -> Bool {
        current[ticket.key] == ticket.epoch
    }

    /// Ends `key`'s current generation, whatever it is.
    package mutating func end(_ key: Key) {
        current.removeValue(forKey: key)
    }

    /// Ends `ticket`'s generation only if it is still the current one; returns whether it was.
    /// For a callback that can outlive its generation: it must not end a newer one.
    @discardableResult
    package mutating func end(_ ticket: Ticket<Key>) -> Bool {
        guard isCurrent(ticket) else { return false }
        current.removeValue(forKey: ticket.key)
        return true
    }

    /// Runs `act` only if `ticket` is current, and returns its result (`nil` when it wasn't).
    ///
    /// `act` is not `async`, so the compiler rejects an `await` between the check and the act:
    /// both are one synchronous segment of the owning actor. A `Task` started inside `act`
    /// escapes the guard; its work must check its own ticket.
    package func ifCurrent<R>(_ ticket: Ticket<Key>, _ act: (borrowing Current<Key>) throws -> R) rethrows -> R? {
        guard isCurrent(ticket) else { return nil }
        let proof = Current(ticket)
        return try act(proof)
    }
}
