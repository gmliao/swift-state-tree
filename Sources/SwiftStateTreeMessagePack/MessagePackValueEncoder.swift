import Foundation
import SwiftStateTree

public struct MessagePackValueEncoder {
    public init() {}
    
    public func encode<T: Encodable>(_ value: T) throws -> MessagePackValue {
        try box(value)
    }

    fileprivate func box<T: Encodable>(_ value: T) throws -> MessagePackValue {
        if let value = value as? MessagePackValue {
            return value
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? Int {
            return .int(Int64(value))
        }
        if let value = value as? Int8 {
            return .int(Int64(value))
        }
        if let value = value as? Int16 {
            return .int(Int64(value))
        }
        if let value = value as? Int32 {
            return .int(Int64(value))
        }
        if let value = value as? Int64 {
            return .int(value)
        }
        if let value = value as? UInt {
            return .uint(UInt64(value))
        }
        if let value = value as? UInt8 {
            return .uint(UInt64(value))
        }
        if let value = value as? UInt16 {
            return .uint(UInt64(value))
        }
        if let value = value as? UInt32 {
            return .uint(UInt64(value))
        }
        if let value = value as? UInt64 {
            return .uint(value)
        }
        if let value = value as? Float {
            return .float(value)
        }
        if let value = value as? Double {
            return .double(value)
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? Data {
            return .binary(value)
        }
        if let value = value as? Date {
            return .double(value.timeIntervalSinceReferenceDate)
        }
        if let value = value as? UUID {
            return .string(value.uuidString)
        }
        if let value = value as? URL {
            return .string(value.absoluteString)
        }
        if let value = value as? Decimal {
            return .string(value.description)
        }
        if let value = value as? AnyCodable {
            return try MessagePackDirectEncoder().encodeAnyCodable(value)
        }
        if let value = value as? SnapshotValue {
            return MessagePackDirectEncoder().encodeSnapshotValue(value)
        }

        var output: MessagePackValue?
        let capturingEncoder = MessagePackValueBoxEncoder(encoder: self, codingPath: []) {
            output = $0
        }
        try value.encode(to: capturingEncoder)
        if let output {
            return output
        }
        let context = EncodingError.Context(codingPath: [], debugDescription: "Failed to encode value")
        throw EncodingError.invalidValue(value, context)
    }
}

private final class MessagePackValueBoxEncoder: Encoder {
    let encoder: MessagePackValueEncoder
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] = [:]
    private let setValue: (MessagePackValue) -> Void

    init(encoder: MessagePackValueEncoder, codingPath: [CodingKey], setValue: @escaping (MessagePackValue) -> Void) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.setValue = setValue
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let storage = MessagePackObjectStorage()
        let container = MessagePackKeyedEncodingContainer<Key>(
            encoder: encoder,
            codingPath: codingPath,
            storage: storage,
            setValue: setValue
        )
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let storage = MessagePackArrayStorage()
        return MessagePackUnkeyedEncodingContainer(
            encoder: encoder,
            codingPath: codingPath,
            storage: storage,
            setValue: setValue
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        MessagePackSingleValueEncodingContainer(encoder: encoder, codingPath: codingPath, setValue: setValue)
    }
}

private final class MessagePackObjectStorage {
    var map: [MessagePackValue: MessagePackValue] = [:]
}

private final class MessagePackArrayStorage {
    var values: [MessagePackValue] = []
}

private struct MessagePackKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: MessagePackValueEncoder
    var codingPath: [CodingKey]
    private let storage: MessagePackObjectStorage
    private let setValue: (MessagePackValue) -> Void

    init(
        encoder: MessagePackValueEncoder,
        codingPath: [CodingKey],
        storage: MessagePackObjectStorage,
        setValue: @escaping (MessagePackValue) -> Void
    ) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.storage = storage
        self.setValue = setValue
        updateValue()
    }

    mutating func encodeNil(forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .nil
        updateValue()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .bool(value)
        updateValue()
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .string(value)
        updateValue()
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .double(value)
        updateValue()
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .float(value)
        updateValue()
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .int(Int64(value))
        updateValue()
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .int(Int64(value))
        updateValue()
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .int(Int64(value))
        updateValue()
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .int(Int64(value))
        updateValue()
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .int(value)
        updateValue()
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .uint(UInt64(value))
        updateValue()
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .uint(UInt64(value))
        updateValue()
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .uint(UInt64(value))
        updateValue()
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .uint(UInt64(value))
        updateValue()
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = .uint(value)
        updateValue()
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        storage.map[.string(key.stringValue)] = try encoder.box(value)
        updateValue()
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nestedStorage = MessagePackObjectStorage()
        let keyString = key.stringValue
        let parentSetValue = setValue
        let updateParent: (MessagePackValue) -> Void = { [weak storage] value in
            storage?.map[.string(keyString)] = value
            if let storage {
                parentSetValue(.map(storage.map))
            }
        }
        let container = MessagePackKeyedEncodingContainer<NestedKey>(
            encoder: encoder,
            codingPath: codingPath + [key],
            storage: nestedStorage,
            setValue: updateParent
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nestedStorage = MessagePackArrayStorage()
        let keyString = key.stringValue
        let parentSetValue = setValue
        let updateParent: (MessagePackValue) -> Void = { [weak storage] value in
            storage?.map[.string(keyString)] = value
            if let storage {
                parentSetValue(.map(storage.map))
            }
        }
        return MessagePackUnkeyedEncodingContainer(
            encoder: encoder,
            codingPath: codingPath + [key],
            storage: nestedStorage,
            setValue: updateParent
        )
    }

    mutating func superEncoder() -> Encoder {
        if let key = Key(stringValue: "super") {
            return superEncoder(forKey: key)
        }
        return MessagePackValueBoxEncoder(encoder: encoder, codingPath: codingPath, setValue: { _ in })
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let keyString = key.stringValue
        let parentSetValue = setValue
        return MessagePackValueBoxEncoder(
            encoder: encoder,
            codingPath: codingPath + [key],
            setValue: { [weak storage] value in
                storage?.map[.string(keyString)] = value
                if let storage {
                    parentSetValue(.map(storage.map))
                }
            }
        )
    }

    private func updateValue() {
        setValue(.map(storage.map))
    }
}

