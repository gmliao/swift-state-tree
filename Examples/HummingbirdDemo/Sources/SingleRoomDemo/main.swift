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
        typealias DemoAppContainer = AppContainer<DemoGameState>

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
        // Available levels: .trace, .debug, .info, .notice, .warning, .error, .critical
        // Use .trace to see all action response payloads (as mentioned in TransportAdapter comments)
        let logger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "SingleRoomDemo",
            logLevel: .debug // Change to .info for less verbose, .debug for moderate detail
        )

        // Single-room mode: Create a fixed land instance
        // All connections will connect to this same land
        let container = try await DemoAppContainer.makeServer(
            configuration: AppContainer.Configuration(
                logger: logger, // Pass custom logger with desired log level
                jwtConfig: jwtConfig,
                allowGuestMode: true // Enable guest mode: allow connections without JWT token
            ),
            land: HummingbirdDemoContent.DemoGame.makeLand(),
            initialState: DemoGameState(),
            createGuestSession: { _, clientID in
                // Create PlayerSession for guest users (when JWT validation is enabled but no token is provided)
                // This is only used when allowGuestMode is true and the client connects without a JWT token
                //
                // PlayerSession creation priority:
                // 1. Join message fields (if provided in join request)
                // 2. JWT payload fields (from AuthenticatedInfo) - for authenticated users
                // 3. This closure (for guest users)
                //
                // Guest users get a "guest-{randomID}" playerID format
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
        try await container.run()
    }
}
