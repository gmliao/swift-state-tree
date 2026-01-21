import SwiftStateTree

/// Defines the encoding combination used by the transport layer.
public struct TransportEncodingConfig: Sendable {
    public let message: TransportEncoding
    public let stateUpdate: StateUpdateEncoding
    
    /// Automatically determine if payload should be encoded as an array (compressed format) instead of an object.
    /// - Returns: true if message encoding is .opcodeJsonArray or .messagepack
    var shouldEncodePayloadAsArray: Bool {
        switch message {
        case .opcodeJsonArray, .messagepack:
            return true
        default:
            return false
        }
    }

    public init(
        message: TransportEncoding = .json,
        stateUpdate: StateUpdateEncoding = .opcodeJsonArray
    ) {
        self.message = message
        self.stateUpdate = stateUpdate
    }

    /// JSON mode: human-readable JSON object format for both messages and state updates
    /// - JOIN: JSON Object format (protocol requirement)
    /// - Post-JOIN messages: JSON Object format (e.g., {"kind": "action", "payload": {...}})
    /// - State updates: JSON Object (full JSON patches)
    /// - Compression: disabled (JSON text doesn't compress well)
    /// - Use case: debugging, development, maximum compatibility
    public static let json = TransportEncodingConfig(
        message: .json,
        stateUpdate: .jsonObject
    )
    
    /// Hybrid mode: JSON messages with opcode state updates
    /// - JOIN: JSON Object format (protocol requirement)
    /// - Post-JOIN messages: JSON Object format (readable action/event messages)
    /// - State updates: Opcode JSON Array (compact state patches with path hashing)
    /// - Compression: disabled for messages (JSON), enabled for state (opcode)
    /// - Use case: debugging messages while optimizing state sync, gradual migration
    public static let jsonOpcode = TransportEncodingConfig(
        message: .json,
        stateUpdate: .opcodeJsonArray
    )
    
    /// Opcode JSON Array mode: compact JSON array format for both messages and state updates
    /// - JOIN: JSON Object format (protocol requirement)
    /// - Post-JOIN messages: JSON Array format (e.g., [101, requestID, ...])
    /// - State updates: Opcode JSON Array (compact state patches)
    /// - Compression: enabled (array format compresses well)
    public static let opcode = TransportEncodingConfig(
        message: .opcodeJsonArray,
        stateUpdate: .opcodeJsonArray
    )
    
    /// MessagePack mode: binary encoding for both messages and state updates
    /// - JOIN: JSON Object format (protocol requirement)
    /// - Post-JOIN messages: MessagePack binary format
    /// - State updates: Opcode MessagePack (opcode array structure in MessagePack binary)
    /// - Compression: enabled (binary format compresses very well)
    public static let messagepack = TransportEncodingConfig(
        message: .messagepack,
        stateUpdate: .opcodeMessagePack
    )

    public func makeCodec() -> any TransportCodec {
        message.makeCodec()
    }

    public func makeMessageEncoder(
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil
    ) -> any TransportMessageEncoder {
        message.makeMessageEncoder(
            eventHashes: eventHashes,
            clientEventHashes: clientEventHashes,
            enablePayloadCompression: shouldEncodePayloadAsArray
        )
    }

    public func makeStateUpdateEncoder(pathHashes: [String: UInt32]? = nil) -> any StateUpdateEncoder {
        stateUpdate.makeEncoder(pathHashes: pathHashes)
    }
}

public extension StateUpdateEncoding {
    func makeEncoder(pathHashes: [String: UInt32]? = nil) -> any StateUpdateEncoder {
        switch self {
        case .jsonObject:
            return JSONStateUpdateEncoder()
        case .opcodeJsonArray:
            // Validate configuration: opcodeJsonArray should have pathHashes for compression
            if pathHashes == nil {
                // Log warning (using print as we don't have logger context here)
                print("⚠️ WARNING: opcodeJsonArray encoding is configured but pathHashes is nil.")
                print("   This will fall back to Legacy format (no PathHash compression).")
                print("   To enable full compression, provide pathHashes from your Land schema:")
                print("   Example: pathHashes: YourLand.schema.pathHashes")
            }
            
            // Create PathHasher if pathHashes available
            if let pathHashes = pathHashes {
                let pathHasher = PathHasher(pathHashes: pathHashes)
                return OpcodeJSONStateUpdateEncoder(pathHasher: pathHasher)
            }
            return OpcodeJSONStateUpdateEncoder()
        case .opcodeMessagePack:
            // Validate configuration: opcodeMessagePack should have pathHashes for compression (optional)
            if pathHashes == nil {
                print("⚠️ WARNING: opcodeMessagePack encoding is configured but pathHashes is nil.")
                print("   This will use Legacy format (no PathHash compression).")
                print("   To enable full compression, provide pathHashes from your Land schema.")
            }
            if let pathHashes = pathHashes {
                let pathHasher = PathHasher(pathHashes: pathHashes)
                return OpcodeMessagePackStateUpdateEncoder(pathHasher: pathHasher)
            }
            return OpcodeMessagePackStateUpdateEncoder()
        case .opcodeJsonArrayLegacy:
            // Explicitly force legacy mode (no PathHasher)
            return OpcodeJSONStateUpdateEncoder()
        }
    }
}
