import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Mock transport implementation for benchmarks that counts sent bytes and messages.
/// Implements Transport protocol and provides registerSession for compatibility with TransportAdapter.
actor CountingTransport: Transport {
    var delegate: TransportDelegate?

    private var sentBytes: Int = 0
    private var sentMessages: Int = 0
    // Track player sessions for compatibility (not used in benchmarks, but required by TransportAdapter)
    private var playerSessions: [PlayerID: Set<SessionID>] = [:]

    func start() async throws {}

    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) async throws {
        sentBytes += message.count
        sentMessages += 1
    }

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    /// Register a session for a player (required by TransportAdapter, but not used in benchmarks)
    func registerSession(_ sessionID: SessionID, for playerID: PlayerID) {
        playerSessions[playerID, default: []].insert(sessionID)
    }

    func resetCounts() {
        sentBytes = 0
        sentMessages = 0
    }

    func snapshotCounts() -> (bytes: Int, messages: Int) {
        (sentBytes, sentMessages)
    }
}
