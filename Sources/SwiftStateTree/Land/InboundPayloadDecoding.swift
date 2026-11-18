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
/// A payload whose frame was bounded at decode (`DepthBounded`) is already no deeper than that,
/// and isn't walked again: each live input is checked once, by its frame's decode.
enum InboundPayloadDecoding {
    /// Told, by the overload that ran, whether the payload was walked (`true`) or came with its
    /// bound (`false`): the keeper counts its live decodes with it (`livePayloadDecodesForTesting`).
    typealias Observer = (_ walked: Bool) -> Void

    static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable, decoder: JSONDecoder, observe: Observer? = nil) throws -> T {
        observe?(true)
        try PayloadNesting.check(payload.base)
        return try reencoded(type, from: payload, decoder: decoder)
    }

    /// A payload from a frame its decoder bounded (`DepthBounded`): no deeper than the client
    /// limit already, so it isn't walked again.
    static func decode<T: Decodable>(_ type: T.Type, from payload: DepthBounded<AnyCodable>, decoder: JSONDecoder, observe: Observer? = nil) throws -> T {
        observe?(false)
        return try reencoded(type, from: payload.value, decoder: decoder)
    }

    /// Walks `payload` (`decode(_:from:decoder:)`) unless it comes with its bound.
    static func decode<T: Decodable>(_ type: T.Type, from payload: AnyCodable, bounded: DepthBounded<AnyCodable>?, decoder: JSONDecoder, observe: Observer? = nil) throws -> T {
        if let bounded {
            return try decode(type, from: bounded, decoder: decoder, observe: observe)
        }
        return try decode(type, from: payload, decoder: decoder, observe: observe)
    }

    private static func reencoded<T: Decodable>(_ type: T.Type, from payload: AnyCodable, decoder: JSONDecoder) throws -> T {
        let payloadData = try JSONEncoder().encode(payload)
        return try decoder.decode(type, from: payloadData)
    }
}
