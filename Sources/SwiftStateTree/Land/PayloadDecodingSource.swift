import Foundation

/// A client input's payload as its decoder received it, decoded into its type when the keeper
/// takes it in (#521).
///
/// An `AnyCodable` tree (`AnyCodablePayloadSource`) decodes with today's JSON round trip; a
/// MessagePack value (`MessagePackPayloadSource`, in the MessagePack module) decodes straight into
/// the type, without the tree. Which one an input carries is fixed by the decoder that built its
/// envelope, so nothing tests a source's concrete type per input.
package protocol PayloadDecodingSource: Sendable {
    /// The payload as `type`.
    func decode<T: Decodable>(_ type: T.Type) throws -> T

    /// Throws where today's intake refuses the whole payload tree, declared fields or not: a
    /// non-finite number, which `JSONEncoder` refuses in the round trip (#521 §2.4). A map key that
    /// isn't a string is refused earlier, by the frame's decoder, as today.
    func validateRecordable() throws

    /// The payload as today's `AnyCodable` tree: for a record, and for the public `payload` and
    /// `action` properties. Built on each read, from what the decoder already refused, so it
    /// can't fail.
    var boxedPayload: AnyCodable { get }
}

extension PayloadDecodingSource {
    /// The tree a record holds: `validateRecordable()`, then `boxedPayload`.
    package func makeRecordPayload() throws -> AnyCodable {
        try validateRecordable()
        return boxedPayload
    }

    /// The payload as the action type a handler declares.
    package func decodeAction(_ type: any ActionPayload.Type) throws -> any ActionPayload {
        func open<A: ActionPayload>(_ type: A.Type) throws -> any ActionPayload {
            try decode(type)
        }
        return try open(type)
    }
}

/// A client event refused at intake because its payload doesn't decode into the registered type,
/// or holds what a record can't (#537). The adapter answers it with `eventInvalidPayload`.
package struct ClientEventPayloadError: Error, CustomStringConvertible {
    package let eventType: String
    package let underlying: any Error

    package var description: String { "Client event '\(eventType)' payload doesn't decode: \(underlying)" }
}

/// A payload held as an `AnyCodable` tree: what the JSON decoders build, what a record holds, and
/// what a hand-built envelope or event carries. It decodes with today's round trip
/// (`InboundPayloadDecoding`: the depth check, then `JSONEncoder` and `JSONDecoder`).
package struct AnyCodablePayloadSource: PayloadDecodingSource {
    package let payload: AnyCodable

    package init(_ payload: AnyCodable) {
        self.payload = payload
    }

    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try InboundPayloadDecoding.decode(type, from: payload, decoder: JSONDecoder())
    }

    /// Nothing to check before the decode: the round trip's `JSONEncoder` encodes the whole tree
    /// and refuses a non-finite number anywhere in it, as today.
    package func validateRecordable() throws {}

    package var boxedPayload: AnyCodable { payload }
}

/// A recorded payload, decoded with the codec that wrote its record (#521 PR 1b): the tree is
/// encoded with `CanonicalMessagePack` and the type decoded with its strict decoder, so a
/// `Date` reads from its ISO string and `Data`, `URL` and `Decimal` from their own `Codable`
/// forms, as the recorder wrote them. Both record sources hold trees in that form: a saved
/// record, and the JSON view, which is rendered from frames read back from the log.
///
/// A payload whose base is already the type (an in-process run's projected event) is taken as
/// is, without a round trip.
package struct RecordPayloadSource: PayloadDecodingSource {
    package let payload: AnyCodable
    /// The JSON view's one allowance: JSON doesn't keep the float/integer split, so an integer
    /// decodes into `Double` or `Float` when it converts exactly. False (strict) for a saved record.
    package let integralFloats: Bool

    package init(_ payload: AnyCodable, integralFloats: Bool = false) {
        self.payload = payload
        self.integralFloats = integralFloats
    }

    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if let typed = payload.base as? T { return typed }
        return try CanonicalMessagePack.decode(type, from: CanonicalMessagePack.encode(payload), integralFloats: integralFloats)
    }

    /// A recorded payload was checked when it was recorded.
    package func validateRecordable() throws {}

    package var boxedPayload: AnyCodable { payload }
}
