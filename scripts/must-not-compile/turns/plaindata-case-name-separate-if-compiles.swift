// expect: compiles
import SwiftStateTurns

// One case name in two separate `#if` blocks that never compile together (#797): each build
// declares it once, and its check runs under the block's condition.
@PlainData
enum Mode {
    #if SST_SNIPPET_FLAG
    case fast(Int)
    #endif
    #if !SST_SNIPPET_FLAG
    case fast(String)
    #endif
    case other
}
