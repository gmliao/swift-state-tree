import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo: Multi-Room Architecture Example
///
/// This demo demonstrates the **multi-room mode** using `LandServer.makeMultiRoomServer()`.
/// Supports dynamic room creation and multiple concurrent rooms.
///
/// **Multi-Room Mode Characteristics**:
/// - Dynamic land/room creation (lands are created on-demand)
/// - Multiple concurrent lands/rooms can exist simultaneously
/// - Uses `LandManager` and `LandRouter` for room management
/// - Suitable for production environments
///
/// **Alternative**: You can also use `LandRealm` to manage multiple land types with different State types.
/// See `DESIGN_STATE_BINDING_AND_INITIALIZATION.md` for more details.
@main
struct MultiRoomDemo {
    static func main() async throws {
        typealias DemoLandServer = LandServer<CookieGameState>

        // JWT Configuration for demo/testing purposes
        // ⚠️ WARNING: This is a demo secret key. CHANGE THIS IN PRODUCTION!
        // In production, use environment variables or secure key management:
        //   export JWT_SECRET_KEY="your-secure-secret-key-here"
        let demoJWTSecretKey = "demo-secret-key-change-in-production"
        let jwtConfig = JWTConfiguration(
            secretKey: demoJWTSecretKey,
            algorithm: .HS256,
            validateExpiration: true
        )

        // Create logger with custom log level
        let logger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "MultiRoomDemo",
            logLevel: .debug
        )

        let port: UInt16 = {
            guard
                let raw = ProcessInfo.processInfo.environment["PORT"],
                let value = Int(raw),
                value >= 0,
                value <= Int(UInt16.max)
            else {
                return 8080
            }
            return UInt16(value)
        }()

        // Multi-room mode: Create a server that supports dynamic room creation
        // Lands are created on-demand when clients join with a specific landID
        let server = try await DemoLandServer.makeMultiRoomServer(
            configuration: DemoLandServer.Configuration(
                host: "localhost",
                port: port,
                webSocketPath: "/game",
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true // Enable guest mode: allow connections without JWT token
            ),
            landFactory: { landID in
                // Factory function to create LandDefinition for a given LandID
                // This allows different lands to have different configurations if needed.
                // In this demo, all lands use the same cookie-clicker definition.
                HummingbirdDemoContent.CookieGame.makeLand()
            },
            initialStateFactory: { landID in
                // Factory function to create initial state for a given LandID
                // This allows different lands to have different initial states if needed.
                // In this demo, all lands start with the same initial cookie state.
                CookieGameState()
            },
            createGuestSession: { _, clientID in
                // Create PlayerSession for guest users
                let randomID = String(UUID().uuidString.prefix(6))
                return PlayerSession(
                    playerID: "guest-\(randomID)",
                    deviceID: clientID.rawValue,
                    metadata: [
                        "isGuest": "true",
                        "connectedAt": ISO8601DateFormatter().string(from: Date()),
                        "clientID": clientID.rawValue,
                    ]
                )
            }
        )
        
        logger.info("🚀 Multi-room server started")
        logger.info("📡 WebSocket endpoint: ws://localhost:\(port)/game")
        logger.info("💡 Connect with different landIDs to create different rooms")
        logger.info("   Example: ws://localhost:\(port)/game?token=<jwt>&landID=room-123")
        
        try await server.run()
    }
}
