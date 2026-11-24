// expect-error: 'any Outer.Payload'
import SwiftStateTurns

// The same with an existential: at file scope `Payload` refines PlainData, but the field's is the
// nested protocol, which doesn't, so a class can stand behind it.
protocol Payload: PlainData {}

enum Outer {
    protocol Payload {}
    final class Ref: Payload {}

    @PlainData
    struct Inner {
        var item: any Payload
    }
}
