// Sources/SwiftStateTreeNIO/SendBacklogBound.swift
//
// The send backlog bound (#61 step 3, option A): a memory bound for a client that doesn't
// drain, like Redis's hard `client-output-buffer-limit`. Over it, the session is closed with
// 4008 and the client rebuilds from its next join's firstSync.

import Foundation
import Logging
import NIOCore
import NIOWebSocket
import SwiftStateTree

/// When a WebSocket session's outbound backlog closes it. 0 disables a bound.
public struct SendBacklogBound: Equatable, Sendable {
    /// Close when the channel's outbound buffer (`bufferedWritableBytes`) holds more than this
    /// while the channel is unwritable. It is checked where the backlog is sampled: when the
    /// channel turns unwritable and after each write while it stays so. So it only acts above
    /// the channel's high watermark. 0 disables it.
    public var maxBytes: Int
    /// Close when the channel stays unwritable for longer than this (a timer from the start of
    /// the unwritable episode, cancelled when the channel turns writable or the session ends).
    /// `.zero` disables it.
    public var maxUnwritable: TimeAmount

    public init(maxBytes: Int, maxUnwritable: TimeAmount) {
        self.maxBytes = max(0, maxBytes)
        self.maxUnwritable = max(.zero, maxUnwritable)
    }

    /// 8 MiB or 30 s.
    public static let `default` = SendBacklogBound(maxBytes: 8 << 20, maxUnwritable: .seconds(30))
    /// No bound.
    public static let disabled = SendBacklogBound(maxBytes: 0, maxUnwritable: .zero)

    /// The close code: 4008, in the application range (4000–4999).
    public static let closeCode = WebSocketErrorCode.unknown(4008)
}

/// Which bound closed a session, with the value that broke it.
public enum SendBacklogBreach: Equatable, Sendable {
    /// The outbound buffer held this many bytes.
    case bytes(Int)
    /// The channel was unwritable this long.
    case unwritable(TimeAmount)
}

extension NIOWebSocketServerConfiguration {
    /// The bound from `WS_SEND_BACKLOG_MAX_BYTES` and `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`:
    /// whole numbers, 0 or above, 0 disabling that bound. A missing or invalid value gives that
    /// bound's default; a value that is set but invalid is logged at warning level, once per
    /// process.
    public static func sendBacklogBound(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SendBacklogBound {
        let rejected = rejectedSendBacklogKeys(environment: environment)
        if !rejected.isEmpty, rejectedSendBacklogWarning.claim() {
            Logger(label: "com.swiftstatetree.nio").warning(
                "Send backlog bound env value is not a whole number of 0 or above; using the default",
                metadata: [
                    "keys": .string(rejected.joined(separator: ",")),
                    "defaultMaxBytes": .stringConvertible(SendBacklogBound.default.maxBytes),
                    "defaultMaxUnwritableMs": .stringConvertible(SendBacklogBound.default.maxUnwritable.nanoseconds / 1_000_000),
                ]
            )
        }
        let maxBytes = validValue(EnvKeys.Server.sendBacklogMaxBytes, environment)
            ?? SendBacklogBound.default.maxBytes
        let maxUnwritable = validValue(EnvKeys.Server.sendBacklogMaxUnwritableMs, environment)
            .map { TimeAmount.milliseconds(Int64($0)) }
            ?? SendBacklogBound.default.maxUnwritable
        return SendBacklogBound(maxBytes: maxBytes, maxUnwritable: maxUnwritable)
    }

    /// The send backlog env keys that are set but not a whole number of 0 or above.
    static func rejectedSendBacklogKeys(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [EnvKeys.Server.sendBacklogMaxBytes, EnvKeys.Server.sendBacklogMaxUnwritableMs].filter {
            environment[$0] != nil && validValue($0, environment) == nil
        }
    }

    private static func validValue(_ key: String, _ environment: [String: String]) -> Int? {
        guard environment[key] != nil else { return nil }
        let value = EnvHelpers.getEnvInt(key: key, defaultValue: -1, environment: environment)
        return value >= 0 ? value : nil
    }

    /// The rejected send backlog warning is logged once per process.
    static let rejectedSendBacklogWarning = OnceFlag()
}
