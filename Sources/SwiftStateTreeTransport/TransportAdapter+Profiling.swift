// Sources/SwiftStateTreeTransport/TransportAdapter+Profiling.swift
//
// Profiling instrumentation for TransportAdapter. Extracted for separation of concerns.
// When TRANSPORT_PROFILE_JSONL_PATH is set, records counters (atomics) and latency (sampled 1 in 100).

import Foundation

extension TransportAdapter {

    /// Profiling operation type.
    enum ProfilingOperation {
        case send
        case handle
    }

    /// Record profiling metrics for an operation.
    ///
    /// Tracks operation latency (sampled 1 in 100) based on operation type.
    ///
    /// - Parameters:
    ///   - startTime: Operation start time
    ///   - operation: Operation type (determines which profiler method to call)
    func recordProfiling(startTime: ContinuousClock.Instant, operation: ProfilingOperation) async {
        guard let profiler else { return }

        let elapsed = ContinuousClock.now - startTime
        let durationMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        latencySampleCounter += 1

        if latencySampleCounter % 100 == 0 {
            switch operation {
            case .send:
                Task { await profiler.recordSend(durationMs: durationMs) }
            case .handle:
                Task { await profiler.recordHandle(durationMs: durationMs) }
            }
        }
    }

    /// Send data to transport with profiling instrumentation.
    ///
    /// Tracks send latency (sampled 1 in 100) and increments state update counter.
    ///
    /// - Parameters:
    ///   - data: Data to send
    ///   - target: Transport target
    ///   - yieldAfterSend: Whether to yield after send (default: false)
    func sendWithProfiling(
        _ data: Data,
        to target: EventTarget,
        yieldAfterSend: Bool = false
    ) async {
        profilerCounters?.incrementStateUpdates()
        let sendStart = ContinuousClock.now
        await transport.send(data, to: target)
        if yieldAfterSend {
            await Task.yield()
        }
        await recordProfiling(startTime: sendStart, operation: .send)
    }

    /// Send batch to transport with profiling instrumentation.
    ///
    /// Tracks send latency (sampled 1 in 100) and increments state update counter.
    /// Records average latency per update in batch.
    ///
    /// - Parameters:
    ///   - batch: Batch of messages to send
    ///   - stateUpdateCount: Number of state updates in batch
    func sendBatchWithProfiling(
        _ batch: [(Data, EventTarget)],
        stateUpdateCount: Int
    ) async {
        profilerCounters?.incrementStateUpdates(by: stateUpdateCount)
        let sendStart = ContinuousClock.now
        if let queue = transportSendQueue {
            queue.enqueueBatch(batch)
        } else {
            await transport.sendBatch(batch)
        }
        await Task.yield()
        if let profiler {
            let sendElapsed = ContinuousClock.now - sendStart
            let sendMs = Double(sendElapsed.components.seconds) * 1000 + Double(sendElapsed.components.attoseconds) / 1e15
            // Sample latency for each update in batch (distributed)
            for _ in 0..<stateUpdateCount {
                latencySampleCounter += 1
                if latencySampleCounter % 100 == 0 {
                    // Record average latency per update
                    Task { await profiler.recordSend(durationMs: sendMs / Double(stateUpdateCount)) }
                }
            }
        }
    }
}
