// Sources/SwiftStateTreeTransport/OutboundWriter.swift
//
// One ordered outbound FIFO per TransportAdapter (#60).

import Foundation
import Logging
import SwiftStateTree

/// One frame for one session of a land.
///
/// Outbound frames only ever address a single session, so a frame cannot reach sessions of
/// another land on a shared transport (#84). Group targets (`.all`, `.player`, `.client`) are
/// expanded by the adapter, from its own membership, before frames are enqueued.
public struct SessionFrame: Sendable {
    public let data: Data
    public let sessionID: SessionID
    /// The transport connection this frame was produced for (see
    /// `WebSocketTransport.connectionGeneration(for:)`). The transport drops the frame when the
    /// session's current connection has a different generation, so frames meant for an ended
    /// connection never reach a later connection that reuses the `SessionID`. `nil`: not checked.
    public let connectionGeneration: UInt64?

    public init(data: Data, sessionID: SessionID, connectionGeneration: UInt64?) {
        self.data = data
        self.sessionID = sessionID
        self.connectionGeneration = connectionGeneration
    }
}

/// Backlog of an `OutboundWriter`, for tests and diagnostics.
public struct OutboundBacklog: Sendable, Equatable {
    /// Elements enqueued but not yet handed to the transport.
    public let elements: Int
    /// Bytes of those elements.
    public let bytes: Int
    /// Elements dropped because the backlog was over its byte ceiling.
    public let dropped: Int
    /// Elements dropped because they were enqueued after `finish`.
    public let droppedAfterFinish: Int
}

/// Lock-protected counters shared by the writer and its consumer task (which must not retain
/// the writer: the writer finishes its stream on deinit).
private final class OutboundWriterCounters: @unchecked Sendable {
    let lock = NSLock()
    var elements = 0
    var bytes = 0
    var dropped = 0
    var droppedAfterFinish = 0
    var lastCeilingLogAt: ContinuousClock.Instant?

    func sent(bytes sentBytes: Int) {
        lock.lock()
        elements -= 1
        bytes -= sentBytes
        lock.unlock()
    }

    var backlog: OutboundBacklog {
        lock.lock()
        defer { lock.unlock() }
        return OutboundBacklog(elements: elements, bytes: bytes, dropped: dropped, droppedAfterFinish: droppedAfterFinish)
    }
}

/// The ordered outbound FIFO of one `TransportAdapter`.
///
/// Contract: every frame the adapter sends to a session of its land after the session joins goes
/// through `enqueue`, in the order the adapter issues it, and reaches the transport in that order.
/// `enqueue` is synchronous, so a sync cycle never awaits a send. One consumer task hands each
/// element to `Transport.sendSessionFrames` and awaits it before taking the next.
///
/// The backlog is bounded by `maxBytes`: an element that would push it over is dropped, counted
/// and logged (the per-session policy is #61). An element larger than the whole ceiling is still
/// accepted when the backlog is empty, so a single large frame cannot wedge a land.
final class OutboundWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[SessionFrame]>.Continuation?
    private let consumer: Task<Void, Never>
    private let counters: OutboundWriterCounters
    private let maxBytes: Int
    private let logger: Logger
    private static let ceilingLogInterval: Duration = .seconds(2)

    /// - Parameters:
    ///   - transport: Destination. The consumer captures the transport, the stream and the
    ///     counters only, never the adapter.
    ///   - maxBytes: Ceiling for the queued bytes.
    ///   - onSent: Called by the consumer after each element was handed to the transport, with
    ///     the time from dequeue to return and the number of frames (profiling).
    init(
        transport: any Transport,
        maxBytes: Int,
        logger: Logger,
        onSent: (@Sendable (Duration, Int) -> Void)? = nil
    ) {
        self.maxBytes = max(1, maxBytes)
        self.logger = logger
        let (stream, continuation) = AsyncStream<[SessionFrame]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let counters = OutboundWriterCounters()
        self.counters = counters
        self.consumer = Task {
            for await element in stream {
                let start = ContinuousClock.now
                await transport.sendSessionFrames(element)
                onSent?(ContinuousClock.now - start, element.count)
                counters.sent(bytes: element.reduce(0) { $0 + $1.data.count })
            }
        }
    }

    deinit {
        continuation?.finish()
    }

    /// Enqueues one element (frames in send order). Synchronous; returns whether it was accepted.
    @discardableResult
    func enqueue(_ frames: [SessionFrame]) -> Bool {
        guard !frames.isEmpty else { return true }
        let bytes = frames.reduce(0) { $0 + $1.data.count }

        lock.lock()
        defer { lock.unlock() }
        guard let continuation else {
            counters.lock.lock()
            counters.droppedAfterFinish += 1
            counters.lock.unlock()
            return false
        }
        counters.lock.lock()
        if counters.elements > 0, counters.bytes + bytes > maxBytes {
            counters.dropped += 1
            let now = ContinuousClock.now
            let shouldLog = counters.lastCeilingLogAt.map { now - $0 >= Self.ceilingLogInterval } ?? true
            if shouldLog { counters.lastCeilingLogAt = now }
            let snapshot = (counters.elements, counters.bytes, counters.dropped)
            counters.lock.unlock()
            if shouldLog {
                logger.error("Outbound writer backlog over its ceiling; dropping frames", metadata: [
                    "queuedElements": .stringConvertible(snapshot.0),
                    "queuedBytes": .stringConvertible(snapshot.1),
                    "maxBytes": .stringConvertible(maxBytes),
                    "droppedTotal": .stringConvertible(snapshot.2),
                ])
            }
            return false
        }
        counters.elements += 1
        counters.bytes += bytes
        counters.lock.unlock()
        continuation.yield(frames)
        return true
    }

    var backlog: OutboundBacklog {
        counters.backlog
    }

    /// Removes the continuation, so later `enqueue` calls are dropped.
    private func takeContinuation() -> AsyncStream<[SessionFrame]>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }

    /// Stops accepting frames, lets the consumer hand the queued ones to the transport and waits
    /// for that up to `timeout`. Logs what is left when the wait times out.
    func finish(timeout: Duration) async {
        takeContinuation()?.finish()

        let consumer = self.consumer
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await consumer.value
                return true
            }
            group.addTask {
                try? await safeTaskSleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !drained {
            let backlog = counters.backlog
            logger.warning("Outbound writer did not drain before teardown timeout", metadata: [
                "queuedElements": .stringConvertible(backlog.elements),
                "queuedBytes": .stringConvertible(backlog.bytes),
            ])
        }
    }
}

/// Samples 1 in `every` calls (profiling of the writer's send latency).
final class OutboundSendSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    private let every: UInt64

    init(every: UInt64) {
        self.every = max(1, every)
    }

    func shouldSample() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count % every == 0
    }
}
