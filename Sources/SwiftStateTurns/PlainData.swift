// "The machine's stored state is plain data", checked at compile time.

import Foundation

/// A value that can't call through to anything or change behind its holder: no class, closure,
/// actor, existential, lock or token, at any depth.
///
/// Conform with `@PlainData`, which checks every stored property (or associated value) of a
/// struct or enum. A hand-written conformance outside this module is refused by a lint.
public protocol PlainData {}

/// Writes the `PlainData` conformance and one check per stored property or associated value,
/// which fails to compile unless that type is `PlainData`. Every stored property needs a type
/// annotation; a generic type gets `where T: PlainData`; a class, actor or protocol is refused.
@attached(extension, conformances: PlainData, names: named(_plainDataCheck))
public macro PlainData() = #externalMacro(module: "SwiftStateTurnsMacros", type: "PlainDataMacro")

/// What the macro's checks call. Not for direct use.
public enum PlainDataCheck {
    @inlinable @inline(__always)
    public static func field<T: PlainData>(_: T.Type) {}
}

extension Bool: PlainData {}
extension Int: PlainData {}
extension Int8: PlainData {}
extension Int16: PlainData {}
extension Int32: PlainData {}
extension Int64: PlainData {}
extension UInt: PlainData {}
extension UInt8: PlainData {}
extension UInt16: PlainData {}
extension UInt32: PlainData {}
extension UInt64: PlainData {}
extension Double: PlainData {}
extension Float: PlainData {}
extension String: PlainData {}
extension Character: PlainData {}
extension Duration: PlainData {}
extension Data: PlainData {}
extension Never: PlainData {}
extension Optional: PlainData where Wrapped: PlainData {}
extension Array: PlainData where Element: PlainData {}
extension ContiguousArray: PlainData where Element: PlainData {}
extension Set: PlainData where Element: PlainData {}
extension Dictionary: PlainData where Key: PlainData, Value: PlainData {}
extension Result: PlainData where Success: PlainData, Failure: PlainData {}

extension InputID: PlainData {}
extension RequestID: PlainData {}
extension Generation: PlainData {}
extension TurnInstant: PlainData {}
extension Abandonment: PlainData {}
extension TurnError: PlainData {}

/// Two plain values as one, where a tuple would be stored (a tuple can't conform).
@frozen
public struct PlainPair<First: PlainData & Sendable & Hashable, Second: PlainData & Sendable & Hashable>:
    PlainData, Sendable, Hashable
{
    public var first: First
    public var second: Second

    @inlinable public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}
