import Foundation

/// A value synchronized as one unit: a change replaces the whole value, and wire formats that
/// support it send its leaves positionally, in `atomicLeafPaths` order.
///
/// Conform a type to declare it atomic; nothing else makes a value atomic (no shape or name
/// guessing). `@SnapshotConvertible(atomic: true)` generates the conformance from the stored
/// properties in declaration order. The leaf paths must equal the leaf paths of the type's schema
/// properties; `AtomicLayoutTable` checks this when it is built.
public protocol AtomicSnapshotValue: SnapshotValueConvertible {
    /// The value's leaf paths in wire order, e.g. Position2 → `[["v", "x"], ["v", "y"]]`.
    static var atomicLeafPaths: [[String]] { get }
}

/// Lets the schema converter see through `Optional<T>` where `T` is atomic.
package protocol OptionalAtomicSnapshotValue {
    static var wrappedAtomicType: any AtomicSnapshotValue.Type { get }
}

extension Optional: OptionalAtomicSnapshotValue where Wrapped: AtomicSnapshotValue {
    package static var wrappedAtomicType: any AtomicSnapshotValue.Type { Wrapped.self }
}

/// The atomic type declared by `type`, seeing through one `Optional`, or `nil`.
package func declaredAtomicType(_ type: Any.Type) -> (any AtomicSnapshotValue.Type)? {
    if let atomic = type as? any AtomicSnapshotValue.Type {
        return atomic
    }
    if let optional = type as? any OptionalAtomicSnapshotValue.Type {
        return optional.wrappedAtomicType
    }
    return nil
}

/// The leaf paths a stored property of type `type`, named `name`, contributes to an atomic value
/// (used by `@SnapshotConvertible(atomic: true)`): one leaf for a scalar, the type's own leaves,
/// prefixed, for a nested atomic value.
public func _atomicLeafPaths(of type: Any.Type, named name: String) -> [[String]] {
    if let atomic = type as? any AtomicSnapshotValue.Type {
        return atomic.atomicLeafPaths.map { [name] + $0 }
    }
    precondition(
        isAtomicScalar(type),
        "Atomic value property '\(name)' has type \(type), which is neither a scalar nor an AtomicSnapshotValue"
    )
    return [[name]]
}

private func isAtomicScalar(_ type: Any.Type) -> Bool {
    type == Int.self || type == Int8.self || type == Int16.self || type == Int32.self || type == Int64.self
        || type == UInt.self || type == UInt8.self || type == UInt16.self || type == UInt32.self || type == UInt64.self
        || type == Double.self || type == Float.self || type == Bool.self || type == String.self
}
