// expect: compiles
import SwiftStateTree

// A @Payload struct used only as another payload's field: @Payload alone makes it PlainData.
@Payload
struct Line: Codable, Sendable {
    let sku: String
    let count: Int
}

@Payload
struct OrderEvent: ServerEventPayload {
    let lines: [Line]
}

// An enum payload with @PlainData.
@PlainData
enum Signal: ServerEventPayload {
    case start
    case stop(reason: String)
}

// A resolver output with @PlainData.
@PlainData
struct QuoteOutput: ResolverOutput {
    let cents: Int64
}

// A payload nested in a generic type that stores no T: unconditionally PlainData.
struct Box<T> {
    @Payload
    struct InnerEvent: ServerEventPayload {
        let n: Int
    }
}

// A generic payload that declares its parameter PlainData.
@Payload
struct Tagged<T: Codable & Sendable & PlainData>: ServerEventPayload {
    let value: T
}

func requirePlainData<P: PlainData>(_: P.Type) {}

func uses() {
    requirePlainData(Line.self)
    requirePlainData(OrderEvent.self)
    requirePlainData(Signal.self)
    requirePlainData(QuoteOutput.self)
    requirePlainData(Box<NSObjectLike>.InnerEvent.self)
    requirePlainData(Tagged<Int>.self)
}

final class NSObjectLike {}
