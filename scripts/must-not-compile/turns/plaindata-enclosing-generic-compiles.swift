// expect: compiles
import SwiftStateTurns

// A nested type's field of the parent's generic parameter: the conformance holds where the
// parameter is PlainData (#782). A nested type that doesn't name it stays unconditional.
struct Outer<T> {
    @PlainData
    struct Inner {
        var value: T
        var count: Int
    }

    @PlainData
    struct Counter {
        var n: Int
    }
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Outer<Int>.Inner.self)
    requirePlainData(Outer<NSObjectLike>.Counter.self)
}

final class NSObjectLike {}

// Exclusive `#if` clauses may each declare the same case.
@PlainData
enum Platformed {
    #if os(Linux)
    case item(count: Int)
    #else
    case item(label: String)
    #endif
}
