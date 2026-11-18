import Foundation
import SwiftStateTree

/// Pipeline component for detecting and decoding transport messages.
///
/// This component centralizes all message decoding logic, supporting multiple encoding formats:
/// - JSON object format (standard)
/// - JSON opcode array format
/// - MessagePack format
///
/// **Special Handling for Join Messages**:
/// In legacy mode (`enableLegacyJoin = true`), join messages are always JSON (even if server
/// is configured for MessagePack). This ensures backward compatibility with the join handshake protocol.
///
/// **Performance**: This is a value type (struct) with zero allocation overhead. All logic remains
/// within TransportAdapter's actor isolation domain (no actor hopping).
/// A client frame as the adapter's pipeline decoded it: with the proof of its depth bound
/// (`DepthBounded`) when the decode enforced `PayloadNesting.clientFrameMaxDepth` on the whole
/// frame, so the payload decode after it doesn't walk the payload again (#362).
enum DecodedClientFrame: Sendable {
    /// Checked at the client limit: a JSON frame's byte scan, or this module's MessagePack codec,
    /// which unpacks at the limit.
    case bounded(DepthBounded<TransportMessage>)
    /// Decoded by a codec this module doesn't know to bound its unpacking: its payloads are
    /// walked.
    case unchecked(TransportMessage)

    var message: TransportMessage {
        switch self {
        case .bounded(let bounded): return bounded.value
        case .unchecked(let message): return message
        }
    }

    var bounded: DepthBounded<TransportMessage>? {
        if case .bounded(let bounded) = self { return bounded }
        return nil
    }
}

struct MessageDecodingPipeline: Sendable {
    let codec: any TransportCodec
    let opcodeDecoder: OpcodeTransportMessageDecoder
    let enableLegacyJoin: Bool
    
    /// Decode raw data into TransportMessage.
    ///
    /// **Decoding Priority**:
    /// - Legacy mode: JSON-first (for join handshake compatibility)
    /// - Non-legacy mode: Codec-first (for performance)
    ///
    /// - Parameter data: Raw message data
    /// - Returns: Decoded TransportMessage
    /// - Throws: Decoding errors if data cannot be parsed
    func decode(_ data: Data) throws -> TransportMessage {
        try decodeClientFrame(data).message
    }

    /// `decode`, with the frame's depth bound when the decode enforced it (`DecodedClientFrame`).
    ///
    /// The proof is granted only where this module's own code bounded these exact bytes at the
    /// client limit (#362, review of #616): a JSON frame that `checkClientJSON` scanned and this
    /// module's decoder parsed (`OpcodeTransportMessageDecoder`, `JSONTransportCodec`), or a
    /// MessagePack frame that `MessagePackTransportCodec` unpacked. Anything else, another
    /// module's codec or a frame the scan didn't read, is `.unchecked`, and its payloads are walked.
    ///
    /// The `scanned` half of the JSON condition is defensive: this module's JSON decoders parse no
    /// frame the scan skips (it reads past a BOM and whitespace to the `[` or `{`, and a top-level
    /// scalar isn't a `TransportMessage`), so no test can tell it from its removal. It keeps the
    /// rule true if either changes. The codec half is tested (`BoundedPayloadDecodeTests`).
    func decodeClientFrame(_ data: Data) throws -> DecodedClientFrame {
        // Special handling for legacy join mode:
        // In legacy mode, join messages are always JSON (even if server is MessagePack-configured)
        // So we need to detect JSON format first before falling back to codec
        if enableLegacyJoin {
            // Any frame may reach the JSON parser first, so every one is checked before it
            // (#362); the decodes below don't check again, except MessagePack's unpack.
            let scanned = try PayloadNesting.checkClientJSON(data)
            // Try JSON detection first (for join handshake compatibility)
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let array = json as? [Any],
                   array.count >= 1,
                   let opcode = array[0] as? Int,
                   opcode >= 101 && opcode <= 106 {
                    // JSON opcode array format
                    return Self.proven(try opcodeDecoder.decode(from: data), if: scanned)
                } else {
                    // Standard JSON object format (includes Join messages)
                    return Self.proven(try JSONTransportCodec().decode(TransportMessage.self, from: data), if: scanned)
                }
            }
            // Not JSON to Foundation: the configured codec decodes it. Its scan above (if any)
            // doesn't cover what another module's decoder reads, so only this module's decoders
            // get the proof.
            if codec.encoding == .messagepack {
                return try decodeMessagePack(data)
            }
            return Self.proven(try codec.decode(TransportMessage.self, from: data), if: scanned && codec is JSONTransportCodec)
        }
        
        // Non-legacy mode: use codec-first approach (for performance)
        if codec.encoding == .messagepack {
            return try decodeMessagePack(data)
        }

        // Checked before this decode parses it (#362); the decodes below don't check again.
        let scanned = try PayloadNesting.checkClientJSON(data)
        
        // Detect JSON opcode array format
        if let json = try? JSONSerialization.jsonObject(with: data),
           let array = json as? [Any],
           array.count >= 1,
           let opcode = array[0] as? Int,
           opcode >= 101 && opcode <= 106 {
            return Self.proven(try opcodeDecoder.decode(from: data), if: scanned)
        }
        
        // Standard JSON object format
        return Self.proven(try codec.decode(TransportMessage.self, from: data), if: scanned && codec is JSONTransportCodec)
    }

    /// `.bounded` when `bounded` (this module's code bounded the bytes `message` came from),
    /// else `.unchecked`.
    private static func proven(_ message: TransportMessage, if bounded: Bool) -> DecodedClientFrame {
        bounded ? .bounded(DepthBounded(decodedFromBoundedFrame: message)) : .unchecked(message)
    }
        
    /// A MessagePack frame: bounded only when this module's codec unpacked it, at the client
    /// limit. Another module's codec may not bound its unpacking (`decodeClientFrame`'s default
    /// doesn't for MessagePack), so its payloads are walked.
    private func decodeMessagePack(_ data: Data) throws -> DecodedClientFrame {
        let message = try codec.decodeClientFrame(TransportMessage.self, from: data)
        return Self.proven(message, if: codec is MessagePackTransportCodec)
    }
}
