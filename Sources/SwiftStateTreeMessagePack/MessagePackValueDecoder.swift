import Foundation

struct MessagePackValueDecoder {
    func decode<T: Decodable>(_ type: T.Type, from value: MessagePackValue) throws -> T {
        let decoder = MessagePackValueBoxDecoder(value: value, codingPath: [])
        return try T(from: decoder)
    }
}

private final class MessagePackValueBoxDecoder: Decoder {
    let value: MessagePackValue
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(value: MessagePackValue, codingPath: [CodingKey]) {
        self.value = value
        self.codingPath = codingPath
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
        guard let value = map[key.stringValue] else { return true }
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
        Float(try decodeValue(forKey: key).decodeDouble(codingPath: codingPath + [key]))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key])
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        Int8(try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        Int16(try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        Int32(try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        Int64(try decodeValue(forKey: key).decodeInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        UInt(try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        UInt8(try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        UInt16(try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        UInt32(try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key]))
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeValue(forKey: key).decodeUInt(codingPath: codingPath + [key])
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if type == Data.self {
            let box = try decodeValue(forKey: key)
            let data = try box.decodeData(codingPath: codingPath + [key])
            return data as! T
        }
        let value = try decodeValue(forKey: key).value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key])
        return try T(from: nestedDecoder)
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let value = try decodeValue(forKey: key).value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key])
        return try nestedDecoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let value = try decodeValue(forKey: key).value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key])
        return try nestedDecoder.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        if let key = Key(stringValue: "super") {
            return try superDecoder(forKey: key)
        }
        return MessagePackValueBoxDecoder(value: .nil, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let value = map[key.stringValue] ?? .nil
        return MessagePackValueBoxDecoder(value: value, codingPath: codingPath + [key])
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
        guard !isAtEnd else { return true }
        if case .nil = values[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try nextBox().decodeBool(codingPath: codingPath)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try nextBox().decodeString(codingPath: codingPath)
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try nextBox().decodeDouble(codingPath: codingPath)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        Float(try nextBox().decodeDouble(codingPath: codingPath))
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try nextBox().decodeInt(codingPath: codingPath)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        Int8(try nextBox().decodeInt(codingPath: codingPath))
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        Int16(try nextBox().decodeInt(codingPath: codingPath))
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        Int32(try nextBox().decodeInt(codingPath: codingPath))
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        Int64(try nextBox().decodeInt(codingPath: codingPath))
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        UInt(try nextBox().decodeUInt(codingPath: codingPath))
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        UInt8(try nextBox().decodeUInt(codingPath: codingPath))
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        UInt16(try nextBox().decodeUInt(codingPath: codingPath))
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        UInt32(try nextBox().decodeUInt(codingPath: codingPath))
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try nextBox().decodeUInt(codingPath: codingPath)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            let data = try nextBox().decodeData(codingPath: codingPath)
            return data as! T
        }
        let value = try nextBox().value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath)
        return try T(from: nestedDecoder)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let value = try nextBox().value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath)
        return try nestedDecoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let value = try nextBox().value
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath)
        return try nestedDecoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let value = try nextBox().value
        return MessagePackValueBoxDecoder(value: value, codingPath: codingPath)
    }

    private mutating func nextBox() throws -> MessagePackValueBox {
        guard !isAtEnd else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }
        let value = values[currentIndex]
        currentIndex += 1
        return MessagePackValueBox(value: value)
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
        Float(try MessagePackValueBox(value: value).decodeDouble(codingPath: codingPath))
    }

    func decode(_ type: Int.Type) throws -> Int {
        try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        Int8(try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath))
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        Int16(try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath))
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        Int32(try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath))
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        Int64(try MessagePackValueBox(value: value).decodeInt(codingPath: codingPath))
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        UInt(try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath))
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        UInt8(try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath))
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        UInt16(try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath))
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        UInt32(try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath))
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try MessagePackValueBox(value: value).decodeUInt(codingPath: codingPath)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self {
            let data = try MessagePackValueBox(value: value).decodeData(codingPath: codingPath)
            return data as! T
        }
        let nestedDecoder = MessagePackValueBoxDecoder(value: value, codingPath: codingPath)
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

