// Sources/SwiftStateTree/Sync/Sync.swift

import Foundation

/// 玩家識別符（帳號層級）
public struct PlayerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// 表示一個欄位的同步策略。
public enum SyncPolicy<Value: Sendable>: Sendable {
    case serverOnly
    case broadcast
    case perPlayer(@Sendable (Value, PlayerID) -> Any?)
    case masked(@Sendable (Value) -> Any)
    case custom(@Sendable (PlayerID, Value) -> Any?)

    func filteredValue(_ value: Value, for playerID: PlayerID) -> Any? {
        switch self {
        case .serverOnly:
            return nil
        case .broadcast:
            return value
        case let .perPlayer(filter):
            return filter(value, playerID)
        case let .masked(mask):
            return mask(value)
        case let .custom(handler):
            return handler(playerID, value)
        }
    }
}

public extension SyncPolicy {
    /// 方便處理以 PlayerID 為 key 的 dictionary，只同步該玩家的值。
    static func perPlayerDictionaryValue<Element>() -> SyncPolicy<[PlayerID: Element]> {
        .perPlayer { value, playerID in
            value[playerID]
        }
    }
}

/// 標示 StateTree 欄位的同步策略。
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    public let policy: SyncPolicy<Value>
    public var wrappedValue: Value

    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) {
        self.policy = policy
        self.wrappedValue = wrappedValue
    }
}

/// 型別抹除後的同步值存取。
private protocol SyncValueProvider {
    func syncValue(for playerID: PlayerID) -> Any?
}

extension Sync: SyncValueProvider {
    fileprivate func syncValue(for playerID: PlayerID) -> Any? {
        policy.filteredValue(wrappedValue, for: playerID)
    }
}

/// Snapshot 允許的資料形態，用於輸出 JSON 友善的結構。
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

public enum SyncError: Error, Equatable {
    case unsupportedValue(String)
    case unsupportedKey(String)
}

public extension SnapshotValue {
    static func make(from value: Any) throws -> SnapshotValue {
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

/// 裁切後的狀態快照（JSON 友善結構）。
public struct StateSnapshot: Equatable, Sendable {
    public let values: [String: SnapshotValue]

    public init(values: [String: SnapshotValue]) {
        self.values = values
    }

    public subscript(_ key: String) -> SnapshotValue? {
        values[key]
    }

    public var isEmpty: Bool {
        values.isEmpty
    }
}

/// SyncEngine 會根據 SyncPolicy 裁切 StateTree 並輸出 StateSnapshot。
public struct SyncEngine: Sendable {
    public init() {}

    public func snapshot<State>(
        for playerID: PlayerID,
        from state: State
    ) throws -> StateSnapshot {
        let mirror = Mirror(reflecting: state)
        var result: [String: SnapshotValue] = [:]

        for child in mirror.children {
            guard let label = child.label else { continue }
            guard let provider = child.value as? SyncValueProvider else { continue }
            let normalizedLabel = label.hasPrefix("_") ? String(label.dropFirst()) : label
            guard let rawValue = provider.syncValue(for: playerID) else { continue }
            let mappedValue = try SnapshotValue.make(from: rawValue)
            result[normalizedLabel] = mappedValue
        }

        return StateSnapshot(values: result)
    }
}
