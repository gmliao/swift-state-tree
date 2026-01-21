import SwiftStateTree

public struct ReevaluationStepResult: Sendable {
    public let tickId: Int64
    public let stateHash: String
    public let recordedHash: String?
    public let isMatch: Bool

    public init(tickId: Int64, stateHash: String, recordedHash: String?, isMatch: Bool) {
        self.tickId = tickId
        self.stateHash = stateHash
        self.recordedHash = recordedHash
        self.isMatch = isMatch
    }
}

public protocol ReevaluationRunnerProtocol: Sendable {
    var maxTickId: Int64 { get }
    func prepare() async throws
    func step() async throws -> ReevaluationStepResult?
}

public protocol ReevaluationTargetFactory: Sendable {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol
}

public struct ReevaluationStatus: Sendable {
    public enum Phase: String, Sendable {
        case idle
        case loading
        case verifying
        case paused
        case completed
        case failed
    }

    public var phase: Phase = .idle
    public var currentTick: Int64 = 0
    public var totalTicks: Int64 = 0
    public var correctTicks: Int = 0
    public var mismatchedTicks: Int = 0
    public var errorMessage: String = ""
    public var recordFilePath: String = ""

    public var currentExpectedHash: String = ""
    public var currentActualHash: String = ""
    public var currentIsMatch: Bool = true

    public init() {}
}
