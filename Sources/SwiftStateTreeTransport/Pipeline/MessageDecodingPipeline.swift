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
        // Special handling for legacy join mode:
        // In legacy mode, join messages are always JSON (even if server is MessagePack-configured)
        // So we need to detect JSON format first before falling back to codec
        if enableLegacyJoin {
            // Try JSON detection first (for join handshake compatibility)
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let array = json as? [Any],
                   array.count >= 1,
                   let opcode = array[0] as? Int,
                   opcode >= 101 && opcode <= 106 {
                    // JSON opcode array format
                    return try opcodeDecoder.decode(from: data)
                } else {
                    // Standard JSON object format (includes Join messages)
                    return try JSONTransportCodec().decode(TransportMessage.self, from: data)
                }
            }
            // Not JSON, fall back to configured codec (MessagePack)
            return try codec.decode(TransportMessage.self, from: data)
        }
        
        // Non-legacy mode: use codec-first approach (for performance)
        if codec.encoding == .messagepack {
            return try codec.decode(TransportMessage.self, from: data)
        }
        
        // Detect JSON opcode array format
        if let json = try? JSONSerialization.jsonObject(with: data),
           let array = json as? [Any],
           array.count >= 1,
           let opcode = array[0] as? Int,
           opcode >= 101 && opcode <= 106 {
            return try opcodeDecoder.decode(from: data)
        }
        
        // Standard JSON object format
        return try codec.decode(TransportMessage.self, from: data)
    }
}
