// Sources/SwiftStateTreeTransport/DecimalScan.swift
import Foundation
import SwiftStateTree

/// Refuses a `Decimal` before a JSON encoding writes one (#597, #557).
///
/// `JSONEncoder` writes a `Decimal` as a JSON number, and a Decimal NaN as a bare `NaN`, which
/// isn't JSON. It handles `Decimal` inside itself, before any hook, so the check is a separate
/// walk: an encoder that writes nothing and throws at the first `Decimal`, or an
/// `NSDecimalNumber` in an `AnyCodable`. The macros and registration refuse the `Decimal`
/// fields they can see; this catches the rest at the first send: an event emitted without
/// registration, an `AnyCodable` filled at runtime, and a `Decimal` nested in a plain `Codable`
/// type. The MessagePack encoders refuse a `Decimal` themselves.
///
/// Cost: one extra `Codable` walk of each JSON message, with no output. State updates don't
/// go through it: they encode `SnapshotValue` trees, which can't hold a `Decimal`.
enum DecimalScan {
    /// Throws `EncodingError.invalidValue` at the first `Decimal` in `value`, naming its path.
    static func check<T: Encodable>(_ value: T) throws {
        try ScanEncoder(codingPath: []).scan(value)
    }

    static func refusal(_ value: Any, at codingPath: [CodingKey]) -> EncodingError {
        EncodingError.invalidValue(value, EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "a Decimal has no wire form (#597); store an integer of the smallest unit or a String"
        ))
    }

    private static let primitiveTypes: Set<ObjectIdentifier> = [
        ObjectIdentifier(Bool.self), ObjectIdentifier(String.self),
        ObjectIdentifier(Double.self), ObjectIdentifier(Float.self),
        ObjectIdentifier(Int.self), ObjectIdentifier(Int8.self), ObjectIdentifier(Int16.self),
        ObjectIdentifier(Int32.self), ObjectIdentifier(Int64.self),
        ObjectIdentifier(UInt.self), ObjectIdentifier(UInt8.self), ObjectIdentifier(UInt16.self),
        ObjectIdentifier(UInt32.self), ObjectIdentifier(UInt64.self),
    ]

    private struct ScanEncoder: Encoder {
        let codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func scan<T: Encodable>(_ value: T) throws {
            // A primitive's `encode(to:)` encodes itself into a single-value container, which
            // would come back here: it holds no Decimal, so stop.
            if DecimalScan.primitiveTypes.contains(ObjectIdentifier(T.self)) { return }
            if T.self == Decimal.self { throw refusal(value, at: codingPath) }
            if let any = value as? AnyCodable, type(of: any.base) is NSDecimalNumber.Type {
                throw refusal(any.base, at: codingPath)
            }
            try value.encode(to: self)
        }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            KeyedEncodingContainer(Keyed<Key>(codingPath: codingPath))
        }
        func unkeyedContainer() -> UnkeyedEncodingContainer { Unkeyed(codingPath: codingPath) }
        func singleValueContainer() -> SingleValueEncodingContainer { Single(codingPath: codingPath) }
    }

    private struct Index: CodingKey {
        let intValue: Int?
        var stringValue: String { "\(intValue ?? 0)" }
        init(_ index: Int) { intValue = index }
        init?(stringValue: String) { return nil }
        init?(intValue: Int) { self.intValue = intValue }
    }

    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let codingPath: [CodingKey]
        mutating func encodeNil(forKey key: Key) throws {}
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try ScanEncoder(codingPath: codingPath + [key]).scan(value)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(codingPath: codingPath + [key]))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            Unkeyed(codingPath: codingPath + [key])
        }
        mutating func superEncoder() -> Encoder { ScanEncoder(codingPath: codingPath) }
        mutating func superEncoder(forKey key: Key) -> Encoder { ScanEncoder(codingPath: codingPath + [key]) }
    }

    private struct Unkeyed: UnkeyedEncodingContainer {
        let codingPath: [CodingKey]
        private(set) var count = 0
        init(codingPath: [CodingKey]) { self.codingPath = codingPath }
        mutating func encodeNil() throws { count += 1 }
        mutating func encode<T: Encodable>(_ value: T) throws {
            defer { count += 1 }
            try ScanEncoder(codingPath: codingPath + [Index(count)]).scan(value)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            defer { count += 1 }
            return KeyedEncodingContainer(Keyed<NestedKey>(codingPath: codingPath + [Index(count)]))
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            defer { count += 1 }
            return Unkeyed(codingPath: codingPath + [Index(count)])
        }
        mutating func superEncoder() -> Encoder { ScanEncoder(codingPath: codingPath) }
    }

    private struct Single: SingleValueEncodingContainer {
        let codingPath: [CodingKey]
        mutating func encodeNil() throws {}
        mutating func encode<T: Encodable>(_ value: T) throws {
            try ScanEncoder(codingPath: codingPath).scan(value)
        }
    }
}
