import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo Server
///
/// A unified demo server that showcases SwiftStateTree capabilities:
/// - Multiple land types (cookie game and counter demo)
/// - Multi-room support with dynamic room creation
/// - Unified HTTP server and game logic management via LandHost
///
/// **Land Types**:
/// - `cookie`: Cookie Clicker game (CookieGameState) at `/game/cookie`
/// - `counter`: Simple counter demo (CounterState) at `/game/counter`
///
/// **Configuration**:
/// - Port: Set via `PORT` environment variable (default: 8080)
/// - Host: Set via `HOST` environment variable (default: "localhost")
/// - Guest mode: Enabled (allows connections without JWT)
/// - Auto-create rooms: Enabled (clients can create rooms dynamically)
/// - Admin routes: Enabled at `/admin/*` (API Key: `demo-admin-key`)
///
/// **Usage**:
/// ```bash
/// # Run with default settings (localhost:8080)
/// swift run DemoServer
///
/// # Run on custom port
/// PORT=3000 swift run DemoServer
///
/// # Run on custom host and port
/// HOST=0.0.0.0 PORT=3000 swift run DemoServer
/// ```
@main
struct DemoServer {
    static func main() async throws {
        // JWT Configuration for demo/testing purposes
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger with custom log level
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "DemoServer",
            logLevel: .debug
        )

        // Get configuration from environment variables
        let host = HummingbirdDemoContent.getEnvString(key: "HOST", defaultValue: "localhost")
        let port = HummingbirdDemoContent.getEnvUInt16(key: "PORT", defaultValue: 8080)

        // Create LandHost to manage both game logic and HTTP server
        let landHost = LandHost(configuration: LandHost.HostConfiguration(
            host: host,
            port: port,
            logger: logger
        ))

        // Shared server configuration for all land types
        // Enable parallel encoding for better performance with multiple players
        let serverConfig = LandServerConfiguration(
            logger: logger,
            jwtConfig: jwtConfig,
            allowGuestMode: true,
            allowAutoCreateOnJoin: true,
            enableParallelEncoding: true  // Enable parallel JSON encoding for state updates
        )

        // Register Cookie Game server
        try await landHost.register(
            landType: "cookie",
            land: HummingbirdDemoContent.CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: serverConfig
        )

        // Register Counter Demo server
        try await landHost.register(
            landType: "counter",
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            initialState: CounterState(),
            webSocketPath: "/game/counter",
            configuration: serverConfig
        )

        // Register admin routes for managing lands
        // Use API key for demo (in production, use JWT with adminRole)
        let adminAuth = AdminAuthMiddleware(
            jwtValidator: nil,  // Can use JWT validator if needed
            apiKey: "demo-admin-key"  // Demo API key (change in production!)
        )
        await landHost.registerAdminRoutes(
            adminAuth: adminAuth,
            logger: logger
        )
        logger.info("✅ Admin routes registered at /admin/* (API Key: demo-admin-key)")

        // Run unified server (LandHost will automatically print connection info)
        do {
            try await landHost.run()
        } catch let error as LandHostError {
            logger.error("❌ Server startup failed: \(error)", metadata: [
                "error": .string(String(describing: error))
            ])
            exit(1)
        }
    }
}
