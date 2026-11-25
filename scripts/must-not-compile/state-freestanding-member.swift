// expect-error: the PlainData check can't see the storage a macro expansion adds
import SwiftStateTree

// A freestanding declaration macro among the members (here the standard library's #warning) is
// refused, whether or not it adds storage: the check reads only the type's own syntax.
@StateNodeBuilder
struct FreestandingMemberState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    #warning("a member expansion")

    init() {}
}
