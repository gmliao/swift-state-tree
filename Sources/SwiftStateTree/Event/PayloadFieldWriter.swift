// The typed positional form of a payload (#521): `@Payload` emits `_writePayloadFields(into:)`,
// which hands each field, in name order, to a writer the encoder supplies. A field whose
// declared type has a typed form (`_PayloadWireLeaf`) is written through it; any other field
// goes through the encoder's `Codable` fallback, which is the per-field path the encoders used
// before (its bytes are unchanged by construction). The choice is made per declared field type
// at compile time, by overload resolution, never per message.

import Foundation

/// The sink a leaf writes itself into. Core can't name an encoding's value type (MessagePack
/// depends on core), so a leaf writes primitives: scalars, and an object as a count followed by
/// a key and one value per entry, keys in UTF-8 byte order.
public protocol _PayloadPrimitiveWriter {
    mutating func int(_ value: Int64)
    mutating func uint(_ value: UInt64)
    mutating func bool(_ value: Bool)
    mutating func float(_ value: Float)
    mutating func double(_ value: Double)
    mutating func string(_ value: String)
    /// An object of `count` entries; each is a `key(_:)` then one value.
    mutating func object(count: Int)
    mutating func key(_ key: String)
}

/// A payload field type with a typed wire form: it writes exactly the value the encoders' top
/// level gave it before (#521 §2.2). JSON encodings write a leaf with its own `Codable`.
public protocol _PayloadWireLeaf: Encodable {
    func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P)
}

/// The encoder's side of `_writePayloadFields(into:)`: one call per field, in field order.
public protocol _PayloadFieldWriter {
    /// A field whose type has a typed form.
    mutating func leaf<T: _PayloadWireLeaf>(_ value: T) throws
    /// Any other field: the encoding's `Codable` path, as before the writer.
    mutating func fallback<T: Encodable>(_ value: T) throws
}

extension _PayloadFieldWriter {
    /// The macro's call for each field. Overload resolution picks this one when the field's
    /// declared type is a `_PayloadWireLeaf`.
    @inlinable
    public mutating func field<T: _PayloadWireLeaf>(_ value: T) throws {
        try leaf(value)
    }

    /// The macro's call for every other field.
    @inlinable
    public mutating func field<T: Encodable>(_ value: T) throws {
        try fallback(value)
    }
}

/// How `_writePayloadFields(into:)` writes one field: through its typed form, or through the
/// `Codable` fallback. `@Payload` lists them (`_payloadFieldForms`) from the same overloads as the
/// writer, so the list can't disagree with it.
public enum _PayloadFieldForm: String, Sendable, Equatable {
    case typed
    case codable
}

/// One field of a payload and how the writer writes it, in field order.
public struct _PayloadFieldFormEntry: Sendable, Equatable {
    public let name: String
    public let form: _PayloadFieldForm

    public init(_ name: String, _ form: _PayloadFieldForm) {
        self.name = name
        self.form = form
    }
}

/// The form of a field of type `T`, chosen as `field(_:)` chooses it.
@inlinable
public func _payloadFieldForm<Root, T: _PayloadWireLeaf>(of _: KeyPath<Root, T>) -> _PayloadFieldForm { .typed }

@inlinable
public func _payloadFieldForm<Root, T>(of _: KeyPath<Root, T>) -> _PayloadFieldForm { .codable }

/// The event naming rule: the type's name without its module, with an `Event` suffix dropped
/// (`PlayerShootEvent` → `PlayerShoot`). The schema, `EventRegistry` and an event type's
/// `_payloadWireName` use it.
func payloadEventName(for type: Any.Type) -> String {
    let typeName = String(describing: type)
    let baseTypeName = typeName.split(separator: ".").last.map(String.init) ?? typeName
    return baseTypeName.hasSuffix("Event") ? String(baseTypeName.dropLast(5)) : baseTypeName
}

/// The action naming rule: the type's name without its module, with an `Action` suffix dropped
/// (`AddGoldAction` → `AddGold`). The schema and an action type's `_payloadWireName` use it.
func payloadActionName(for type: Any.Type) -> String {
    let typeName = String(describing: type)
    let baseTypeName = typeName.split(separator: ".").last.map(String.init) ?? typeName
    return baseTypeName.hasSuffix("Action") ? String(baseTypeName.dropLast(6)) : baseTypeName
}

/// Thrown by the default `_writePayloadFields(into:)`: the type has no typed writer (no
/// `@Payload`). Registration refuses such a type where payloads are compressed (EV1).
public struct PayloadWithoutWriterError: Error, CustomStringConvertible {
    public let typeName: String
    public var description: String {
        "\(typeName) has no positional writer: add @Payload, or implement both _writePayloadFields(into:) and static var _payloadHasTypedWriter: Bool { true }"
    }
}

// MARK: - Leaves (core)

extension Bool: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.bool(self) }
}
extension Int: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.int(Int64(self)) }
}
extension Int8: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.int(Int64(self)) }
}
extension Int16: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.int(Int64(self)) }
}
extension Int32: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.int(Int64(self)) }
}
extension Int64: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.int(self) }
}
extension UInt: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.uint(UInt64(self)) }
}
extension UInt8: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.uint(UInt64(self)) }
}
extension UInt16: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.uint(UInt64(self)) }
}
extension UInt32: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.uint(UInt64(self)) }
}
extension UInt64: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.uint(self) }
}
extension Float: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.float(self) }
}
extension Double: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.double(self) }
}
extension String: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.string(self) }
}
extension PlayerID: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.string(rawValue) }
}
extension ClientID: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.string(rawValue) }
}
extension SessionID: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.string(rawValue) }
}
extension LandID: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) { writer.string(rawValue) }
}
