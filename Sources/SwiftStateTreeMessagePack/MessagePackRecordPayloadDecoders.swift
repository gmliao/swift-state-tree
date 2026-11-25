import Foundation
import SwiftStateTree

extension RecordPayloadDecoders {
    /// JSON and MessagePack: each recorded payload decodes with the decoder its encoding's
    /// transport uses live. A MessagePack payload is unpacked and decoded through
    /// `MessagePackPayloadSource`, the live path, which matches keys with `String ==` as live does.
    public static let standard = RecordPayloadDecoders(encodings: [.json, .messagepack]) { bytes, encoding in
        switch encoding {
        case .json:
            return try JSONRecordBytesSource(validating: bytes)
        case .messagepack:
            return try MessagePackPayloadSource(validating: unpack(bytes, maxDepth: PayloadNesting.clientFrameMaxDepth))
        }
    }
}
