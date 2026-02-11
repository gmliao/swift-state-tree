import Foundation
import Logging
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - Game Helper Functions

/// Whether to use ANSI color codes in log output, from environment.
///
/// Disables colors when:
/// - `NO_COLOR` is set (any value; see https://no-color.org/)
/// - `LOG_USE_COLORS` is 0, false, no, or off
///
/// Use this when logging to a file or in CI so logs stay plain text.
public func getEnvUseColors(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    EnvHelpers.getEnvUseColors(environment: environment)
}

/// Create a logger for game demo applications with consistent configuration.
///
/// This helper provides a standardized way to create loggers for game demo applications,
/// using the same logger identifier and allowing customization of scope and log level.
/// When output is redirected to a file (e.g. load tests), set `NO_COLOR=1` or
/// `LOG_USE_COLORS=0` so logs are plain text without ANSI control codes.
///
/// - Parameters:
///   - scope: The scope/context name for the logger (e.g., "GameServer", "GameDemo")
///   - logLevel: The minimum log level to output (default: `.info`)
///   - useColors: When nil, derived from env (NO_COLOR / LOG_USE_COLORS); otherwise use this value.
/// - Returns: A configured Logger instance
public func createGameLogger(
    scope: String,
    logLevel: Logger.Level = .info,
    useColors: Bool? = nil
) -> Logger {
    let colors = useColors ?? getEnvUseColors()
    return createColoredLogger(
        loggerIdentifier: "com.swiftstatetree.gamedemo",
        scope: scope,
        logLevel: logLevel,
        useColors: colors
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
    EnvHelpers.getEnvUInt16(key: key, defaultValue: defaultValue)
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
    EnvHelpers.getEnvString(key: key, defaultValue: defaultValue)
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
    EnvHelpers.getEnvStringOptional(key: key)
}

/// Get a Logger.Level value from environment variable with default fallback.
///
/// Accepted values (case-insensitive): trace, debug, info, notice, warning, error, critical.
/// Any other value falls back to the default.
///
/// - Parameters:
///   - key: The environment variable key (e.g. "LOG_LEVEL")
///   - defaultValue: The default level if not set or invalid
///   - environment: The environment dictionary to read from (defaults to process environment)
/// - Returns: Parsed Logger.Level or default value
public func getEnvLogLevel(
    key: String,
    defaultValue: Logger.Level = .info,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Logger.Level {
    guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
        return defaultValue
    }
    switch raw {
    case "trace": return .trace
    case "debug": return .debug
    case "info": return .info
    case "notice": return .notice
    case "warning": return .warning
    case "error": return .error
    case "critical": return .critical
    default: return defaultValue
    }
}

/// Get a Bool value from environment variable with default fallback.
///
/// Accepted truthy values: "1", "true", "yes", "y", "on"
/// Accepted falsy values: "0", "false", "no", "n", "off"
/// Any other value falls back to the default.
///
/// - Parameters:
///   - key: The environment variable key
///   - defaultValue: The default value to return if the environment variable is not set or invalid
///   - environment: The environment dictionary to read from (defaults to process environment)
/// - Returns: Parsed Bool or default value
public func getEnvBool(
    key: String,
    defaultValue: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    EnvHelpers.getEnvBool(key: key, defaultValue: defaultValue, environment: environment)
}

// MARK: - Transport Encoding Helpers

/// Resolve transport encoding from environment variable string.
///
/// This helper provides a flexible way to parse transport encoding values,
/// accepting multiple formats for better compatibility:
/// - `jsonOpcode`, `json_opcode`, `json-opcode` → `.jsonOpcode`
/// - `messagepack`, `msgpack` → `.messagepack`
/// - `json` → `.json`
/// - `opcode` → `.opcode`
///
/// - Parameter rawValue: The raw string value from environment variable
/// - Returns: A TransportEncodingConfig instance, defaults to `.json` if invalid
///
/// Example:
/// ```swift
/// let encoding = resolveTransportEncoding(rawValue: "jsonOpcode")
/// ```
public func resolveTransportEncoding(rawValue: String) -> TransportEncodingConfig {
    switch rawValue.lowercased() {
    case "json":
        return .json
    case "jsonopcode", "json_opcode", "json-opcode":
        return .jsonOpcode
    case "opcode":
        return .opcode
    case "messagepack", "msgpack":
        return .messagepack
    default:
        // Default to json for backward compatibility
        return .json
    }
}
