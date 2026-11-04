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

/// Outcome of `OutboundWriter.enqueue`.
enum OutboundEnqueueResult: Equatable {
    case accepted
    /// Dropped: the backlog was over its byte ceiling. The caller must disconnect the sessions
    /// the element addressed; their clients rejoin and get a fresh firstSync.
    case droppedOverCeiling
    /// Dropped: the writer was finished (teardown).
    case droppedAfterFinish
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
    /// Queued elements that are a sync cycle's frames (a subset of `elements`).
    public let syncCycleElements: Int

    public init(elements: Int, bytes: Int, dropped: Int, droppedAfterFinish: Int, syncCycleElements: Int = 0) {
        self.elements = elements
        self.bytes = bytes
        self.dropped = dropped
        self.droppedAfterFinish = droppedAfterFinish
        self.syncCycleElements = syncCycleElements
    }
}

/// One writer element: frames in send order, and whether they are a sync cycle's output.
struct OutboundElement: Sendable {
    let frames: [SessionFrame]
    let isSyncCycle: Bool
}

/// Lock-protected counters shared by the writer and its consumer task (which must not retain
/// the writer: the writer finishes its stream on deinit).
private final class OutboundWriterCounters: @unchecked Sendable {
    let lock = NSLock()
    var elements = 0
    var bytes = 0
    var dropped = 0
    var droppedAfterFinish = 0
    var syncCycleElements = 0
    var lastCeilingLogAt: ContinuousClock.Instant?
    /// Waiters for `syncCycleElements == 0` (see `OutboundWriter.waitForSyncCycleDrain`).
    var syncCycleDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set when the consumer task ended; later waits return at once.
    var consumerEnded = false

    func sent(bytes sentBytes: Int, isSyncCycle: Bool) {
        lock.lock()
        elements -= 1
        bytes -= sentBytes
        var waiters: [CheckedContinuation<Void, Never>] = []
        if isSyncCycle {
            syncCycleElements -= 1
            if syncCycleElements == 0 {
                waiters = syncCycleDrainWaiters
                syncCycleDrainWaiters = []
            }
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Resumes every waiter (the consumer ended: nothing more will drain).
    func releaseWaiters() {
        lock.lock()
        consumerEnded = true
        let waiters = syncCycleDrainWaiters
        syncCycleDrainWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    var backlog: OutboundBacklog {
        lock.lock()
        defer { lock.unlock() }
        return OutboundBacklog(
            elements: elements,
            bytes: bytes,
            dropped: dropped,
            droppedAfterFinish: droppedAfterFinish,
            syncCycleElements: syncCycleElements
        )
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
/// and logged, and `enqueue` returns `.droppedOverCeiling` so the adapter disconnects the
/// sessions it addressed (a dropped frame must never leave a client silently on wrong state).
/// An element larger than the whole ceiling is still accepted when the backlog is empty, so a
/// single large frame cannot wedge a land.
///
/// The ceiling measures only the writer→transport handoff. `WebSocketTransport.sendSessionFrames`
/// yields into each session's own stream and returns, so socket backpressure from a slow client
/// never reaches this backlog: it is not a slow-client memory bound. That policy is #61.
final class OutboundWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<OutboundElement>.Continuation?
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
        let (stream, continuation) = AsyncStream<OutboundElement>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        let counters = OutboundWriterCounters()
        self.counters = counters
        self.consumer = Task {
            for await element in stream {
                if Task.isCancelled { break }
                let start = ContinuousClock.now
                await transport.sendSessionFrames(element.frames)
                onSent?(ContinuousClock.now - start, element.frames.count)
                counters.sent(bytes: element.frames.reduce(0) { $0 + $1.data.count }, isSyncCycle: element.isSyncCycle)
            }
            counters.releaseWaiters()
        }
    }

    deinit {
        continuation?.finish()
    }

    /// Enqueues one element (frames in send order). Synchronous. `isSyncCycle` marks a sync
    /// cycle's frames, counted in `OutboundBacklog.syncCycleElements` (sync back-pressure).
    @discardableResult
    func enqueue(_ frames: [SessionFrame], isSyncCycle: Bool = false) -> OutboundEnqueueResult {
        guard !frames.isEmpty else { return .accepted }
        let bytes = frames.reduce(0) { $0 + $1.data.count }

        lock.lock()
        defer { lock.unlock() }
        guard let continuation else {
            counters.lock.lock()
            counters.droppedAfterFinish += 1
            counters.lock.unlock()
            return .droppedAfterFinish
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
                logger.error("Outbound writer backlog over its ceiling; dropping frames and disconnecting their sessions", metadata: [
                    "queuedElements": .stringConvertible(snapshot.0),
                    "queuedBytes": .stringConvertible(snapshot.1),
                    "maxBytes": .stringConvertible(maxBytes),
                    "droppedTotal": .stringConvertible(snapshot.2),
                ])
            }
            return .droppedOverCeiling
        }
        counters.elements += 1
        counters.bytes += bytes
        if isSyncCycle { counters.syncCycleElements += 1 }
        counters.lock.unlock()
        continuation.yield(OutboundElement(frames: frames, isSyncCycle: isSyncCycle))
        return .accepted
    }

    var backlog: OutboundBacklog {
        counters.backlog
    }

    /// Returns once no sync cycle element is queued (at once when none is), or when the
    /// consumer has ended.
    func waitForSyncCycleDrain() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            counters.lock.lock()
            if counters.syncCycleElements == 0 || counters.consumerEnded {
                counters.lock.unlock()
                waiter.resume()
                return
            }
            counters.syncCycleDrainWaiters.append(waiter)
            counters.lock.unlock()
        }
    }

    /// Removes the continuation, so later `enqueue` calls are dropped.
    private func takeContinuation() -> AsyncStream<OutboundElement>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }

    /// Stops accepting frames, lets the consumer hand the queued ones to the transport and waits
    /// for that up to `timeout`. Returns within about `timeout` even when the transport never
    /// returns: the wait races the consumer against a deadline in unstructured tasks (a task
    /// group would have to join the consumer), then cancels the consumer and logs what is left.
    /// Returns whether the backlog drained.
    @discardableResult
    func finish(timeout: Duration) async -> Bool {
        takeContinuation()?.finish()

        let consumer = self.consumer
        let drained = await withCheckedContinuation { (result: CheckedContinuation<Bool, Never>) in
            let once = OutboundResumeOnce(result)
            Task {
                await consumer.value
                once.resume(true)
            }
            Task {
                try? await safeTaskSleep(for: timeout)
                once.resume(false)
            }
        }
        if !drained {
            consumer.cancel()
            let backlog = counters.backlog
            logger.warning("Outbound writer did not drain before teardown timeout; frames left unsent", metadata: [
                "queuedElements": .stringConvertible(backlog.elements),
                "queuedBytes": .stringConvertible(backlog.bytes),
            ])
        }
        return drained
    }
}

/// Resumes a continuation once; later calls are ignored.
private final class OutboundResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
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
