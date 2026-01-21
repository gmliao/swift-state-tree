import Foundation

/// A sink for re-evaluation outputs.
///
/// This is used to feed recorded outputs (e.g., server events) into:
/// - file exporters (JSONL)
/// - playback servers (WebSocket/HTTP)
/// - verification tools
public protocol ReevaluationSink: Sendable {
    /// Called during `.reevaluation` ticks to emit the recorded server events for that tick.
    func onRecordedServerEvents(
        tickId: Int64,
        events: [ReevaluationRecordedServerEvent]
    ) async
}

