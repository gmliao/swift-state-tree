// expect-error: can't have willSet or didSet
import SwiftStateTree

// The generated mutators and the snapshot decode write a @Sync field's storage, so its observers
// would run on some writes only: refused. An observed @Internal field compiles.
@StateNodeBuilder
struct ObservedSyncState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0 { didSet {} }

    init() {}
}
