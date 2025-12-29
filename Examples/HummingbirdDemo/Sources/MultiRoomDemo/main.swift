import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo: Multi-Room Architecture Example with Multiple Land Types
///
/// This demo demonstrates the **multi-room mode** with multiple land types on a single server
/// using `LandHost` to manage unified HTTP server and game logic.
///
/// **Multi-Room Mode Characteristics**:
/// - Dynamic land/room creation (lands are created on-demand)
/// - Multiple concurrent lands/rooms can exist simultaneously
/// - Multiple land types with different State types on the same server
/// - Each land type has its own WebSocket path (e.g., `/game/cookie`, `/game/counter`)
/// - Uses `LandHost` to manage unified HTTP server and game logic
/// - Suitable for production environments
///
/// **Land Types**:
/// - `cookie`: Cookie Clicker game (CookieGameState) at `/game/cookie`
/// - `counter`: Simple counter demo (CounterState) at `/game/counter`
@main
struct MultiRoomDemo {
    static func main() async throws {
        // JWT Configuration for demo/testing purposes
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger with custom log level
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "MultiRoomDemo",
            logLevel: .debug
        )

        // Get port from environment variable, default to 8080
        let port = HummingbirdDemoContent.getEnvUInt16(key: "PORT", defaultValue: 8080)

        // Create LandHost to manage both game logic and HTTP server
        // LandHost combines LandRealm and HTTP server management
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
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
        // Router is automatically used from host
        try await host.register(
            landType: "cookie",
            land: HummingbirdDemoContent.CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: serverConfig
        )

        // Register Counter Demo server
        try await host.register(
            landType: "counter",
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            initialState: CounterState(),
            webSocketPath: "/game/counter",
            configuration: serverConfig
        )

        // Run unified server (LandHost will automatically print connection info)
        try await host.run()
    }
}
