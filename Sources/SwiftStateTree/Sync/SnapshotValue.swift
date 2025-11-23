// Sources/SwiftStateTree/Sync/SnapshotValue.swift

import Foundation

/// Allowed data types for snapshots, used for JSON-friendly output structures.
public enum SnapshotValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SnapshotValue])
    case object([String: SnapshotValue])

    public var objectValue: [String: SnapshotValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [SnapshotValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case let .double(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

/// Protocol for types that can efficiently convert themselves to SnapshotValue
/// without using runtime reflection.
///
/// Types conforming to this protocol can provide their own conversion implementation,
/// which avoids the performance overhead of using Mirror for reflection.
///
/// **Recommended Usage**: Use `@SnapshotConvertible` macro to automatically generate
/// the protocol conformance implementation.
///
/// Example with macro (recommended):
/// ```swift
/// @SnapshotConvertible
/// struct PlayerState: Codable {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// // Macro automatically generates the protocol conformance
/// ```
///
/// Example with manual implementation:
/// ```swift
/// extension PlayerState: SnapshotValueConvertible {
///     func toSnapshotValue() throws -> SnapshotValue {
///         return .object([
///             "name": .string(name),
///             "hpCurrent": .int(hpCurrent),
///             "hpMax": .int(hpMax)
///         ])
///     }
/// }
/// ```
public protocol SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue
}

public extension SnapshotValue {
    static func make(from value: Any) throws -> SnapshotValue {
        // Priority 1: Check if type conforms to SnapshotValueConvertible (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()
        }
        
        // Priority 2: Handle basic types directly (no Mirror needed)
        if value is NSNull {
            return .null
        }
        switch value {
        case let boolValue as Bool:
            return .bool(boolValue)
        case let intValue as Int:
            return .int(intValue)
        case let int8Value as Int8:
            return .int(Int(int8Value))
        case let int16Value as Int16:
            return .int(Int(int16Value))
        case let int32Value as Int32:
            return .int(Int(int32Value))
        case let int64Value as Int64:
            return .int(Int(int64Value))
        case let uintValue as UInt:
            return .int(Int(uintValue))
        case let uint8Value as UInt8:
            return .int(Int(uint8Value))
        case let uint16Value as UInt16:
            return .int(Int(uint16Value))
        case let uint32Value as UInt32:
            return .int(Int(uint32Value))
        case let uint64Value as UInt64:
            return .int(Int(uint64Value))
        case let doubleValue as Double:
            return .double(doubleValue)
        case let floatValue as Float:
            return .double(Double(floatValue))
        case let stringValue as String:
            return .string(stringValue)
        case let playerID as PlayerID:
            return .string(playerID.rawValue)
        default:
            break
        }

        let mirror = Mirror(reflecting: value)

        if mirror.displayStyle == .optional {
            if let child = mirror.children.first {
                return try make(from: child.value)
            } else {
                return .null
            }
        }

        switch mirror.displayStyle {
        case .collection:
            let array = try mirror.children.map { try make(from: $0.value) }
            return .array(array)
        case .dictionary:
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                let pair = Mirror(reflecting: child.value)
                guard pair.children.count == 2 else {
                    throw SyncError.unsupportedValue("Dictionary entry must contain exactly two children.")
                }
                let keyMirror = pair.children.first!
                let valueMirror = pair.children.dropFirst().first!
                let keyString = try makeKeyString(from: keyMirror.value)
                let mappedValue = try make(from: valueMirror.value)
                object[keyString] = mappedValue
            }
            return .object(object)
        case .struct, .class:
            var object: [String: SnapshotValue] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                object[label] = try make(from: child.value)
            }
            return .object(object)
        default:
            throw SyncError.unsupportedValue("Unsupported type: \(type(of: value))")
        }
    }

    private static func makeKeyString(from value: Any) throws -> String {
        if let playerID = value as? PlayerID {
            return playerID.rawValue
        }
        if let stringKey = value as? String {
            return stringKey
        }
        if let convertible = value as? CustomStringConvertible {
            return convertible.description
        }
        throw SyncError.unsupportedKey("Unsupported dictionary key type: \(type(of: value))")
    }
}

