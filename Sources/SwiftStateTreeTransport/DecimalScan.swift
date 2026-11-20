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
/// Limit: a hand-written `encode(to:)` that catches this error and falls back to another form
/// passes the scan, and the real encode then writes what the fallback writes.
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

    /// Types that hold no `Decimal` and end the walk. A scalar's `encode(to:)` encodes itself
    /// into a single-value container, which would come back here; `Data` would be walked byte
    /// by byte, where the real encoder writes it in one step.
    private static let primitiveTypes: Set<ObjectIdentifier> = {
        var types: Set<ObjectIdentifier> = [
            ObjectIdentifier(Bool.self), ObjectIdentifier(String.self),
            ObjectIdentifier(Double.self), ObjectIdentifier(Float.self),
            ObjectIdentifier(Int.self), ObjectIdentifier(Int8.self), ObjectIdentifier(Int16.self),
            ObjectIdentifier(Int32.self), ObjectIdentifier(Int64.self),
            ObjectIdentifier(UInt.self), ObjectIdentifier(UInt8.self), ObjectIdentifier(UInt16.self),
            ObjectIdentifier(UInt32.self), ObjectIdentifier(UInt64.self),
            ObjectIdentifier(Data.self),
        ]
        if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
            types.insert(ObjectIdentifier(Int128.self))
            types.insert(ObjectIdentifier(UInt128.self))
        }
        return types
    }()

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
            KeyedEncodingContainer(Keyed<Key>(codingPath: codingPath, encoderPath: codingPath))
        }
        func unkeyedContainer() -> UnkeyedEncodingContainer { Unkeyed(codingPath: codingPath, encoderPath: codingPath) }
        func singleValueContainer() -> SingleValueEncodingContainer { Single(codingPath: codingPath) }
    }

    private struct Index: CodingKey {
        let intValue: Int?
        // As Foundation's encoders spell it, so a path-dependent `encode(to:)` branches alike.
        var stringValue: String { "Index \(intValue ?? 0)" }
        init(_ index: Int) { intValue = index }
        init?(stringValue: String) { return nil }
        init?(intValue: Int) { self.intValue = intValue }
    }

    /// The key Foundation's keyed containers give `superEncoder()`.
    private struct SuperKey: CodingKey {
        var stringValue: String { "super" }
        var intValue: Int? { nil }
        init() {}
        init?(stringValue: String) { return nil }
        init?(intValue: Int) { return nil }
    }

    // `encoderPath` is the path of the encoder that made the container, nested or not:
    // Foundation's `superEncoder()` builds its path from it, not from a nested container's own
    // path, and the scan gives an `encode(to:)` the same paths.
    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let codingPath: [CodingKey]
        let encoderPath: [CodingKey]
        mutating func encodeNil(forKey key: Key) throws {}
        // The scalars hold no Decimal (as Foundation's containers, a concrete overload each).
        mutating func encode(_ value: Bool, forKey key: Key) throws {}
        mutating func encode(_ value: String, forKey key: Key) throws {}
        mutating func encode(_ value: Double, forKey key: Key) throws {}
        mutating func encode(_ value: Float, forKey key: Key) throws {}
        mutating func encode(_ value: Int, forKey key: Key) throws {}
        mutating func encode(_ value: Int8, forKey key: Key) throws {}
        mutating func encode(_ value: Int16, forKey key: Key) throws {}
        mutating func encode(_ value: Int32, forKey key: Key) throws {}
        mutating func encode(_ value: Int64, forKey key: Key) throws {}
        mutating func encode(_ value: UInt, forKey key: Key) throws {}
        mutating func encode(_ value: UInt8, forKey key: Key) throws {}
        mutating func encode(_ value: UInt16, forKey key: Key) throws {}
        mutating func encode(_ value: UInt32, forKey key: Key) throws {}
        mutating func encode(_ value: UInt64, forKey key: Key) throws {}
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: Int128, forKey key: Key) throws {}
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: UInt128, forKey key: Key) throws {}
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try ScanEncoder(codingPath: codingPath + [key]).scan(value)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(codingPath: codingPath + [key], encoderPath: encoderPath))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            Unkeyed(codingPath: codingPath + [key], encoderPath: encoderPath)
        }
        mutating func superEncoder() -> Encoder { ScanEncoder(codingPath: encoderPath + [SuperKey()]) }
        mutating func superEncoder(forKey key: Key) -> Encoder { ScanEncoder(codingPath: encoderPath + [key]) }
    }

    private struct Unkeyed: UnkeyedEncodingContainer {
        let codingPath: [CodingKey]
        let encoderPath: [CodingKey]
        private(set) var count = 0
        init(codingPath: [CodingKey], encoderPath: [CodingKey]) {
            self.codingPath = codingPath
            self.encoderPath = encoderPath
        }
        mutating func encodeNil() throws { count += 1 }
        mutating func encode(_ value: Bool) throws { count += 1 }
        mutating func encode(_ value: String) throws { count += 1 }
        mutating func encode(_ value: Double) throws { count += 1 }
        mutating func encode(_ value: Float) throws { count += 1 }
        mutating func encode(_ value: Int) throws { count += 1 }
        mutating func encode(_ value: Int8) throws { count += 1 }
        mutating func encode(_ value: Int16) throws { count += 1 }
        mutating func encode(_ value: Int32) throws { count += 1 }
        mutating func encode(_ value: Int64) throws { count += 1 }
        mutating func encode(_ value: UInt) throws { count += 1 }
        mutating func encode(_ value: UInt8) throws { count += 1 }
        mutating func encode(_ value: UInt16) throws { count += 1 }
        mutating func encode(_ value: UInt32) throws { count += 1 }
        mutating func encode(_ value: UInt64) throws { count += 1 }
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: Int128) throws { count += 1 }
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: UInt128) throws { count += 1 }
        mutating func encode<T: Encodable>(_ value: T) throws {
            defer { count += 1 }
            try ScanEncoder(codingPath: codingPath + [Index(count)]).scan(value)
        }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            defer { count += 1 }
            return KeyedEncodingContainer(Keyed<NestedKey>(codingPath: codingPath + [Index(count)], encoderPath: encoderPath))
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            defer { count += 1 }
            return Unkeyed(codingPath: codingPath + [Index(count)], encoderPath: encoderPath)
        }
        mutating func superEncoder() -> Encoder {
            defer { count += 1 }
            return ScanEncoder(codingPath: encoderPath + [Index(count)])
        }
    }

    private struct Single: SingleValueEncodingContainer {
        let codingPath: [CodingKey]
        mutating func encodeNil() throws {}
        mutating func encode(_ value: Bool) throws {}
        mutating func encode(_ value: String) throws {}
        mutating func encode(_ value: Double) throws {}
        mutating func encode(_ value: Float) throws {}
        mutating func encode(_ value: Int) throws {}
        mutating func encode(_ value: Int8) throws {}
        mutating func encode(_ value: Int16) throws {}
        mutating func encode(_ value: Int32) throws {}
        mutating func encode(_ value: Int64) throws {}
        mutating func encode(_ value: UInt) throws {}
        mutating func encode(_ value: UInt8) throws {}
        mutating func encode(_ value: UInt16) throws {}
        mutating func encode(_ value: UInt32) throws {}
        mutating func encode(_ value: UInt64) throws {}
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: Int128) throws {}
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        mutating func encode(_ value: UInt128) throws {}
        mutating func encode<T: Encodable>(_ value: T) throws {
            try ScanEncoder(codingPath: codingPath).scan(value)
        }
    }
}
