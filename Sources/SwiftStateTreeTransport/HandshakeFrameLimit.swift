// Sources/SwiftStateTreeTransport/HandshakeFrameLimit.swift
//
// The bounds on what a session may send before its join is admitted. Until then the router
// decodes every frame as JSON, whatever the land's encoding, and the JSON object format's decode
// costs far more per element than the frame's size suggests (`AnyCodable`'s decode, #594):
// - a frame over `maxBytes` is refused before it is parsed, and the session closed with 1009
//   (Message Too Big). A join is a few hundred bytes;
// - a session whose pre-join frames are refused more than `maxRefusedFrames` times is closed
//   with 1008 (Policy Violation). The size limit bounds one frame's decode; this bounds how many
//   a connection gets. Connection-rate limiting stays the proxy's job.

import Foundation
import SwiftStateTree

public enum HandshakeFrameLimit {
    /// 8 KiB. The TypeScript SDK's join with every state-update feature declared and a
    /// metadata object is about 300 bytes.
    public static let defaultMaxBytes = 8 * 1024

    /// 8 refused pre-join frames per session; the next refused one closes it. A client sends
    /// one join, a few more only while another view's join on the same socket is in progress
    /// (`JOIN_IN_PROGRESS`), or when the app retries a refused join on the same socket.
    public static let defaultMaxRefusedFrames = 8

    /// `HANDSHAKE_REFUSED_FRAME_BUDGET`: refused pre-join frames a session may send, `nil` (no
    /// budget) when it is 0. A missing, negative or non-integer value gives
    /// `defaultMaxRefusedFrames`.
    public static func refusedFrameBudgetFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        let value = EnvHelpers.getEnvInt(
            key: TransportEnvKeys.handshakeRefusedFrameBudget,
            defaultValue: defaultMaxRefusedFrames,
            environment: environment
        )
        switch value {
        case 0: return nil
        case ..<0: return defaultMaxRefusedFrames
        default: return value
        }
    }

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
