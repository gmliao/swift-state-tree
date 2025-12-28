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
        let server = try await CounterLandServer.makeServer(
            configuration: LandServer.Configuration(
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            ),
            land: HummingbirdDemoContent.CounterDemo.makeLand()
        )
        try await server.run()
    }
}
