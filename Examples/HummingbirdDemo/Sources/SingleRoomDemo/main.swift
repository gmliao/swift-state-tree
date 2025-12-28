import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird

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
        typealias DemoSingleRoomServer = LandServer<CookieGameState>

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
        let server = try await DemoSingleRoomServer.makeServer(
            configuration: LandServer.Configuration(
                logger: logger, // Pass custom logger with desired log level
                jwtConfig: jwtConfig,
                allowGuestMode: true // Enable guest mode: allow connections without JWT token
            ),
            land: HummingbirdDemoContent.CookieGame.makeLand()
        )
        try await server.run()
    }
}
