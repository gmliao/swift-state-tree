// Sources/SwiftStateTree/Support/SingleFlight.swift
//
// Run once per key: create, start or destroy something exactly once while concurrent callers
// share the result. Implements the "reserve the slot before the first await" half of the actor
// reentrancy rule (CLAUDE.md, "Actor reentrancy").

import Foundation

/// In-flight work per key, owned by one actor (a stored `var` of that actor, never shared).
///
/// The owner reserves the key synchronously, before its first `await`, by calling
/// `flight(for:start:)`. A caller that finds a flight running awaits the same task instead of
/// starting a second one.
///
/// Rules for the owner:
/// - The work runs in its own unstructured `Task` (made by `start`), not in the first caller's
///   task. A caller that is cancelled stops waiting (`SingleFlight.value(of:)`), but the shared
///   work goes on for the other callers. Only the owner cancels a flight (`cancelAll()`).
/// - The work ends with one synchronous segment on the owner that publishes its result (for
///   example inserts into the owner's map) and calls `finish(_:token:)`. If those two were
///   separated by an `await`, a caller in between would see neither and start a duplicate.
/// - On failure (including `CancellationError`) the work also calls `finish(_:token:)` before it
///   throws. The error reaches every current waiter; the next caller starts a fresh flight (no
///   negative caching).
/// - The work must not await a flight for its own key: it would wait for itself.
public struct SingleFlight<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    /// Identifies one flight, so a finished flight never removes a later flight for its key.
    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Entry: Sendable {
        let token: Token
        let task: Task<Value, Error>
    }

    private var entries: [Key: Entry] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// The task in flight for `key`, starting one with `start` when there is none.
    ///
    /// `start` receives the new flight's token, which the work passes to `finish(_:token:)`.
    /// It must return the task without awaiting anything.
    public mutating func flight(
        for key: Key,
        start: (Token) -> Task<Value, Error>
    ) -> Task<Value, Error> {
        if let entry = entries[key] {
            return entry.task
        }
        nextID += 1
        let token = Token(id: nextID)
        let task = start(token)
        entries[key] = Entry(token: token, task: task)
        return task
    }

    /// Ends the flight identified by `token`. A later flight for the same key is left alone.
    public mutating func finish(_ key: Key, token: Token) {
        if entries[key]?.token == token {
            entries.removeValue(forKey: key)
        }
    }

    /// The task in flight for `key`, if any.
    public func inFlight(_ key: Key) -> Task<Value, Error>? {
        entries[key]?.task
    }

    /// Number of keys with work in flight.
    public var count: Int { entries.count }

    /// Cancels every flight and returns their tasks, for the owner to await before tearing down.
    /// The entries stay until each flight's work calls `finish(_:token:)`.
    public func cancelAll() -> [Task<Value, Error>] {
        let tasks = entries.values.map(\.task)
        for task in tasks { task.cancel() }
        return tasks
    }

    /// Waits for a flight's value. If the calling task is cancelled, this caller stops waiting
    /// and throws `CancellationError`; the flight itself keeps running for the other callers.
    public static func value(of task: Task<Value, Error>) async throws -> Value {
        let waiter = FlightWaiter<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                guard waiter.install(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                Task {
                    do {
                        waiter.resume(with: .success(try await task.value))
                    } catch {
                        waiter.resume(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            waiter.resume(with: .failure(CancellationError()))
        }
    }
}

/// One waiter's continuation, resumed exactly once: by the flight's result or by cancellation.
private final class FlightWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    /// Stores the continuation; returns false if the waiter was already cancelled.
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.continuation = continuation
        return true
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// A generation number, for "did the state change while I was awaiting?".
///
/// Capture the current epoch before an `await`; after it, compare in the same synchronous segment
/// as the act (insert, remove, admit) and skip or compensate when it is no longer current.
/// Implements the "capture a generation" half of the actor reentrancy rule.
public struct Epoch: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Epoch, rhs: Epoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "epoch \(rawValue)" }
}

/// The current epoch per key. Every `advance(_:)` returns a value never handed out before by
/// this counter (for any key), so an older owner can tell it has been replaced, also after the
/// key was removed and started again.
public struct EpochCounter<Key: Hashable & Sendable>: Sendable {
    private var current: [Key: Epoch] = [:]
    private var last: UInt64 = 0

    public init() {}

    /// Starts a new epoch for `key` and returns it.
    public mutating func advance(_ key: Key) -> Epoch {
        last += 1
        let next = Epoch(rawValue: last)
        current[key] = next
        return next
    }

    /// Forgets `key` (its owner is gone). No later epoch equals the removed one.
    public mutating func remove(_ key: Key) {
        current.removeValue(forKey: key)
    }

    /// The latest epoch for `key`, if one was started.
    public func current(_ key: Key) -> Epoch? {
        current[key]
    }

    /// Whether `epoch` is still the latest one for `key`.
    public func isCurrent(_ epoch: Epoch, for key: Key) -> Bool {
        current[key] == epoch
    }
}
