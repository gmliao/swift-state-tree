import SwiftStateTree

// MARK: - Actions

@Payload
public struct StartVerificationAction: ActionPayload {
    public typealias Response = StartVerificationResponse
    public let landType: String
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
