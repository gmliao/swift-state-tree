// expect-error: a function type isn't plain data
import SwiftStateTree

// A resolver output with a closure: it could call through to anything.
@PlainData
struct CallbackOutput: ResolverOutput {
    let onDone: @Sendable () -> Void
}
