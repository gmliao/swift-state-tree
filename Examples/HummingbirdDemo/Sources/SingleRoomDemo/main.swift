import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo: Single-Room Architecture Example
///
/// This demo demonstrates the **single-room mode** using `LandServer.makeServer()`.
/// All connections connect to the same fixed land instance.
///
/// **Single-Room Mode Characteristics**:
/// - Fixed land instance (created at server startup)
/// - All clients connect to the same land
/// - Suitable for simple scenarios or testing
///
/// **For Multi-Room Mode**: See `MultiRoomDemo` which uses `LandServer.makeMultiRoomServer()`
/// or `LandRealm` to support dynamic room creation and multiple concurrent rooms.
@main
struct SingleRoomDemo {
    static func main() async throws {
        // JWT Configuration for demo/testing purposes
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger with custom log level
        // Available levels: .trace, .debug, .info, .notice, .warning, .error, .critical
        // Use .trace to see all action response payloads (as mentioned in TransportAdapter comments)
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "SingleRoomDemo",
            logLevel: .debug // Change to .info for less verbose, .debug for moderate detail
        )

        // Single-room mode: Create a fixed land instance
        // All connections will connect to this same land
        // Use LandHost for unified HTTP server and game logic management
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger
        ))
        
        // Register server - LandHost handles route registration automatically
        try await host.registerWithServer(
            landType: "cookie",
            land: HummingbirdDemoContent.CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: LandServerConfiguration(
                logger: logger, // Pass custom logger with desired log level
                jwtConfig: jwtConfig,
                allowGuestMode: true // Enable guest mode: allow connections without JWT token
            )
        )
        
        // Run unified server
        try await host.run()
    }
}
