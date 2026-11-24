// expect: compiles
import SwiftStateTurns

// A nested type's field of the parent's generic parameter: the conformance holds where the
// parameter is PlainData (#782). A nested type whose stored values don't name it stays
// unconditional, even when a method does.
struct Outer<T> {
    @PlainData
    struct Inner {
        var value: T
        var count: Int
    }

    @PlainData
    struct Counter {
        var n: Int
        func identity(_ value: T) -> T { value }
        var none: T? { nil }
    }
}

// A keyword-named parameter keeps its backticks in the `where` clause.
struct Keyworded<`repeat`> {
    @PlainData
    struct Inner {
        var value: `repeat`
    }
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Outer<Int>.Inner.self)
    requirePlainData(Outer<NSObjectLike>.Counter.self)
    requirePlainData(Keyworded<Int>.Inner.self)
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
