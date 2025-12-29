import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hummingbird Demo: Counter Example
///
/// This is the simplest possible example demonstrating SwiftStateTree:
/// - A single counter state that broadcasts to all clients
/// - A single increment action
/// - Perfect for understanding the basics
@main
struct CounterDemo {
    static func main() async throws {
        // JWT Configuration for demo/testing purposes
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "CounterDemo",
            logLevel: .info
        )

        // Single-room mode: Create a fixed land instance
        // Use LandHost for unified HTTP server and game logic management
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger
        ))
        
        // Register server - LandHost handles route registration automatically
        try await host.registerWithServer(
            landType: "counter",
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            initialState: CounterState(),
            webSocketPath: "/game/counter",
            configuration: LandServerConfiguration(
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            )
        )
        
        // Run unified server
        try await host.run()
    }
}
