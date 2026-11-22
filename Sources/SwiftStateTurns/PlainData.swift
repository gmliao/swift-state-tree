// "The machine's stored state is plain data", checked at compile time.

import Foundation

/// A value that can't call through to anything or change behind its holder: no class, closure,
/// actor, existential, lock or token, at any depth.
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
/// annotation; a generic type gets `where T: PlainData`; a class, actor or protocol is refused.
@attached(extension, conformances: PlainData, names: named(_plainDataCheck))
public macro PlainData() = #externalMacro(module: "SwiftStateTurnsMacros", type: "PlainDataMacro")

/// What the macro's checks call. Not for direct use.
public enum PlainDataCheck {
    @inlinable @inline(__always)
    public static func field<T: PlainData>(_: T.Type) {}

    /// For a field `any P`: compiles only when `P` refines `PlainData`, because only then does
    /// `any P` convert to `any PlainData`. The value can't be a class: a class can't conform
    /// without `@PlainData`, which refuses one.
    @inlinable @inline(__always)
    public static func existential<E>(_: E.Type, _ upcast: (E) -> any PlainData) {}
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
        PlainDataCheck.field(First.self)
        PlainDataCheck.field(Second.self)
    }

    @inlinable public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}
