// expect: compiles
import SwiftStateTurns

// A field whose type is a sibling nested in the same outer type: the file-scope extension can't
// name `Sibling` unqualified, and the check doesn't need to, since it reads the value.
enum Outer {
    @PlainData
    struct Sibling {
        var n: Int
    }

    protocol Payload: PlainData {}

    @PlainData
    struct Inner {
        var sibling: Sibling
        var siblings: [String: Sibling]
        var payload: (any Payload)?
    }
}

// Private and lazy stored properties are read from the extension like any other.
@PlainData
struct Hidden {
    private var secret: Int = 0
    lazy var cached: [Int] = []
}

// A deprecated field and case are read inside the deprecated `check`, without a warning.
@PlainData
struct Legacy {
    @available(*, deprecated) var old: Int
}

@PlainData
enum LegacyCase {
    case current(Int)
    @available(*, deprecated) case old(String)
}
