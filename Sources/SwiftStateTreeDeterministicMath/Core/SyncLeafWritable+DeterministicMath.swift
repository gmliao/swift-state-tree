import SwiftStateTree

// The atomic types' typed leaf forms for the typed sync diff (`SyncLeafWritable`, #392 PR E).
// Each is exactly the type's `toSnapshotValue()`, built without `SnapshotValue.make(from: Any)`:
// `IVec2`/`IVec3` as their hand-written conversion, and the `@SnapshotConvertible(atomic: true)`
// types as the macro writes them (`Int32` fields as `.int(Int(x))`, an `IVec2` field through
// `make(from:)`, which takes its `toSnapshotValue()`). Their leaves are integers, so `==` is
// `sameValue` on the converted form. `SyncLeafWritableTests` pins every one.

extension IVec2: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue {
        .object(["x": .int(Int(x)), "y": .int(Int(y))])
    }
}

extension IVec3: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue {
        .object(["x": .int(Int(x)), "y": .int(Int(y)), "z": .int(Int(z))])
    }
}

extension Position2: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .object(["v": v.syncLeafSnapshot]) }
}

extension Velocity2: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .object(["v": v.syncLeafSnapshot]) }
}

extension Acceleration2: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .object(["v": v.syncLeafSnapshot]) }
}

extension Angle: SyncLeafWritableByEquality {
    package var syncLeafSnapshot: SnapshotValue { .object(["degrees": .int(Int(degrees))]) }
}
