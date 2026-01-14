import Foundation
import SwiftStateTree

// MARK: - Actions

/// Example action to play the game.
@Payload
public struct PlayAction: ActionPayload {
    public typealias Response = PlayResponse

    public init() {}
}

@Payload
public struct PlayResponse: ResponsePayload {
    public let newScore: Int

    public init(newScore: Int) {
        self.newScore = newScore
    }
}
