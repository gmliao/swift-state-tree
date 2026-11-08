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

/// ServerLoadTest's join for player `playerIndexInRoom` of room `roomIndex`. It declares every
/// state-update feature this build decodes (`StateUpdateFeature.joinMetadata`): a server
/// refuses a join that lacks one it has on.
public func makeLoadTestJoinMessage(landType: String, roomIndex: Int, playerIndexInRoom: Int) -> TransportMessage {
    TransportMessage(
        kind: .join,
        payload: .join(TransportJoinPayload(
            requestID: "join-\(roomIndex)-\(playerIndexInRoom)",
            landType: landType,
            landInstanceId: "room-\(roomIndex)",
            playerID: "p-\(roomIndex)-\(playerIndexInRoom)",
            deviceID: nil,
            metadata: StateUpdateFeature.joinMetadata
        ))
    )
}

/// The state-update features a join was given (`joinResponse.stateUpdateFeatures`, e.g. the path
/// index and field merge): the run's wire form. Joins by feature set; a run whose joins disagree
/// mixes forms and fails.
public struct JoinFeatureTally: Sendable, Equatable {
    /// Joins per feature set, keyed by the sorted names joined with "," ("" for none).
    public private(set) var joins: [String: Int] = [:]

    public init() {}

    /// A successful join's features; a response without the list gave none.
    public mutating func record(_ features: [String]?) {
        joins[Set(features ?? []).sorted().joined(separator: ","), default: 0] += 1
    }

    /// The one feature set every join was given; nil without joins or when they disagree.
    public var agreed: [String]? {
        guard joins.count == 1, let key = joins.keys.first else { return nil }
        return key.isEmpty ? [] : key.split(separator: ",").map(String.init)
    }

    /// Why the run fails, or nil when the joins agree (or there were none).
    public var failure: String? {
        guard joins.count > 1 else { return nil }
        let shown = joins.keys.sorted().map { "[\($0)]×\(joins[$0]!)" }.joined(separator: ", ")
        return "joins disagree on stateUpdateFeatures: \(shown)"
    }
}

/// The `stateUpdateFeatures` of a successful joinResponse frame, in either form ServerLoadTest
/// can receive (a `{kind, payload}` object, or the opcode array `[105, requestID, 1, …, features]`);
/// nil when the frame isn't a successful joinResponse.
public func successfulJoinFeatures(_ json: Any) -> [String]?? {
    if let dict = json as? [String: Any], dict["kind"] as? String == "joinResponse",
       let payload = dict["payload"] as? [String: Any], let join = payload["joinResponse"] as? [String: Any] {
        let ok = (join["success"] as? Bool) == true || (join["success"] as? Int) == 1
        return ok ? .some(join["stateUpdateFeatures"] as? [String]) : nil
    }
    if let array = json as? [Any], array.count >= 3, array[0] as? Int == 105 {
        let ok = (array[2] as? Int) == 1 || (array[2] as? Bool) == true
        return ok ? .some(array.count > 8 ? array[8] as? [String] : nil) : nil
    }
    return nil
}

/// Why a ServerLoadTest run measured less load than it targets, or nil when every player joined.
/// A refused join (for example a state-update feature the server requires and the join lacks)
/// leaves the player out, and a run without its players must not pass as a measurement.
public func loadTestJoinFailure(peakJoinedPlayers: Int, expectedPlayers: Int) -> String? {
    guard peakJoinedPlayers < expectedPlayers else { return nil }
    return "only \(peakJoinedPlayers) of \(expectedPlayers) players joined"
}
