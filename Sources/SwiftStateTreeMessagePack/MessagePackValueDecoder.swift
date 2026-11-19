import Foundation
import SwiftStateTree

struct MessagePackValueDecoder {
    /// Set for a client input's payload (`MessagePackPayloadSource`): its `AnyCodable` fields
    /// decode as the JSON round trip built them (`decodeAnyCodable`). Frames the server builds
    /// decode `AnyCodable` from the value directly, as before.
    var clientPayload = false

    func decode<T: Decodable>(_ type: T.Type, from value: MessagePackValue) throws -> T {
        let decoder = MessagePackValueBoxDecoder(value: value, codingPath: [], clientPayload: clientPayload)
        return try T(from: decoder)
    }
}

private final class MessagePackValueBoxDecoder: Decoder {
    let value: MessagePackValue
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    let clientPayload: Bool

    init(value: MessagePackValue, codingPath: [CodingKey], clientPayload: Bool) {
        self.value = value
        self.codingPath = codingPath
        self.clientPayload = clientPayload
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case let .map(values) = value else {
            throw typeMismatch(KeyedDecodingContainer<Key>.self)
        }
        var map: [String: MessagePackValue] = [:]
        for (key, value) in values {
            guard case let .string(keyString) = key else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Non-string key in map"
                ))
            }
            map[keyString] = value
        }
        let container = MessagePackKeyedDecodingContainer<Key>(
            decoder: self,
            codingPath: codingPath,
            map: map
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case let .array(values) = value else {
            throw typeMismatch(UnkeyedDecodingContainer.self)
        }
        return MessagePackUnkeyedDecodingContainer(decoder: self, codingPath: codingPath, values: values)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        MessagePackSingleValueDecodingContainer(decoder: self, codingPath: codingPath, value: value)
    }

    private func typeMismatch(_ type: Any.Type) -> DecodingError {
        DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected \(type), found \(value)"
        ))
    }
}

private struct MessagePackKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: MessagePackValueBoxDecoder
    var codingPath: [CodingKey]
    let map: [String: MessagePackValue]

    var allKeys: [Key] {
        map.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        map[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = map[key.stringValue] else {
            // A client payload's missing key throws, as `JSONDecoder` does. A frame the server
            // builds keeps the old answer (true).
            if decoder.clientPayload {
                throw DecodingError.keyNotFound(key, DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \(key.stringValue)"
                ))
            }
            return true
        }
        if case .nil = value {
            return true
        }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeValue(forKey: key).decodeBool(codingPath: codingPath + [key])
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeValue(forKey: key).decodeString(codingPath: codingPath + [key])
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeValue(forKey: key).decodeDouble(codingPath: codingPath + [key])
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeValue(forKey: key).decodeFloat(codingPath: codingPath + [key])
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key])
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeValue(forKey: key).decodeInteger(Int8.self, codingPath: codingPath + [key])
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeValue(forKey: key).decodeInteger(Int16.self, codingPath: codingPath + [key])
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeValue(forKey: key).decodeInteger(Int32.self, codingPath: codingPath + [key])
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeValue(forKey: key).decodeInteger(Int64.self, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try decodeValue(forKey: key).decodeInteger(UInt.self, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try decodeValue(forKey: key).decodeInteger(UInt8.self, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try decodeValue(forKey: key).decodeInteger(UInt16.self, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try decodeValue(forKey: key).decodeInteger(UInt32.self, codingPath: codingPath + [key])
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key])
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let box = try decodeValue(forKey: key)
        if let special = try box.decodeSpecial(type, codingPath: codingPath + [key], clientPayload: decoder.clientPayload) {
            return special
        }
        let value = box.value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key], clientPayload: decoder.clientPayload)
        return try T(from: nestedDecoder)
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let value = try decodeValue(forKey: key).value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key], clientPayload: decoder.clientPayload)
        return try nestedDecoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let value = try decodeValue(forKey: key).value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key], clientPayload: decoder.clientPayload)
        return try nestedDecoder.unkeyedContainer()
    }

    /// The value under `"super"`, as `JSONDecoder` reads it, whether or not `Key` has a `super`
    /// case; nil when it's missing.
    func superDecoder() throws -> Decoder {
        let key = SuperCodingKey()
        return MessagePackValueBoxDecoder(value: map[key.stringValue] ?? .nil, codingPath: codingPath + [key], clientPayload: decoder.clientPayload)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let value = map[key.stringValue] ?? .nil
        return MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key], clientPayload: decoder.clientPayload)
    }

    private func decodeValue(forKey key: Key) throws -> MessagePackValueBox {
        guard let value = map[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Missing key \(key.stringValue)"
            ))
        }
        return MessagePackValueBox(value: value)
    }
}

