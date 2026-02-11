// Sources/SwiftStateTree/Support/EnvHelpers.swift
//
// Shared environment variable parsing helpers for consistent behavior across
// SwiftStateTree modules and Examples. Use these instead of ad-hoc
// ProcessInfo.processInfo.environment reads.

import Foundation

/// Shared environment variable helpers with consistent parsing rules.
///
/// **Boolean parsing**: truthy = "1", "true", "yes", "y", "on";
/// falsy = "0", "false", "no", "n", "off". Any other value uses default.
///
/// **Use from**: SwiftStateTree (no deps), SwiftStateTreeTransport, SwiftStateTreeNIO,
/// Examples (GameHelpers, DemoHelpers).
public enum EnvHelpers: Sendable {

    /// Get a String value with default fallback.
    public static func getEnvString(
        key: String,
        defaultValue: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        environment[key] ?? defaultValue
    }

    /// Get an optional String (nil if unset or empty).
    public static func getEnvStringOptional(
        key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let value = environment[key]
        return value?.isEmpty == false ? value : nil
    }

    /// Parse bool with consistent rules.
    /// Truthy: "1", "true", "yes", "y", "on". Falsy: "0", "false", "no", "n", "off".
    public static func getEnvBool(
        key: String,
        defaultValue: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return defaultValue
        }
    }

    /// Parse Int with default. Invalid or missing uses default.
    public static func getEnvInt(
        key: String,
        defaultValue: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[key], let value = Int(raw) else {
            return defaultValue
        }
        return value
    }

    /// Parse Double with default and optional clamp. Invalid or missing uses default.
    public static func getEnvDouble(
        key: String,
        defaultValue: Double,
        min: Double? = nil,
        max: Double? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let raw = environment[key], let value = Double(raw) else {
            return defaultValue
        }
        var result = value
        if let min { result = Swift.max(result, min) }
        if let max { result = Swift.min(result, max) }
        return result
    }

    /// Parse UInt16 with validation. Invalid or out-of-range uses default.
    public static func getEnvUInt16(
        key: String,
        defaultValue: UInt16,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt16 {
        guard
            let raw = environment[key],
            let value = Int(raw),
            value >= 0,
            value <= Int(UInt16.max)
        else {
            return defaultValue
        }
        return UInt16(value)
    }

    /// Check if "false", "0", "no", "off" (for env vars that default to true when unset).
    /// Use when the semantic is "opt-out" (e.g. USE_SNAPSHOT_FOR_SYNC != "false" means enabled).
    public static func isExplicitlyDisabled(
        key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        switch raw {
        case "0", "false", "no", "off":
            return true
        default:
            return false
        }
    }

    /// Whether to use ANSI colors in log output.
    /// Disables when NO_COLOR is set (https://no-color.org/) or LOG_USE_COLORS is falsy.
    public static func getEnvUseColors(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[EnvKeys.Logging.noColor] != nil {
            return false
        }
        return getEnvBool(key: EnvKeys.Logging.useColors, defaultValue: true, environment: environment)
    }
}
