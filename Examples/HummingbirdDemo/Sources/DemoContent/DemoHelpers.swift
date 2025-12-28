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

// MARK: - Environment Variable Helpers

/// Get a UInt16 value from environment variable with validation and default fallback.
///
/// This helper safely reads a UInt16 value from environment variables,
/// validating the value is within the valid range (0 to UInt16.max).
///
/// - Parameters:
///   - key: The environment variable key (e.g., "PORT")
///   - defaultValue: The default value to return if the environment variable is not set or invalid
/// - Returns: The parsed UInt16 value, or the default value if parsing fails
///
/// Example:
/// ```swift
/// let port = getEnvUInt16(key: "PORT", defaultValue: 8080)
/// ```
public func getEnvUInt16(key: String, defaultValue: UInt16) -> UInt16 {
    guard
        let raw = ProcessInfo.processInfo.environment[key],
        let value = Int(raw),
        value >= 0,
        value <= Int(UInt16.max)
    else {
        return defaultValue
    }
    return UInt16(value)
}

/// Get a String value from environment variable with default fallback.
///
/// - Parameters:
///   - key: The environment variable key
///   - defaultValue: The default value to return if the environment variable is not set
/// - Returns: The environment variable value, or the default value if not set
///
/// Example:
/// ```swift
/// let host = getEnvString(key: "HOST", defaultValue: "localhost")
/// ```
public func getEnvString(key: String, defaultValue: String) -> String {
    return ProcessInfo.processInfo.environment[key] ?? defaultValue
}

/// Get an optional String value from environment variable.
///
/// - Parameter key: The environment variable key
/// - Returns: The environment variable value if set, nil otherwise
///
/// Example:
/// ```swift
/// if let apiKey = getEnvStringOptional(key: "API_KEY") {
///     // Use API key
/// }
/// ```
public func getEnvStringOptional(key: String) -> String? {
    let value = ProcessInfo.processInfo.environment[key]
    return value?.isEmpty == false ? value : nil
}