/// The key `superDecoder()` reads, as `JSONDecoder`'s `"super"`.
private struct SuperCodingKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) { guard stringValue == "super" else { return nil } }
    init?(intValue: Int) { nil }
}

private struct MessagePackUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: MessagePackValueBoxDecoder
    var codingPath: [CodingKey]
    let values: [MessagePackValue]
    var currentIndex: Int = 0

    var count: Int? {
        values.count
    }

    var isAtEnd: Bool {
        currentIndex >= values.count
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            // A client payload's read past the end throws, as `JSONDecoder` does. A frame the
            // server builds keeps the old answer (true).
            if decoder.clientPayload {
                throw DecodingError.valueNotFound(Optional<Any>.self, DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unkeyed container is at end."
                ))
            }
            return true
        }
        if case .nil = values[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try next { try $0.decodeBool(codingPath: $1) }
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try next { try $0.decodeString(codingPath: $1) }
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try next { try $0.decodeDouble(codingPath: $1) }
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try next { try $0.decodeFloat(codingPath: $1) }
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try next { try $0.decodeInt(codingPath: $1) }
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try next { try $0.decodeInteger(Int8.self, codingPath: $1) }
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try next { try $0.decodeInteger(Int16.self, codingPath: $1) }
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try next { try $0.decodeInteger(Int32.self, codingPath: $1) }
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try next { try $0.decodeInteger(Int64.self, codingPath: $1) }
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try next { try $0.decodeInteger(UInt.self, codingPath: $1) }
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try next { try $0.decodeInteger(UInt8.self, codingPath: $1) }
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try next { try $0.decodeInteger(UInt16.self, codingPath: $1) }
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try next { try $0.decodeInteger(UInt32.self, codingPath: $1) }
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try next { try $0.decodeUInt(codingPath: $1) }
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (codingPath, clientPayload) = (codingPath, decoder.clientPayload)
        return try next { box, _ in
            if let special = try box.decodeSpecial(type, codingPath: codingPath, clientPayload: clientPayload) {
                return special
            }
            return try T(from: MessagePackValueBoxDecoder(value: box.value, codingPath: codingPath, clientPayload: clientPayload))
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (codingPath, clientPayload) = (codingPath, decoder.clientPayload)
        return try next { box, _ in
            try MessagePackValueBoxDecoder(value: box.value, codingPath: codingPath, clientPayload: clientPayload).container(keyedBy: type)
        }
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let (codingPath, clientPayload) = (codingPath, decoder.clientPayload)
        return try next { box, _ in
            try MessagePackValueBoxDecoder(value: box.value, codingPath: codingPath, clientPayload: clientPayload).unkeyedContainer()
        }
    }

    mutating func superDecoder() throws -> Decoder {
        let (codingPath, clientPayload) = (codingPath, decoder.clientPayload)
        return try next { box, _ in
            MessagePackValueBoxDecoder(value: box.value, codingPath: codingPath, clientPayload: clientPayload)
        }
    }

    /// Decodes the current element with `body`, and moves past it only when that succeeds, as
    /// `JSONDecoder`'s unkeyed container does: a decode that throws leaves the element for a
    /// fallback read (a hand-written `init(from:)` that tries one type, then another).
    private mutating func next<R>(_ body: (MessagePackValueBox, [CodingKey]) throws -> R) throws -> R {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(R.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end."
            ))
        }
        let result = try body(MessagePackValueBox(value: values[currentIndex]), codingPath)
        currentIndex += 1
        return result
    }
}

