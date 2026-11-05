// Sources/SwiftStateTreeNIO/InboundTaskChain.swift
//
// Runs a session's inbound operations (connect, messages, disconnect) one after another, in
// enqueue order.

import Foundation

/// Serial chain of async operations: each one starts after the previous one has finished.
///
/// `WebSocketSessionHandler` hands its connect, message batches and disconnect to the transport
/// from the channel's event loop, which cannot await. Separate `Task`s give no order between them,
/// so a client's first message (its join) could reach the transport before the connection was
/// registered and be answered into a session that did not exist yet.
final class InboundTaskChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    /// Waits until every operation enqueued so far has finished.
    func waitForIdle() async {
        let current: Task<Void, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            return tail
        }()
        await current?.value
    }
}
