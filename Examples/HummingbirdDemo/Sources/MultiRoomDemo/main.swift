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
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger with custom log level
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "MultiRoomDemo",
            logLevel: .debug
        )

        // Get port from environment variable, default to 8080
        let port = HummingbirdDemoContent.getEnvUInt16(key: "PORT", defaultValue: 8080)

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
            }
        )
        
        logger.info("🚀 Multi-room server started")
        logger.info("📡 WebSocket endpoint: ws://localhost:\(port)/game")
        logger.info("💡 Connect with different landIDs to create different rooms")
        logger.info("   Example: ws://localhost:\(port)/game?token=<jwt>&landID=room-123")
        
        try await server.run()
    }
}
