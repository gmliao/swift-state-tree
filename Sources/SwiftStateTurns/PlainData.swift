// "The machine's stored state is plain data", checked at compile time.

import Foundation

/// A value that can't call through to anything or change behind its holder: no class, closure,
/// actor, lock or token, at any depth, and no existential but one: a field of a `@PlainData`
/// type may be `any P` where `P` refines `PlainData` (also as the element of an optional, an
/// array or a dictionary's value), which the macro checks per field. `any P` itself doesn't
/// conform, so a `where T: PlainData` generic refuses it.
///
/// Conform with `@PlainData`, which checks every stored property (or associated value) of a
/// struct or enum. The checks are its one requirement, so a type that conforms without the
/// macro, through a protocol that refines `PlainData` or by hand, doesn't compile unless it
/// writes them itself; outside this module the lint refuses that, and a hand-written
/// conformance.
public protocol PlainData {
    /// The macro's field checks: compiled, never called. Write it with `@PlainData`, not by hand.
    static func _plainDataCheck()
}

/// Writes the `PlainData` conformance and one check per stored property or associated value,
/// which fails to compile unless that type is `PlainData`. Every stored property needs a type
/// annotation; a generic type gets `where T: PlainData` for each parameter a stored value names
/// (one stored nowhere adds no condition); a class, actor or protocol is refused.
@attached(extension, conformances: PlainData, names: named(_plainDataCheck))
public macro PlainData() = #externalMacro(module: "SwiftStateTurnsMacros", type: "PlainDataMacro")

/// What the macro's checks call. Not for direct use. Each takes a stored value, so it checks the
/// type the value has, wherever the spelled type's name would resolve.
public enum PlainDataCheck {
    /// Compiles only when the value's type is `PlainData`.
    @inlinable @inline(__always)
    public static func field<T: PlainData>(_: T) {}

    /// Chosen only when the constrained overload doesn't apply, so its message is the error for a
    /// field whose type isn't `PlainData`, on the expansion's line that names the field.
    @available(*, unavailable, message: "this field's type isn't PlainData: add @PlainData to your struct or enum; a class, closure or Any can't be stored; an existential `any P` (P refining PlainData) inside Optional, Array, ContiguousArray or a Dictionary's value must be spelled `any P` where the field is declared, not through an alias")
    public static func field<T>(_: T) {}

    /// For a value `any P`: compiles only when `P` refines `PlainData`, because only then does
    /// `any P` convert to `any PlainData`. A class conforming through `P` still has to provide
    /// `_plainDataCheck`, which `@PlainData` refuses to write for a class; written by hand, the
    /// compiler accepts it, and only this repository's lint refuses it.
    @inlinable @inline(__always)
    public static func existential(_: any PlainData) {}

    // A wrapper spelled `Array<…>` (or `Optional`, `ContiguousArray`, `Dictionary`), bare,
    // `Swift.`-qualified or as sugar, around an existential: each helper takes the standard
    // library's type, named here where the user's module can't rebind `Swift` or the type's
    // name, and passes its elements to the closure, which checks them. A namesake or an alias to
    // another type doesn't compile.

    /// Compiles only for the standard library's `Optional`.
    @inlinable @inline(__always)
    public static func optional<Wrapped>(_: Swift.Optional<Wrapped>, _: (Wrapped) -> Void) {}

    /// Compiles only for the standard library's `Array`.
    @inlinable @inline(__always)
    public static func array<Element>(_: Swift.Array<Element>, _: (Element) -> Void) {}

    /// Compiles only for the standard library's `ContiguousArray`.
    @inlinable @inline(__always)
    public static func contiguousArray<Element>(_: Swift.ContiguousArray<Element>, _: (Element) -> Void) {}

    /// Compiles only for the standard library's `Dictionary`.
    @inlinable @inline(__always)
    public static func dictionary<Key, Value>(_: Swift.Dictionary<Key, Value>, _: (Key, Value) -> Void) {}
}

extension Bool: PlainData { public static func _plainDataCheck() {} }
extension Int: PlainData { public static func _plainDataCheck() {} }
extension Int8: PlainData { public static func _plainDataCheck() {} }
extension Int16: PlainData { public static func _plainDataCheck() {} }
extension Int32: PlainData { public static func _plainDataCheck() {} }
extension Int64: PlainData { public static func _plainDataCheck() {} }
extension UInt: PlainData { public static func _plainDataCheck() {} }
extension UInt8: PlainData { public static func _plainDataCheck() {} }
extension UInt16: PlainData { public static func _plainDataCheck() {} }
extension UInt32: PlainData { public static func _plainDataCheck() {} }
extension UInt64: PlainData { public static func _plainDataCheck() {} }
extension Double: PlainData { public static func _plainDataCheck() {} }
extension Float: PlainData { public static func _plainDataCheck() {} }
extension String: PlainData { public static func _plainDataCheck() {} }
extension Character: PlainData { public static func _plainDataCheck() {} }
extension Duration: PlainData { public static func _plainDataCheck() {} }
extension Data: PlainData { public static func _plainDataCheck() {} }
extension Never: PlainData { public static func _plainDataCheck() {} }
extension Optional: PlainData where Wrapped: PlainData { public static func _plainDataCheck() {} }
extension Array: PlainData where Element: PlainData { public static func _plainDataCheck() {} }
extension ContiguousArray: PlainData where Element: PlainData { public static func _plainDataCheck() {} }
extension Set: PlainData where Element: PlainData { public static func _plainDataCheck() {} }
extension Dictionary: PlainData where Key: PlainData, Value: PlainData { public static func _plainDataCheck() {} }
extension Result: PlainData where Success: PlainData, Failure: PlainData { public static func _plainDataCheck() {} }

extension InputID: PlainData { public static func _plainDataCheck() {} }
extension RequestID: PlainData { public static func _plainDataCheck() {} }
extension Generation: PlainData { public static func _plainDataCheck() {} }
extension TurnInstant: PlainData { public static func _plainDataCheck() {} }
extension Abandonment: PlainData { public static func _plainDataCheck() {} }
extension TurnError: PlainData { public static func _plainDataCheck() {} }

/// Two plain values as one, where a tuple would be stored (a tuple can't conform).
@frozen
public struct PlainPair<First: PlainData & Sendable & Hashable, Second: PlainData & Sendable & Hashable>:
    PlainData, Sendable, Hashable
{
    public var first: First
    public var second: Second

    public static func _plainDataCheck() {
        func check(_ value: Self) {
            PlainDataCheck.field(value.first)
            PlainDataCheck.field(value.second)
        }
    }

    @inlinable public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}
