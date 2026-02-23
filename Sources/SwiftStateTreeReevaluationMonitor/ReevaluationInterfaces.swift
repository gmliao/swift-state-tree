import SwiftStateTree

public struct ProjectedReplayFrame: Sendable {
    public let tickID: Int64
    public let stateObject: [String: AnyCodable]
    public let serverEvents: [AnyCodable]

    public init(
        tickID: Int64,
        stateObject: [String: AnyCodable],
        serverEvents: [AnyCodable] = []
    ) {
        self.tickID = tickID
        self.stateObject = stateObject
        self.serverEvents = serverEvents
    }
}

public protocol ReevaluationReplayProjecting: Sendable {
    func project(_ result: ReevaluationStepResult) throws -> ProjectedReplayFrame
}

public typealias ReevaluationReplayProjectorResolver = @Sendable (String) -> (any ReevaluationReplayProjecting)?

public struct ReevaluationStepResult: Sendable {
    public let tickId: Int64
    public let stateHash: String
    public let recordedHash: String?
    public let isMatch: Bool
    public let actualState: AnyCodable?
    public let emittedServerEvents: [ReevaluationRecordedServerEvent]
    /// Recorded server events from the record file for this tick (used when replayEventPolicy is projectedWithFallback).
    public let recordedServerEvents: [ReevaluationRecordedServerEvent]
    public let projectedFrame: ProjectedReplayFrame?

    public init(
        tickId: Int64,
        stateHash: String,
        recordedHash: String?,
        isMatch: Bool,
        actualState: AnyCodable? = nil,
        emittedServerEvents: [ReevaluationRecordedServerEvent] = [],
        recordedServerEvents: [ReevaluationRecordedServerEvent] = [],
        projectedFrame: ProjectedReplayFrame? = nil
    ) {
        self.tickId = tickId
        self.stateHash = stateHash
        self.recordedHash = recordedHash
        self.isMatch = isMatch
        self.actualState = actualState
        self.emittedServerEvents = emittedServerEvents
        self.recordedServerEvents = recordedServerEvents
        self.projectedFrame = projectedFrame
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
