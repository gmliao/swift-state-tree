import Foundation

/// Where a `Decimal` would reach the wire, refused at registration (#597).
///
/// `Decimal` has no wire form: its synced value would be its private stored fields, and a
/// payload's MessagePack form was a lossy `Double` on one path and a string on another. A synced
/// field is a `SyncRegistrationError.Problem.decimalField`; a payload field is in
/// `LandRegistrationError.decimalFields`. A `.serverOnly` or `@Internal` state field, a resolver
/// output and anything else the server only reads may hold one.
enum DecimalFields {
    /// What to use instead, in every refusal.
    static let advice = "Decimal has no wire form; store an integer of the smallest unit (cents) or a String"

    /// The paths under `type` (named `root`) that hold a `Decimal`, as a payload's fields reach
    /// the wire: a payload type's fields (`getFieldMetadata()`), a state node's synced fields, a
    /// `@SnapshotConvertible` type's stored fields, optionals, arrays, sets and dictionaries
    /// (keys and values), and a nested plain `Decodable` type's fields.
    ///
    /// A nested plain type's fields are found by decoding it once through a probing decoder
    /// (`FieldProbe`), which records the type of every field its `init(from:)` asks for. A
    /// synthesized `init(from:)` asks for every field, defaults or not. Not seen: the fields a
    /// hand-written `init(from:)` asks for after it throws (a validation), and the fields after
    /// an enum that isn't `CaseIterable`, whose placeholder can't be built from nothing.
    static func payloadPaths(in type: Any.Type, root: String) -> [String] {
        var walker = Walker()
        walker.visit(type, path: root)
        return walker.paths
    }

    private struct Walker {
        var paths: [String] = []
        /// The types on the current path: a type that holds itself is walked once per path.
        private var onPath: Set<ObjectIdentifier> = []

