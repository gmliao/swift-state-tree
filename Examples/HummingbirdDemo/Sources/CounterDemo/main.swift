import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeHummingbird

/// Hummingbird Demo: Counter Example
///
/// This is the simplest possible example demonstrating SwiftStateTree:
/// - A single counter state that broadcasts to all clients
/// - A single increment action
/// - Perfect for understanding the basics
@main
struct CounterDemo {
    static func main() async throws {
        typealias CounterLandServer = LandServer<CounterState>

        // JWT Configuration for demo/testing purposes
        let jwtConfig = HummingbirdDemoContent.createDemoJWTConfig()

        // Create logger
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "CounterDemo",
            logLevel: .info
        )

        // Single-room mode: Create a fixed land instance
        // Use LandHost for unified HTTP server management
        var host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger
        ))
        
        let server = try await CounterLandServer.makeServer(
            configuration: LandServer.Configuration(
                logStartupBanner: false, // LandHost will log startup info
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            ),
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            router: host.router // Use host's shared router
        )
        
        try host.register(
            landType: "counter",
            server: server,
            webSocketPath: "/game/counter"
        )
        
        // Run unified server
        try await host.run()
    }
}
