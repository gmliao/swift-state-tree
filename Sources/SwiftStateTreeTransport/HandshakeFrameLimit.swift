// Sources/SwiftStateTreeTransport/HandshakeFrameLimit.swift
//
// The largest frame a session may send before its join completes. Until then the router decodes
// every frame as JSON, whatever the land's encoding, and the JSON object format's decode costs
// far more per element than the frame's size suggests (`AnyCodable`'s decode, #528). A join is a
// few hundred bytes, so a frame over the limit is refused before it is parsed, and the session
// is closed with 1009 (Message Too Big).

import Foundation
import SwiftStateTree

public enum HandshakeFrameLimit {
    /// 64 KiB. The TypeScript SDK's join with every state-update feature declared and a
    /// metadata object is about 300 bytes.
    public static let defaultMaxBytes = 64 * 1024

    /// `HANDSHAKE_FRAME_MAX_BYTES`: the limit in bytes, `nil` (no limit) when it is 0. A missing,
    /// negative or non-integer value gives `defaultMaxBytes`.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        let value = EnvHelpers.getEnvInt(
            key: TransportEnvKeys.handshakeFrameMaxBytes,
            defaultValue: defaultMaxBytes,
            environment: environment
        )
        switch value {
        case 0: return nil
        case ..<0: return defaultMaxBytes
        default: return value
        }
    }
}
