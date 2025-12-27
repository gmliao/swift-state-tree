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
        typealias CounterAppContainer = AppContainer<CounterState>

        // JWT Configuration for demo/testing purposes
        let demoJWTSecretKey = "demo-secret-key-change-in-production"
        let jwtConfig = JWTConfiguration(
            secretKey: demoJWTSecretKey,
            algorithm: .HS256,
            validateExpiration: true
        )

        // Create logger
        let logger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "CounterDemo",
            logLevel: .info
        )

        // Single-room mode: Create a fixed land instance
        let container = try await CounterAppContainer.makeServer(
            configuration: AppContainer.Configuration(
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true
            ),
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            initialState: CounterState(),
            createGuestSession: { _, clientID in
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
