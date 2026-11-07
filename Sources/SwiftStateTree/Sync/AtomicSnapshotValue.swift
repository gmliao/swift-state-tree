import Foundation

/// A value synchronized as one unit: a change replaces the whole value, and wire formats that
/// support it send its leaves positionally, in `atomicLeafPaths` order.
///
/// Conform a type to declare it atomic; nothing else makes a value atomic (no shape or name
/// guessing). `@SnapshotConvertible(atomic: true)` generates the conformance from the stored
/// properties in declaration order. The leaf paths must equal the leaf paths of the type's schema
/// properties; `AtomicLayoutTable` checks this when it is built, against the type's own field
/// metadata (so the check needs no sample instance, and holds for a type that isn't `Codable`).
public protocol AtomicSnapshotValue: SnapshotValueConvertible, SchemaMetadataProvider {
    /// The value's leaf paths in wire order, e.g. Position2 → `[["v", "x"], ["v", "y"]]`.
    static var atomicLeafPaths: [[String]] { get }
}

/// Lets the schema converter see through `Optional<T>`.
package protocol OptionalTypeProbe {
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalTypeProbe {
    package static var wrappedType: Any.Type { Wrapped.self }
}

/// The atomic type declared by `type`, seeing through one `Optional`, or `nil`.
package func declaredAtomicType(_ type: Any.Type) -> (any AtomicSnapshotValue.Type)? {
    if let atomic = type as? any AtomicSnapshotValue.Type {
        return atomic
    }
    if let optional = type as? any OptionalTypeProbe.Type {
        return optional.wrappedType as? any AtomicSnapshotValue.Type
    }
    return nil
}

/// A scalar that can be a leaf of an atomic value: the integer types, `Double`, `Float`, `Bool`
/// and `String`. `@SnapshotConvertible(atomic: true)` accepts only these and atomic values as
/// property types, so the compiler rejects an optional or a collection, however it is spelled.
public protocol AtomicScalarLeaf {}

extension Int: AtomicScalarLeaf {}
extension Int8: AtomicScalarLeaf {}
extension Int16: AtomicScalarLeaf {}
extension Int32: AtomicScalarLeaf {}
extension Int64: AtomicScalarLeaf {}
extension UInt: AtomicScalarLeaf {}
extension UInt8: AtomicScalarLeaf {}
extension UInt16: AtomicScalarLeaf {}
extension UInt32: AtomicScalarLeaf {}
extension UInt64: AtomicScalarLeaf {}
extension Double: AtomicScalarLeaf {}
extension Float: AtomicScalarLeaf {}
extension Bool: AtomicScalarLeaf {}
extension String: AtomicScalarLeaf {}

/// The leaf paths of a nested atomic property `name` (used by `@SnapshotConvertible(atomic: true)`):
/// the type's own leaves, prefixed.
public func _atomicLeafPaths<T: AtomicSnapshotValue>(of type: T.Type, named name: String) -> [[String]] {
    type.atomicLeafPaths.map { [name] + $0 }
}

/// The leaf path of a scalar property `name` (used by `@SnapshotConvertible(atomic: true)`).
public func _atomicLeafPaths<T: AtomicScalarLeaf>(of type: T.Type, named name: String) -> [[String]] {
    [[name]]
}
