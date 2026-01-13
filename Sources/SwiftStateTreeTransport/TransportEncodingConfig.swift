import SwiftStateTree

/// Defines the encoding combination used by the transport layer.
public struct TransportEncodingConfig: Sendable {
    public let message: TransportEncoding
    public let stateUpdate: StateUpdateEncoding

    public init(
        message: TransportEncoding = .json,
        stateUpdate: StateUpdateEncoding = .opcodeJsonArray
    ) {
        self.message = message
        self.stateUpdate = stateUpdate
    }

    public static let json = TransportEncodingConfig(
        message: .json,
        stateUpdate: .jsonObject
    )
    public static let jsonOpcode = TransportEncodingConfig(
        message: .json,
        stateUpdate: .opcodeJsonArray
    )

    public func makeCodec() -> any TransportCodec {
        message.makeCodec()
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
        case .opcodeJsonArrayLegacy:
            // Explicitly force legacy mode (no PathHasher)
            return OpcodeJSONStateUpdateEncoder()
        }
    }
}
