// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// The active block's case holds a class: allowing the name across separate blocks still checks
// the case its build declares (#797).
@PlainData
enum Mode {
    #if SST_SNIPPET_FLAG
    case fast(Int)
    #endif
    #if !SST_SNIPPET_FLAG
    case fast(Collaborator)
    #endif
}
