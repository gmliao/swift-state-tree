import SwiftStateTree

/// Defines the encoding combination used by the transport layer.
public struct TransportEncodingConfig: Sendable {
    public let message: TransportEncoding
    public let stateUpdate: StateUpdateEncoding

    public init(
        message: TransportEncoding = .json,
        stateUpdate: StateUpdateEncoding = .jsonObject
    ) {
        self.message = message
        self.stateUpdate = stateUpdate
    }

    public static let json = TransportEncodingConfig()
    public static let jsonOpcode = TransportEncodingConfig(
        message: .json,
        stateUpdate: .opcodeJsonArray
    )

    public func makeCodec() -> any TransportCodec {
        message.makeCodec()
    }

    public func makeStateUpdateEncoder() -> any StateUpdateEncoder {
        stateUpdate.makeEncoder()
    }
}

public extension StateUpdateEncoding {
    func makeEncoder() -> any StateUpdateEncoder {
        switch self {
        case .jsonObject:
            return JSONStateUpdateEncoder()
        case .opcodeJsonArray:
            return OpcodeJSONStateUpdateEncoder()
        }
    }
}
