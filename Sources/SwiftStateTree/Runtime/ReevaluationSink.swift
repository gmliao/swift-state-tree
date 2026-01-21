import Foundation

/// A sink for re-evaluation outputs.
///
/// This is used to feed re-evaluated outputs (e.g., emitted server events) into:
/// - file exporters (JSONL)
/// - playback servers (WebSocket/HTTP)
/// - verification tools
public protocol ReevaluationSink: Sendable {
    /// Called during `.reevaluation` ticks to emit server events for that tick.
    func onEmittedServerEvents(
        tickId: Int64,
        events: [ReevaluationRecordedServerEvent]
    ) async
}

