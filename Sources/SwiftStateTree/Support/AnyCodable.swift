import Foundation

/// Lightweight type-erased `Codable` wrapper used by the Land DSL runtime.
public struct AnyCodable: Codable, @unchecked Sendable {
    public let base: Any

    public init<T>(_ value: T?) {
        if let value {
            self.base = value
        } else {
            self.base = ()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.base = ()
        } else if let bool = try? container.decode(Bool.self) {
            self.base = bool
        } else if let int = try? container.decode(Int.self) {
            self.base = int
        } else if let double = try? container.decode(Double.self) {
            self.base = double
        } else if let string = try? container.decode(String.self) {
            self.base = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.base = array.map(\.base)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.base = dictionary.mapValues(\.base)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch base {
        case is Void:
            try container.encodeNil()
        case let value as Bool:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        case let value as String:
            try container.encode(value)
        case let value as [Any]:
            let wrapped = value.map { AnyCodable($0) }
            try container.encode(wrapped)
        case let value as [String: Any]:
            let wrapped = value.mapValues { AnyCodable($0) }
            try container.encode(wrapped)
        case let value as any Encodable:
            try value.encode(to: encoder)
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable value cannot be encoded"
            )
            throw EncodingError.invalidValue(base, context)
        }
    }
}

