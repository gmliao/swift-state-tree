import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo: Multi-Room Architecture Example with Multiple Land Types
///
/// This demo demonstrates the **multi-room mode** with multiple land types on a single server
/// using `LandHost` to manage a unified HTTP server.
///
/// **Multi-Room Mode Characteristics**:
/// - Dynamic land/room creation (lands are created on-demand)
/// - Multiple concurrent lands/rooms can exist simultaneously
/// - Multiple land types with different State types on the same server
/// - Each land type has its own WebSocket path (e.g., `/game/cookie`, `/game/counter`)
/// - Uses `LandHost` to manage unified HTTP server and avoid port conflicts
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

        // Create LandRealmHost to manage both game logic and HTTP server
        // LandRealmHost combines LandRealm and LandHost functionality
        let realmHost = LandRealmHost(configuration: LandRealmHost.HostConfiguration(
            host: "localhost",
            port: port,
            logger: logger
        ))

        // Register Cookie Game server
        // Router is automatically used from realmHost
        try await realmHost.registerWithLandServer(
            landType: "cookie",
            landFactory: { _ in
                HummingbirdDemoContent.CookieGame.makeLand()
            },
            initialStateFactory: { _ in
                CookieGameState()
            },
            webSocketPath: "/game/cookie",
            configuration: LandServer<CookieGameState>.Configuration(
                host: "localhost",
                port: port,
                webSocketPath: "/game/cookie",
                logStartupBanner: false, // LandRealmHost will log startup info
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            ),
            allowAutoCreateOnJoin: true
        )

        // Register Counter Demo server
        try await realmHost.registerWithLandServer(
            landType: "counter",
            landFactory: { _ in
                HummingbirdDemoContent.CounterDemo.makeLand()
            },
            initialStateFactory: { _ in
                CounterState()
            },
            webSocketPath: "/game/counter",
            configuration: LandServer<CounterState>.Configuration(
                host: "localhost",
                port: port,
                webSocketPath: "/game/counter",
                logStartupBanner: false, // LandRealmHost will log startup info
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            ),
            allowAutoCreateOnJoin: true
        )

        logger.info("💡 Connect with different landIDs to create different rooms")
        logger.info("   Example: ws://localhost:\(port)/game/cookie?token=<jwt>&landID=cookie:room-123")
        
        // Run unified server
        try await realmHost.run()
    }
}