private struct MessagePackSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: MessagePackValueBoxDecoder
    var codingPath: [CodingKey]
    let value: MessagePackValue

    func decodeNil() -> Bool {
        if case .nil = value {
            return true
        }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try MessagePackValueBox(value: value).decodeBool(codingPath: codingPath)
    }

    func decode(_ type: String.Type) throws -> String {
        try MessagePackValueBox(value: value).decodeString(codingPath: codingPath)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try MessagePackValueBox(value: value).decodeDouble(codingPath: codingPath)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try MessagePackValueBox(value: value).decodeFloat(codingPath: codingPath)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try MessagePackValueBox(value: value).decodeInteger(Int8.self, codingPath: codingPath)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try MessagePackValueBox(value: value).decodeInteger(Int16.self, codingPath: codingPath)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try MessagePackValueBox(value: value).decodeInteger(Int32.self, codingPath: codingPath)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try MessagePackValueBox(value: value).decodeInteger(Int64.self, codingPath: codingPath)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try MessagePackValueBox(value: value).decodeInteger(UInt.self, codingPath: codingPath)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try MessagePackValueBox(value: value).decodeInteger(UInt8.self, codingPath: codingPath)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try MessagePackValueBox(value: value).decodeInteger(UInt16.self, codingPath: codingPath)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try MessagePackValueBox(value: value).decodeInteger(UInt32.self, codingPath: codingPath)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let special = try MessagePackValueBox(value: value).decodeSpecial(type, codingPath: codingPath, clientPayload: decoder.clientPayload) {
            return special
        }
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath, clientPayload: decoder.clientPayload)
        return try T(from: nestedDecoder)
    }
}

private struct MessagePackValueBox {
    let value: MessagePackValue

    func decodeBool(codingPath: [CodingKey]) throws -> Bool {
        guard case let .bool(value) = value else {
            throw typeMismatch(Bool.self, codingPath: codingPath)
        }
        return value
    }

    func decodeString(codingPath: [CodingKey]) throws -> String {
        guard case let .string(value) = value else {
            throw typeMismatch(String.self, codingPath: codingPath)
        }
        return value
    }

    func decodeDouble(codingPath: [CodingKey]) throws -> Double {
        switch value {
        case .double(let value):
            return value
        case .float(let value):
            return Double(value)
        case .int(let value):
            return Double(value)
        case .uint(let value):
            return Double(value)
        default:
            throw typeMismatch(Double.self, codingPath: codingPath)
        }
    }

