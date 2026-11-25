// expect-error: inside #if isn't synced
import SwiftStateTree

// The sync tables read only top-level members, so a @Sync field inside #if would never be
// synced: refused. An @Internal field there is fine.
@StateNodeBuilder
struct FlagState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0

    #if DEBUG
    @Sync(.broadcast)
    var debugCount: Int = 0
    #endif

    init() {}
}
