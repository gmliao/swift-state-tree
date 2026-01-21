
/// Service to expose ReevaluationRecorder to LandContext
public struct ReevaluationRecorderService: Sendable {
    public let recorder: ReevaluationRecorder

    public init(recorder: ReevaluationRecorder) {
        self.recorder = recorder
    }
}
