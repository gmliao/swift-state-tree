import Foundation
import SwiftStateTreeHummingbirdDemoContent
import SwiftStateTreeHummingbirdHosting
import SwiftStateTree

@main
struct HummingbirdDemo {
    static func main() async throws {
        typealias DemoAppContainer = AppContainer<DemoGameState, DemoClientEvents, DemoServerEvents>
        
        // Configure how PlayerSession is created from sessionID and clientID
        // This allows you to extract playerID, deviceID, and metadata from:
        // - WebSocket handshake headers (Authorization, X-User-ID, etc.)
        // - JWT tokens
        // - Database lookups
        // - Session cookies
        //
        // For this demo, we use sessionID as playerID (simple case).
        // In production, you would extract this from auth headers or tokens.
        let container = try await DemoAppContainer.makeServer(
            land: DemoGame.makeLand(),
            initialState: DemoGameState(),
            createPlayerSession: { sessionID, clientID in
                // Example: Extract playerID from sessionID
                // In a real app, you might:
                // 1. Extract from WebSocket headers: context.request.headers["Authorization"]
                // 2. Parse JWT token to get playerID
                // 3. Lookup session in database
                // 4. Extract deviceID from headers: context.request.headers["X-Device-ID"]
                
                // For demo purposes, use sessionID as playerID
                // You can also extract deviceID from clientID or headers
                PlayerSession(
                    playerID: sessionID.rawValue,  // In production: extract from auth token/headers
                    deviceID: clientID.rawValue, // In production: extract from headers
                    metadata: [
                        "connectedAt": ISO8601DateFormatter().string(from: Date()),
                        "clientID": clientID.rawValue
                    ]
                )
            }
        )
        try await container.run()
    }
}

