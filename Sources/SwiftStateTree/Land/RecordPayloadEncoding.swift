import Foundation

/// The encoding of a recorded client payload's bytes (#700 K1a): the bytes the live decoder for
/// that encoding read, so replay decodes them with the same decoder.
public enum RecordPayloadEncoding: String, Codable, Sendable, CaseIterable {
    /// JSON, decoded with `JSONDecoder`, as the JSON and opcode JSON transports decode a payload.
    case json
    /// MessagePack, decoded with the MessagePack transport's decoder (`SwiftStateTreeMessagePack`).
    case messagepack
}

extension RecordPayloadEncoding {
    /// The one JSON form a record writes for a payload: keys sorted and slashes unescaped, with
    /// `JSONEncoder`'s default number and data strategies, which are the live round trip's
    /// (`InboundPayloadDecoding`). `JSONDecoder` reads it to the value that round trip decodes:
    /// the order of an object's distinct keys doesn't change what `Decodable` reads. The bytes are
    /// fixed within one toolchain and platform; replay rests on decode equality, not on bytes
    /// across platforms (#700 plan §3.11).
    package static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// A client input's payload as a record keeps it (#700 K1a): the bytes, in the encoding of the
/// decoder that reads them.
package struct RecordedPayloadBytes: Sendable, Equatable {
    package let bytes: Data
    package let encoding: RecordPayloadEncoding

    package init(bytes: Data, encoding: RecordPayloadEncoding) {
        self.bytes = bytes
        self.encoding = encoding
    }

    /// The bytes of `source`'s own decoder (K1-Q8 (a)): canonical JSON for a tree, the canonical
    /// pack for a MessagePack value, whatever transport delivered it. A source with no client
    /// encoding gives its tree's canonical JSON.
    package init(of source: any PayloadDecodingSource) throws {
        if let encoding = source.recordEncoding {
            self.init(bytes: try source.recordBytes(), encoding: encoding)
        } else {
            self.init(bytes: try RecordPayloadEncoding.canonicalJSON(source.boxedPayload), encoding: .json)
        }
    }

    /// A typed value with no source (K1-Q8 (a)): its canonical JSON. The caller applies the value
    /// these bytes decode to, whether the land records or not, so a `Codable` that normalizes on
    /// decode applies the same value on both.
    package init<T: Encodable>(typed value: T) throws {
        self.init(bytes: try RecordPayloadEncoding.canonicalJSON(value), encoding: .json)
    }
}

/// A recorded payload's bytes, decoded with `JSONDecoder`: the decode a JSON transport's payload
/// gets live, without its `AnyCodable` tree.
package struct JSONRecordBytesSource: PayloadDecodingSource {
    package let bytes: Data

    /// Checks the nesting first, as a client's JSON frame is checked (#362): a record read from
    /// disk is as untrusted as a frame. Bytes that aren't JSON pass this check and fail at
    /// `decode`, so replay reports them at their input, not for the whole record.
    package init(validating bytes: Data) throws {
        try PayloadNesting.checkClientJSON(bytes)
        self.bytes = bytes
    }

    package func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: bytes)
    }

    /// The bytes were checked when they were recorded.
    package func validateRecordable() throws {}

    package var boxedPayload: AnyCodable {
        (try? JSONDecoder().decode(AnyCodable.self, from: bytes)) ?? AnyCodable(Optional<Int>.none)
    }

    package var recordEncoding: RecordPayloadEncoding? { .json }

    package func recordBytes() throws -> Data { bytes }
}

/// The decoders a replay uses for recorded client payloads, by the record's encoding (#700 K1a,
/// K1-Q6 (i)). `SwiftStateTree` has the JSON one; the MessagePack one is in
/// `SwiftStateTreeMessagePack` (`RecordPayloadDecoders.standard`), which depends on this module.
public struct RecordPayloadDecoders: Sendable {
    package let makeSource: @Sendable (Data, RecordPayloadEncoding) throws -> any PayloadDecodingSource

    /// The encodings these decoders read. A replay checks the record's header encoding against it
    /// before it applies any input, so a record in an encoding it has no decoder for is refused
    /// whole. Bytes that don't decode are another case: they fail at their own input, as a recorded
    /// payload that doesn't decode fails today (#700 plan §3.11, "Replay's decode failures").
    package let encodings: Set<RecordPayloadEncoding>

    package init(
        encodings: Set<RecordPayloadEncoding>,
        makeSource: @escaping @Sendable (Data, RecordPayloadEncoding) throws -> any PayloadDecodingSource
    ) {
        self.encodings = encodings
        self.makeSource = makeSource
    }

    /// Refuses a record whose header says `encoding` when these decoders don't read it.
    package func check(_ encoding: RecordPayloadEncoding) throws {
        guard encodings.contains(encoding) else { throw ReevaluationRecordPayloadError.noDecoder(encoding: encoding) }
    }

    /// JSON only. A record whose payloads are MessagePack is refused with
    /// `ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)`.
    public static let jsonOnly = RecordPayloadDecoders(encodings: [.json]) { bytes, encoding in
        switch encoding {
        case .json:
            return try JSONRecordBytesSource(validating: bytes)
        case .messagepack:
            throw ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)
        }
    }
}

/// A replay that can't decode a record's payloads.
public enum ReevaluationRecordPayloadError: Error, Equatable, CustomStringConvertible {
    /// The record's payloads are in `encoding`, and the replay's `RecordPayloadDecoders` has no
    /// decoder for it.
    case noDecoder(encoding: RecordPayloadEncoding)

    public var description: String {
        switch self {
        case .noDecoder(let encoding):
            switch encoding {
            case .messagepack:
                return "this record's payloads are MessagePack, and this replay has no MessagePack decoder: pass `RecordPayloadDecoders.standard` (SwiftStateTreeMessagePack)"
            case .json:
                return "this record's payloads are JSON, and this replay has no JSON decoder"
            }
        }
    }
}