        mutating func visit(_ type: Any.Type, path: String) {
            if type == Decimal.self {
                paths.append(path)
                return
            }
            if let wrapped = NestingOptionalHelper.wrappedType(of: type) {
                visit(wrapped, path: path)
                return
            }
            if let value = SchemaHelper.dictionaryValueType(from: type) {
                if let key = SchemaHelper.dictionaryKeyType(from: type) {
                    visit(key, path: "\(path)[key]")
                }
                visit(value, path: "\(path)[*]")
                return
            }
            if let element = SchemaHelper.arrayElementType(from: type) ?? SyncSetHelper.elementType(of: type) {
                visit(element, path: "\(path)[*]")
                return
            }
            if FieldProbe.isLeaf(type) { return }
            let id = ObjectIdentifier(type)
            guard !onPath.contains(id) else { return }
            onPath.insert(id)
            defer { onPath.remove(id) }
            if let node = type as? any StateNodeProtocol.Type {
                for field in node.getFieldMetadata() where field.policy != nil && field.policy != .serverOnly {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            } else if let provider = type as? any SchemaMetadataProvider.Type {
                for field in provider.getFieldMetadata() {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            } else if let stored = type as? any SnapshotConvertibleStoredFields.Type {
                // A field with no type annotation is `Any` here, and isn't followed.
                for field in stored._snapshotStoredFields where field.type != Any.self {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            } else if let decodable = type as? any Decodable.Type {
                for field in FieldProbe.fields(of: decodable) {
                    visit(field.type, path: "\(path).\(field.name)")
                }
            }
        }
    }
}

/// Finds a `Decodable` type's fields by decoding it once through a decoder that records the type
/// of each field asked for and answers with a placeholder (the reflection CodableReflection did
/// for Fluent). Nested types aren't decoded field by field: a placeholder is shallow, and the
/// caller walks each recorded type itself.
enum FieldProbe {
    /// A field asked for by name, with the type `init(from:)` decodes it as.
    struct Field {
        let name: String
        let type: Any.Type
    }

    /// The fields `type`'s `init(from:)` asks for, in order, up to a throw.
    static func fields(of type: any Decodable.Type) -> [Field] {
        let record = Record()
        _ = try? type.init(from: ProbeDecoder(record: record))
        return record.fields
    }

    /// Types with no fields to probe: the scalars and the Foundation values decoded from one.
    static func isLeaf(_ type: Any.Type) -> Bool {
        leafPlaceholder(type) != nil
    }

    /// A value of a leaf type, or nil for any other type.
    static func leafPlaceholder(_ type: Any.Type) -> Any? {
        switch type {
        case is Bool.Type: return false
        case is String.Type: return ""
        case is Int.Type: return 0 as Int
        case is Int8.Type: return 0 as Int8
        case is Int16.Type: return 0 as Int16
        case is Int32.Type: return 0 as Int32
        case is Int64.Type: return 0 as Int64
        case is UInt.Type: return 0 as UInt
        case is UInt8.Type: return 0 as UInt8
        case is UInt16.Type: return 0 as UInt16
        case is UInt32.Type: return 0 as UInt32
        case is UInt64.Type: return 0 as UInt64
        case is Double.Type: return 0 as Double
        case is Float.Type: return 0 as Float
        case is Decimal.Type: return Decimal(0)
        case is Date.Type: return Date(timeIntervalSince1970: 0)
        case is Data.Type: return Data()
        case is UUID.Type: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        case is URL.Type: return URL(string: "about:blank")!
        default: return nil
        }
    }

    /// The deepest placeholder built: past it, the probe of that field stops.
    static let placeholderDepth = 8

    struct Stop: Error {}

    final class Record {
        var fields: [Field] = []
    }

    /// A placeholder value of `type`: a leaf's, a `CaseIterable` type's first case (an enum
    /// with a raw value needs a valid one), or one decoded from a decoder that answers "absent"
    /// and "empty" (optionals nil, collections empty), down to `placeholderDepth`.
    static func placeholder<T: Decodable>(_ type: T.Type, depth: Int) throws -> T {
        if let leaf = leafPlaceholder(type) as? T { return leaf }
        if let cases = type as? any CaseIterable.Type, let first = firstCase(cases) as? T { return first }
        guard depth < placeholderDepth else { throw Stop() }
        return try T(from: PlaceholderDecoder(depth: depth + 1))
    }

    private static func firstCase(_ type: any CaseIterable.Type) -> Any? {
        func first<C: CaseIterable>(_: C.Type) -> Any? { C.allCases.first }
        return first(type)
    }

    // MARK: Recording decoder (the probed type's own fields)

    struct ProbeDecoder: Decoder {
        let record: Record
        var codingPath: [CodingKey] { [] }
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
            KeyedDecodingContainer(ProbeKeyed<Key>(record: record))
        }
        func unkeyedContainer() throws -> UnkeyedDecodingContainer { PlaceholderUnkeyed(depth: 1) }
        func singleValueContainer() throws -> SingleValueDecodingContainer { PlaceholderSingle(depth: 1) }
    }

    struct ProbeKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let record: Record
        var codingPath: [CodingKey] { [] }
        var allKeys: [Key] { [] }
        func contains(_ key: Key) -> Bool { true }
        func decodeNil(forKey key: Key) throws -> Bool { false }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            record.fields.append(Field(name: key.stringValue, type: T.self))
            return try placeholder(T.self, depth: 1)
        }
        func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
            record.fields.append(Field(name: key.stringValue, type: T.self))
            return nil
        }
        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try leaf(Bool.self, key) }
        func decode(_ type: String.Type, forKey key: Key) throws -> String { try leaf(String.self, key) }
        func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try leaf(Double.self, key) }
        func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try leaf(Float.self, key) }
        func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try leaf(Int.self, key) }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try leaf(Int8.self, key) }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try leaf(Int16.self, key) }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try leaf(Int32.self, key) }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try leaf(Int64.self, key) }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try leaf(UInt.self, key) }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try leaf(UInt8.self, key) }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try leaf(UInt16.self, key) }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try leaf(UInt32.self, key) }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try leaf(UInt64.self, key) }
        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            KeyedDecodingContainer(PlaceholderKeyed<NestedKey>(depth: 1))
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { PlaceholderUnkeyed(depth: 1) }
        func superDecoder() throws -> Decoder { PlaceholderDecoder(depth: 1) }
        func superDecoder(forKey key: Key) throws -> Decoder { PlaceholderDecoder(depth: 1) }

        /// A scalar field (the typed overloads): recorded under its own type.
        private func leaf<V: Decodable>(_ type: V.Type, _ key: Key) throws -> V {
            record.fields.append(Field(name: key.stringValue, type: V.self))
            return try placeholder(V.self, depth: 1)
        }
    }

    // MARK: Placeholder decoder (absent, empty; records nothing)

    struct PlaceholderDecoder: Decoder {
        let depth: Int
        var codingPath: [CodingKey] { [] }
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
            KeyedDecodingContainer(PlaceholderKeyed<Key>(depth: depth))
        }
        func unkeyedContainer() throws -> UnkeyedDecodingContainer { PlaceholderUnkeyed(depth: depth) }
        func singleValueContainer() throws -> SingleValueDecodingContainer { PlaceholderSingle(depth: depth) }
    }

    struct PlaceholderKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let depth: Int
        var codingPath: [CodingKey] { [] }
        var allKeys: [Key] { [] }
        func contains(_ key: Key) -> Bool { false }
        func decodeNil(forKey key: Key) throws -> Bool { true }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try placeholder(T.self, depth: depth) }
        func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
            KeyedDecodingContainer(PlaceholderKeyed<NestedKey>(depth: depth))
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { PlaceholderUnkeyed(depth: depth) }
        func superDecoder() throws -> Decoder { PlaceholderDecoder(depth: depth) }
        func superDecoder(forKey key: Key) throws -> Decoder { PlaceholderDecoder(depth: depth) }
    }

    struct PlaceholderUnkeyed: UnkeyedDecodingContainer {
        let depth: Int
        var codingPath: [CodingKey] { [] }
        var count: Int? { 0 }
        var isAtEnd: Bool { true }
        var currentIndex: Int { 0 }
        mutating func decodeNil() throws -> Bool { true }
        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { throw Stop() }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { throw Stop() }
        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { throw Stop() }
        mutating func superDecoder() throws -> Decoder { throw Stop() }
    }

    struct PlaceholderSingle: SingleValueDecodingContainer {
        let depth: Int
        var codingPath: [CodingKey] { [] }
        func decodeNil() -> Bool { false }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try placeholder(T.self, depth: depth) }
    }
}
