import SwiftStateTree

// MARK: - Actions

/// Restarts the monitor land's verification run once it has completed or failed; a no-op while
/// a run is loading, verifying or paused. The run always verifies the record bound in the land's
/// ticket (`ReevaluationMonitorRun`), started when the land was created.
///
/// `landType` and `recordFilePath` are ignored. They stay so that existing clients and generated
/// bindings keep encoding the action; a client can't choose the record or the projector.
@Payload
public struct StartVerificationAction: ActionPayload {
    public typealias Response = StartVerificationResponse
    /// Ignored: the land type comes from the land's ticket.
    public let landType: String
    /// Ignored: the record comes from the land's ticket.
    public let recordFilePath: String

    public init(landType: String, recordFilePath: String) {
        self.landType = landType
        self.recordFilePath = recordFilePath
    }
}

@Payload
public struct StartVerificationResponse: ResponsePayload {
    public init() {}
}

@Payload
public struct PauseVerificationAction: ActionPayload {
    public typealias Response = PauseVerificationResponse
    public init() {}
}

@Payload
public struct PauseVerificationResponse: ResponsePayload {
    public init() {}
}

@Payload
public struct ResumeVerificationAction: ActionPayload {
    public typealias Response = ResumeVerificationResponse
    public init() {}
}

@Payload
public struct ResumeVerificationResponse: ResponsePayload {
    public init() {}
}

// MARK: - The monitor land's run

/// The record a reevaluation monitor land verifies, and the land type it was taken from: read
/// from the land's ticket, which the admin monitor start signed, when the land is created. The
/// land's services carry it; `StartVerificationAction` restarts the run with it, never with a
/// path from the client.
public struct ReevaluationMonitorRun: Sendable, Equatable {
    public let landType: String
    public let recordFilePath: String

    public init(landType: String, recordFilePath: String) {
        self.landType = landType
        self.recordFilePath = recordFilePath
    }
}
