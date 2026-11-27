// expect-error: ambiguous use of 'fast'
import SwiftStateTurns

// Two separate blocks that are both active declare one case name twice (#797). The macro can't
// evaluate the conditions, so it allows the name; the build fails in the expansion's check,
// which can't pick one of the two cases. Never a build with a case left unchecked.
@PlainData
enum Mode {
    #if compiler(>=5.0)
    case fast(count: Int)
    #endif
    #if compiler(>=5.0)
    case fast(label: String)
    #endif
}
