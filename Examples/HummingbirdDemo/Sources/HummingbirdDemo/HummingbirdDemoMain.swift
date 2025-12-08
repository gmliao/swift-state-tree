import Foundation
import HummingbirdDemoContent
import SwiftStateTreeHummingbird
import SwiftStateTree

@main
struct HummingbirdDemo {
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
        
        let container = try await DemoAppContainer.makeServer(
            configuration: AppContainer.Configuration(
                jwtConfig: jwtConfig,
                allowGuestMode: true  // Enable guest mode: allow connections without JWT token
            ),
            land: DemoGame.makeLand(),
            initialState: DemoGameState(),
            createGuestSession: { sessionID, clientID in
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
                        "clientID": clientID.rawValue
                    ]
                )
            }
        )
        try await container.run()
    }
}
