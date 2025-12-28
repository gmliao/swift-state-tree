import Foundation
import Logging
import SwiftStateTree
import SwiftStateTreeHummingbird

// MARK: - Demo Helper Functions

/// Create a logger for demo applications with consistent configuration.
///
/// This helper provides a standardized way to create loggers for all demo applications,
/// using the same logger identifier and allowing customization of scope and log level.
///
/// - Parameters:
///   - scope: The scope/context name for the logger (e.g., "CounterDemo", "SingleRoomDemo")
///   - logLevel: The minimum log level to output (default: `.info`)
/// - Returns: A configured Logger instance
public func createDemoLogger(
    scope: String,
    logLevel: Logger.Level = .info
) -> Logger {
    return createColoredLogger(
        loggerIdentifier: "com.swiftstatetree.hummingbird",
        scope: scope,
        logLevel: logLevel
    )
}

/// Create a JWT configuration for demo/testing purposes.
///
/// This helper provides a standardized JWT configuration for all demo applications.
/// ⚠️ WARNING: This uses a demo secret key. CHANGE THIS IN PRODUCTION!
///
/// In production, use environment variables or secure key management:
/// ```bash
/// export JWT_SECRET_KEY="your-secure-secret-key-here"
/// ```
///
/// - Returns: A JWTConfiguration instance suitable for demo/testing
public func createDemoJWTConfig() -> JWTConfiguration {
    return JWTConfiguration(
        secretKey: "demo-secret-key-change-in-production",
        algorithm: .HS256,
        validateExpiration: true
    )
}
