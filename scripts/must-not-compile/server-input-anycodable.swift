// expect-error: this field's type isn't PlainData
import SwiftStateTree

// A server input holding an AnyCodable: a tree of any value isn't plain data.
@Payload
struct LooseInput: ServerInputPayload {
    let value: AnyCodable
}
