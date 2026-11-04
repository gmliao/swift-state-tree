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

    /// Enqueues a state frame on the outbound writer and counts it (profiling). The send
    /// latency is sampled by the writer's consumer.
    func sendWithProfiling(_ data: Data, to target: EventTarget) {
        profilerCounters?.incrementStateUpdates()
        enqueueOutbound(data, toSessions: sessionIDs(for: target))
    }

    /// Enqueues a batch of frames on the outbound writer, in order, and counts its state
    /// updates (profiling).
    func sendBatchWithProfiling(_ batch: [(Data, EventTarget)], stateUpdateCount: Int) {
        profilerCounters?.incrementStateUpdates(by: stateUpdateCount)
        var frames: [SessionFrame] = []
        frames.reserveCapacity(batch.count)
        for (data, target) in batch {
            for sessionID in sessionIDs(for: target) {
                frames.append(sessionFrame(data, to: sessionID))
            }
        }
        enqueueFrames(frames)
    }
}
