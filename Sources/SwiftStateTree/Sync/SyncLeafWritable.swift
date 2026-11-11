import Foundation

/// A value the typed sync diff converts without `SnapshotValue.make(from: Any)` (#392, PR E):
/// a leaf of a row or a root field whose registration says its `convert` is the macro's
/// standard conversion (`SyncTableConversion.standard`). Behind `TYPED_LEAF_VALUES`.
///
/// **Contracts** (`SyncLeafWritableTests` checks every conformance against the macro's forms):
/// - `syncLeafSnapshot` is exactly the conversion `@StateNodeBuilder` emits for the type, in
///   both its forms: the direct one for a plain primitive spelling and `make(from:)` for any
///   other (a typealias, a generic parameter, an optional). It never throws.
/// - `syncLeafSame(a, b)` is `SnapshotValue.sameValue` of the two converted values: NaN equals
///   NaN, and a type whose `==` is finer than its snapshot (`LandID`) compares the snapshot's
///   content, not `==`.
package protocol SyncLeafWritable {
    var syncLeafSnapshot: SnapshotValue { get }
    static func syncLeafSame(_ lhs: Self, _ rhs: Self) -> Bool
}

/// A leaf whose `==` is exactly `sameValue` on its converted form.
package protocol SyncLeafWritableByEquality: SyncLeafWritable, Equatable {}

extension SyncLeafWritableByEquality {

    package static func syncLeafSame(_ lhs: Self, _ rhs: Self) -> Bool { lhs == rhs }
}

extension Bool: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .bool(self) }
}

extension Int: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(self) }
}

extension Int8: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension Int16: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension Int32: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension Int64: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension UInt8: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension UInt16: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

extension UInt32: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .int(Int(self)) }
}

// Above `Int.max` an unsigned value is its decimal digits (`SnapshotValue.unsigned`): still one
// representation per value, so `==` stays exact.
extension UInt: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { SnapshotValue.unsigned(self) }
}

extension UInt64: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { SnapshotValue.unsigned(self) }
}

extension Double: SyncLeafWritable {
    package var syncLeafSnapshot: SnapshotValue { .double(self) }
    /// `sameValue`: NaN equals NaN (`==` alone would send a set every sync).
    package static func syncLeafSame(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == rhs || (lhs.isNaN && rhs.isNaN)
    }
}

extension Float: SyncLeafWritable {
    /// Widened, as the macro writes a `Float` (`.double(Double(x))`).
    package var syncLeafSnapshot: SnapshotValue { .double(Double(self)) }
    package static func syncLeafSame(_ lhs: Float, _ rhs: Float) -> Bool {
        lhs == rhs || (lhs.isNaN && rhs.isNaN)
    }
}

// `sameValue` compares two `.string`s with `String ==` (canonical equivalence), as `==` does.
extension String: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .string(self) }
}

extension PlayerID: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .string(rawValue) }
}

extension ClientID: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .string(rawValue) }
}

extension SessionID: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .string(rawValue) }
}

extension LandID: SyncLeafWritable {
    package var syncLeafSnapshot: SnapshotValue { .string(rawValue) }
    /// The converted form: `("a", "b:c")` and `("a:b", "c")` are `!=` but write the same string.
    package static func syncLeafSame(_ lhs: LandID, _ rhs: LandID) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension Optional: SyncLeafWritable where Wrapped: SyncLeafWritable {
    /// `nil` is `null`, as `make(from: value as Any)` writes it.
    package var syncLeafSnapshot: SnapshotValue {
        switch self {
        case .some(let value): return value.syncLeafSnapshot
        case .none: return .null
        }
    }

    package static func syncLeafSame(_ lhs: Wrapped?, _ rhs: Wrapped?) -> Bool {
        switch (lhs, rhs) {
        case (.some(let a), .some(let b)): return Wrapped.syncLeafSame(a, b)
        case (.none, .none): return true
        default: return false
        }
    }
}

/// A registered leaf's typed conversion and change test, on the field's own type `V`.
struct SyncLeafAccess<V> {
    let snapshot: (V) -> SnapshotValue
    let same: (V, V) -> Bool
    /// The type has an atomic layout (`AtomicSnapshotValue`): the leaf form is one set only where
    /// the diff's layout node at the field is atomic.
    let needsAtomicLayout: Bool
}

/// `V`'s leaf access, when `V` is `SyncLeafWritable`.
func syncLeafAccess<V>(of type: V.Type) -> SyncLeafAccess<V>? {
    guard let writable = type as? any SyncLeafWritable.Type else { return nil }
    func open<W: SyncLeafWritable>(_: W.Type) -> SyncLeafAccess<V> {
        // `V` is `W`: the casts are the identity, on the static type (no existential box).
        SyncLeafAccess(
            snapshot: { unsafeBitCast($0, to: W.self).syncLeafSnapshot },
            same: { W.syncLeafSame(unsafeBitCast($0, to: W.self), unsafeBitCast($1, to: W.self)) },
            needsAtomicLayout: syncLeafIsAtomic(W.self)
        )
    }
    return open(writable)
}

/// Whether `type`, or the type an `Optional` wraps (at any depth), declares an atomic layout.
private func syncLeafIsAtomic(_ type: Any.Type) -> Bool {
    if type is any AtomicSnapshotValue.Type { return true }
    if let optional = type as? any SyncLeafOptionalType.Type { return syncLeafIsAtomic(optional.syncLeafWrappedType) }
    return false
}

private protocol SyncLeafOptionalType {
    static var syncLeafWrappedType: Any.Type { get }
}

extension Optional: SyncLeafOptionalType {
    fileprivate static var syncLeafWrappedType: Any.Type { Wrapped.self }
}
