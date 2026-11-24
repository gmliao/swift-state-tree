import Foundation
import SwiftStateTree

// MARK: - Server Events

public struct TickSummary: Codable, Sendable {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

@Payload
public struct TickSummaryEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

@Payload
public struct TickProcessedEvent: ServerEventPayload {
    public let tickId: Int64
    /// The state's JSON text, as the runner's snapshot (`ReevaluationStateText`).
    public let expectedState: String
    /// The state's JSON text, as the runner's snapshot (`ReevaluationStateText`).
    public let actualState: String
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(
        tickId: Int64,
        expectedState: String,
        actualState: String,
        isMatch: Bool,
        expectedHash: String,
        actualHash: String
    ) {
        self.tickId = tickId
        self.expectedState = expectedState
        self.actualState = actualState
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

@Payload
public struct VerificationProgressEvent: ServerEventPayload {
    public let processedTicks: Int
    public let totalTicks: Int

    public init(processedTicks: Int, totalTicks: Int) {
        self.processedTicks = processedTicks
        self.totalTicks = totalTicks
    }
}

@Payload
public struct VerificationCompleteEvent: ServerEventPayload {
    public let totalTicks: Int
    public let correctTicks: Int
    public let mismatchedTicks: Int
    public let mismatches: [TickMismatch]

    public init(
        totalTicks: Int,
        correctTicks: Int,
        mismatchedTicks: Int,
        mismatches: [TickMismatch]
    ) {
        self.totalTicks = totalTicks
        self.correctTicks = correctTicks
        self.mismatchedTicks = mismatchedTicks
        self.mismatches = mismatches
    }
}

@Payload
public struct VerificationFailedEvent: ServerEventPayload {
    public let errorMessage: String

    public init(errorMessage: String) {
        self.errorMessage = errorMessage
    }
}

/// A step result's state as the monitor sends it: JSON text. The built-in runner already puts
/// the snapshot's JSON text in `ReevaluationStepResult.actualState`, which passes through; any
/// other value, from another runner, is encoded as JSON text with sorted keys.
enum ReevaluationStateText {
    static func text(of state: AnyCodable) -> String? {
        if let text = state.base as? String { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
