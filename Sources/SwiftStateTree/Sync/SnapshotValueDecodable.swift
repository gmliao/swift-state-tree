// SnapshotValueDecodable.swift
// Reverse-decode protocol for SnapshotValue → Swift types.
// Used by @StateNodeBuilder-generated init(fromBroadcastSnapshot:).

import Foundation

// MARK: - Errors

public enum SnapshotDecodeError: Error, Sendable {
    case typeMismatch(expected: String, got: SnapshotValue)
    case missingKey(String)
    case invalidKeyString(String, targetType: String)
}

// MARK: - SnapshotKeyDecodable

public protocol SnapshotKeyDecodable: Hashable {
    init?(snapshotKey: String)
}

extension String: SnapshotKeyDecodable {
    public init?(snapshotKey: String) { self = snapshotKey }
}

extension Int: SnapshotKeyDecodable {
    public init?(snapshotKey: String) {
        guard let v = Int(snapshotKey) else { return nil }
        self = v
    }
}

extension PlayerID: SnapshotKeyDecodable {
    public init?(snapshotKey: String) { self.init(snapshotKey) }
}

// MARK: - SnapshotValueDecodable

public protocol SnapshotValueDecodable {
    init(fromSnapshotValue value: SnapshotValue) throws
}

// MARK: - Primitive Conformances

extension Int: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .int(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Int (.int)", got: value)
        }
        self = v
    }
}

extension Bool: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .bool(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Bool (.bool)", got: value)
        }
        self = v
    }
}

extension String: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .string(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "String (.string)", got: value)
        }
        self = v
    }
}

extension Double: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .double(let v) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Double (.double)", got: value)
        }
        self = v
    }
}

// MARK: - Collection Conformances

extension Optional: SnapshotValueDecodable where Wrapped: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        if case .null = value {
            self = .none
        } else {
            self = .some(try Wrapped(fromSnapshotValue: value))
        }
    }
}

extension Array: SnapshotValueDecodable where Element: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .array(let arr) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Array (.array)", got: value)
        }
        self = try arr.map { try Element(fromSnapshotValue: $0) }
    }
}

extension Dictionary: SnapshotValueDecodable
    where Key: SnapshotKeyDecodable, Value: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "Dictionary (.object)", got: value)
        }
        self = try Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in
            guard let key = Key(snapshotKey: k) else { return nil }
            let val = try Value(fromSnapshotValue: v)
            return (key, val)
        })
    }
}

// MARK: - Codable Bridge Helper

public extension SnapshotValue {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Generic Helper (used by macro-generated init(fromBroadcastSnapshot:))

@inline(__always)
public func _snapshotDecode<T: SnapshotValueDecodable>(_ value: SnapshotValue) throws -> T {
    return try T(fromSnapshotValue: value)
}