    /// A `Float`, refusing what the JSON round trip refused: a finite value past `Float`'s range
    /// (it would become infinite) and a nonzero one too small for it (it would become zero).
    func decodeFloat(codingPath: [CodingKey]) throws -> Float {
        switch value {
        case .float(let value): return value
        // Straight from the integer, as the round trip parsed its text: one rounding, not two.
        case .int(let value): return Float(value)
        case .uint(let value): return Float(value)
        default: break
        }
        let double = try decodeDouble(codingPath: codingPath)
        // `JSONDecoder` parses the number's text straight into `Float`, and the round trip wrote
        // the double's shortest text: one rounding, from that text. `Float(double)` rounds the
        // exact double, which differs on a Float midpoint whose shortest text isn't exact
        // (1 + 2^-24 is "1.0000000596046448", which rounds up). A double that converts exactly
        // needs no text.
        var float = Float(double)
        if Double(float) != double, double.isFinite, let parsed = Float(double.description) {
            float = parsed
        }
        if double.isFinite && float.isInfinite || double != 0 && float == 0 {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) out of range for Float"
            ))
        }
        return float
    }

    /// The types `JSONDecoder` reads in its own way rather than through their `Codable` form, read
    /// the same way here. Nil when `type` isn't one of them, or, outside a client payload, when
    /// the value is in the type's keyed `Codable` form.
    /// - `Data`: binary, or base64 text.
    /// - `Decimal`: a number. Outside a client payload, also the string `MessagePackValueEncoder`
    ///   writes, or the keyed form. A client payload refuses anything else, as `JSONDecoder` does:
    ///   the keyed form accepted live would be refused by replay's round trip.
    /// - `URL`: a string, as `JSONDecoder` reads it and `MessagePackValueEncoder` writes it. A
    ///   client payload refuses the keyed form, for the same reason.
    /// - `AnyCodable`, in a client payload only: `decodeAnyCodable()`.
    func decodeSpecial<T>(_ type: T.Type, codingPath: [CodingKey], clientPayload: Bool) throws -> T? {
        if type == Data.self {
            return try decodeData(codingPath: codingPath) as? T
        }
        if type == Decimal.self {
            if let decimal = try decodeDecimalNumber(codingPath: codingPath, clientPayload: clientPayload) {
                return decimal as? T
            }
            if clientPayload { throw typeMismatch(Decimal.self, codingPath: codingPath) }
            return nil
        }
        if type == URL.self {
            if case .string(let text) = value {
                guard let url = URL(string: text) else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Invalid URL string."
                    ))
                }
                return url as? T
            }
            if clientPayload { throw typeMismatch(URL.self, codingPath: codingPath) }
            return nil
        }
        if clientPayload, type == AnyCodable.self {
            return try decodeAnyCodable() as? T
        }
        return nil
    }

    /// An `AnyCodable` field, as the JSON round trip built it: the value's tree, through
    /// `JSONEncoder` and `JSONDecoder`. So an integral float is an `Int` and a binary value a
    /// base64 string, as before (#521 PR 2), which a handler reading the field's `base` relies on.
    /// The tree was already walked (depth, keys, finite numbers) by the payload's source.
    func decodeAnyCodable() throws -> AnyCodable {
        let tree = try MessagePackPayloadSource.anyCodable(from: value)
        return try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(tree))
    }

    /// A `Decimal` sent as a number, as a client writes one, read as the JSON round trip read it:
    /// from the number's shortest decimal text, so `0.1` is `0.1`. Outside a client payload, also
    /// the string the server's value encoder writes (`MessagePackValueEncoder`); a client payload
    /// refuses a string, as the round trip's `JSONDecoder` did. Nil for any other value, which
    /// `Decimal`'s own keyed `Codable` form then decodes.
    func decodeDecimalNumber(codingPath: [CodingKey], clientPayload: Bool) throws -> Decimal? {
        let text: String
        switch value {
        case .string(let value) where !clientPayload: text = value
        case .int(let value): return Decimal(value)
        case .uint(let value): return Decimal(value)
        case .double(let value) where value.isFinite: text = value.description
        // The `AnyCodable` tree held a float as a `Double`, and `JSONEncoder` wrote that.
        case .float(let value) where value.isFinite: text = Double(value).description
        case .double, .float:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) isn't a finite Decimal"
            ))
        default: return nil
        }
        guard let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) doesn't read as a Decimal"
            ))
        }
        return decimal
    }

    func decodeInt(codingPath: [CodingKey]) throws -> Int {
        switch value {
        case .int(let value):
            guard value >= Int64(Int.min) && value <= Int64(Int.max) else {
                throw typeMismatch(Int.self, codingPath: codingPath)
            }
            return Int(value)
        case .uint(let value):
            guard value <= UInt64(Int.max) else {
                throw typeMismatch(Int.self, codingPath: codingPath)
            }
            return Int(value)
        default:
            throw typeMismatch(Int.self, codingPath: codingPath)
        }
    }

    /// An integer of `type`, converted exactly: a value it can't hold throws, never traps.
    func decodeInteger<T: FixedWidthInteger>(_ type: T.Type, codingPath: [CodingKey]) throws -> T {
        let result: T?
        switch value {
        case .int(let value): result = T(exactly: value)
        case .uint(let value): result = T(exactly: value)
        default: throw typeMismatch(T.self, codingPath: codingPath)
        }
        guard let result else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) out of range for \(T.self)"
            ))
        }
        return result
    }

    func decodeUInt(codingPath: [CodingKey]) throws -> UInt64 {
        switch value {
        case .uint(let value):
            return value
        case .int(let value):
            guard value >= 0 else {
                throw typeMismatch(UInt64.self, codingPath: codingPath)
            }
            return UInt64(value)
        default:
            throw typeMismatch(UInt64.self, codingPath: codingPath)
        }
    }

    func decodeData(codingPath: [CodingKey]) throws -> Data {
        switch value {
        case .binary(let value):
            return value
        case .string(let value):
            if let data = Data(base64Encoded: value) {
                return data
            }
            throw typeMismatch(Data.self, codingPath: codingPath)
        default:
            throw typeMismatch(Data.self, codingPath: codingPath)
        }
    }

    private func typeMismatch(_ type: Any.Type, codingPath: [CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected \(type), found \(value)"
        ))
    }
}

