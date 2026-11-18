import Foundation

/// Decodes a client-sent payload, an action's or a client event's `AnyCodable`, as its payload
/// type: the value is encoded back to JSON and decoded as the type.
///
/// The keeper's action paths and the land's client-event handlers call this, and so do the
/// decoder fuzz tests (#528), so the tests run the exact decode a client's bytes reach.
///
/// The re-encode recurses once per nesting level, so the payload's depth is checked first
/// (`PayloadNesting`, #362), whatever its source: a frame, a recorded action replayed. A
/// payload deeper than the limit throws `PayloadNesting.TooDeep` instead of exhausting the stack.
enum InboundPayloadDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable, decoder: JSONDecoder) throws -> T {
        try PayloadNesting.check(payload.base)
        let payloadData = try JSONEncoder().encode(payload)
        return try decoder.decode(type, from: payloadData)
    }
}