private struct MessagePackUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: MessagePackValueEncoder
    var codingPath: [CodingKey]
    private let storage: MessagePackArrayStorage
    private let setValue: (MessagePackValue) -> Void

    init(
        encoder: MessagePackValueEncoder,
        codingPath: [CodingKey],
        storage: MessagePackArrayStorage,
        setValue: @escaping (MessagePackValue) -> Void
    ) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.storage = storage
        self.setValue = setValue
        updateValue()
    }

    var count: Int {
        storage.values.count
    }

    mutating func encodeNil() throws {
        storage.values.append(.nil)
        updateValue()
    }

    mutating func encode(_ value: Bool) throws {
        storage.values.append(.bool(value))
        updateValue()
    }

    mutating func encode(_ value: String) throws {
        storage.values.append(.string(value))
        updateValue()
    }

    mutating func encode(_ value: Double) throws {
        storage.values.append(.double(value))
        updateValue()
    }

    mutating func encode(_ value: Float) throws {
        storage.values.append(.float(value))
        updateValue()
    }

    mutating func encode(_ value: Int) throws {
        storage.values.append(.int(Int64(value)))
        updateValue()
    }

    mutating func encode(_ value: Int8) throws {
        storage.values.append(.int(Int64(value)))
        updateValue()
    }

    mutating func encode(_ value: Int16) throws {
        storage.values.append(.int(Int64(value)))
        updateValue()
    }

    mutating func encode(_ value: Int32) throws {
        storage.values.append(.int(Int64(value)))
        updateValue()
    }

    mutating func encode(_ value: Int64) throws {
        storage.values.append(.int(value))
        updateValue()
    }

    mutating func encode(_ value: UInt) throws {
        storage.values.append(.uint(UInt64(value)))
        updateValue()
    }

    mutating func encode(_ value: UInt8) throws {
        storage.values.append(.uint(UInt64(value)))
        updateValue()
    }

    mutating func encode(_ value: UInt16) throws {
        storage.values.append(.uint(UInt64(value)))
        updateValue()
    }

    mutating func encode(_ value: UInt32) throws {
        storage.values.append(.uint(UInt64(value)))
        updateValue()
    }

    mutating func encode(_ value: UInt64) throws {
        storage.values.append(.uint(value))
        updateValue()
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        storage.values.append(try encoder.box(value))
        updateValue()
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let nestedStorage = MessagePackObjectStorage()
        let index = storage.values.count
        storage.values.append(.map([:]))
        updateValue()
        let parentSetValue = setValue
        let updateParent: (MessagePackValue) -> Void = { [weak storage] value in
            storage?.values[index] = value
            if let storage {
                parentSetValue(.array(storage.values))
            }
        }
        let container = MessagePackKeyedEncodingContainer<NestedKey>(
            encoder: encoder,
            codingPath: codingPath,
            storage: nestedStorage,
            setValue: updateParent
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nestedStorage = MessagePackArrayStorage()
        let index = storage.values.count
        storage.values.append(.array([]))
        updateValue()
        let parentSetValue = setValue
        let updateParent: (MessagePackValue) -> Void = { [weak storage] value in
            storage?.values[index] = value
            if let storage {
                parentSetValue(.array(storage.values))
            }
        }
        return MessagePackUnkeyedEncodingContainer(
            encoder: encoder,
            codingPath: codingPath,
            storage: nestedStorage,
            setValue: updateParent
        )
    }

    mutating func superEncoder() -> Encoder {
        let index = storage.values.count
        storage.values.append(.nil)
        updateValue()
        let parentSetValue = setValue
        return MessagePackValueBoxEncoder(encoder: encoder, codingPath: codingPath) { [weak storage] value in
            storage?.values[index] = value
            if let storage {
                parentSetValue(.array(storage.values))
            }
        }
    }

    private func updateValue() {
        setValue(.array(storage.values))
    }
}

private struct MessagePackSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: MessagePackValueEncoder
    var codingPath: [CodingKey]
    private let setValue: (MessagePackValue) -> Void

    init(encoder: MessagePackValueEncoder, codingPath: [CodingKey], setValue: @escaping (MessagePackValue) -> Void) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.setValue = setValue
    }

    mutating func encodeNil() throws {
        setValue(.nil)
    }

    mutating func encode(_ value: Bool) throws {
        setValue(.bool(value))
    }

    mutating func encode(_ value: String) throws {
        setValue(.string(value))
    }

    mutating func encode(_ value: Double) throws {
        setValue(.double(value))
    }

    mutating func encode(_ value: Float) throws {
        setValue(.float(value))
    }

    mutating func encode(_ value: Int) throws {
        setValue(.int(Int64(value)))
    }

    mutating func encode(_ value: Int8) throws {
        setValue(.int(Int64(value)))
    }

    mutating func encode(_ value: Int16) throws {
        setValue(.int(Int64(value)))
    }

    mutating func encode(_ value: Int32) throws {
        setValue(.int(Int64(value)))
    }

    mutating func encode(_ value: Int64) throws {
        setValue(.int(value))
    }

    mutating func encode(_ value: UInt) throws {
        setValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt8) throws {
        setValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt16) throws {
        setValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt32) throws {
        setValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64) throws {
        setValue(.uint(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        setValue(try encoder.box(value))
    }
}
