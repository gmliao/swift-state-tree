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
        let serverConfig = LandServerConfiguration(
            logger: logger,
            jwtConfig: jwtConfig,
            allowGuestMode: true,
            allowAutoCreateOnJoin: true
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

        // Run unified server (LandHost will automatically print connection info)
        try await landHost.run()
    }
}
