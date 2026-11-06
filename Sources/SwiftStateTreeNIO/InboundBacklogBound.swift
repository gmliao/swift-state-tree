// Sources/SwiftStateTreeNIO/InboundBacklogBound.swift
//
// The inbound backlog bound (#113): a session's messages read from the channel but not yet
// delivered to the transport. Above it the session's channel is not read (TCP backpressure),
// until the backlog is down to half. Nothing is closed.

import Foundation
import Logging
import NIOCore
import SwiftStateTree

/// When a WebSocket session stops being read. 0 disables a bound.
public struct InboundBacklogBound: Equatable, Sendable {
    /// Stop reading while more messages than this are read but not yet delivered.
    public var maxMessages: Int
    /// Stop reading while more bytes than this are read but not yet delivered.
    public var maxBytes: Int

    public init(maxMessages: Int, maxBytes: Int) {
        self.maxMessages = max(0, maxMessages)
        self.maxBytes = max(0, maxBytes)
    }

    /// 1024 messages or 4 MiB: 16 full batches of 64.
    public static let `default` = InboundBacklogBound(maxMessages: 1024, maxBytes: 4 << 20)
    /// No bound.
    public static let disabled = InboundBacklogBound(maxMessages: 0, maxBytes: 0)

    /// Above the high watermark: reading stops.
    func isExceeded(messages: Int, bytes: Int) -> Bool {
        (maxMessages > 0 && messages > maxMessages) || (maxBytes > 0 && bytes > maxBytes)
    }

    /// At or below the low watermark, half of each bound: reading resumes.
    func isDrained(messages: Int, bytes: Int) -> Bool {
        (maxMessages == 0 || messages <= maxMessages / 2) && (maxBytes == 0 || bytes <= maxBytes / 2)
    }
}

/// A session's inbound backlog, measured (#113). Event-loop state of its handler.
struct InboundBacklogStats: Equatable, Sendable {
    /// The most messages read but not yet delivered at once.
    var maxQueuedMessages = 0
    /// The most bytes read but not yet delivered at once.
    var maxQueuedBytes = 0
    /// Times reading stopped at the bound.
    var readPauses = 0
    /// The longest finished pause.
    var longestPause: TimeAmount = .zero
}

extension NIOWebSocketServerConfiguration {
    /// The bound from `WS_INBOUND_BACKLOG_MAX_MESSAGES` and `WS_INBOUND_BACKLOG_MAX_BYTES`:
    /// whole numbers, 0 or above, 0 disabling that bound. A missing or invalid value gives that
    /// bound's default; a value that is set but invalid is logged at warning level, once per
    /// process.
    public static func inboundBacklogBound(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> InboundBacklogBound {
        let rejected = rejectedInboundBacklogKeys(environment: environment)
        if !rejected.isEmpty, rejectedInboundBacklogWarning.claim() {
            Logger(label: "com.swiftstatetree.nio").warning(
                "Inbound backlog bound env value is not a whole number of 0 or above; using the default",
                metadata: [
                    "keys": .string(rejected.joined(separator: ",")),
                    "defaultMaxMessages": .stringConvertible(InboundBacklogBound.default.maxMessages),
                    "defaultMaxBytes": .stringConvertible(InboundBacklogBound.default.maxBytes),
                ]
            )
        }
        let maxMessages = validInboundValue(EnvKeys.Server.inboundBacklogMaxMessages, environment)
            ?? InboundBacklogBound.default.maxMessages
        let maxBytes = validInboundValue(EnvKeys.Server.inboundBacklogMaxBytes, environment)
            ?? InboundBacklogBound.default.maxBytes
        return InboundBacklogBound(maxMessages: maxMessages, maxBytes: maxBytes)
    }

    /// The inbound backlog env keys that are set but not a whole number of 0 or above.
    static func rejectedInboundBacklogKeys(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        [EnvKeys.Server.inboundBacklogMaxMessages, EnvKeys.Server.inboundBacklogMaxBytes].filter {
            environment[$0] != nil && validInboundValue($0, environment) == nil
        }
    }

    private static func validInboundValue(_ key: String, _ environment: [String: String]) -> Int? {
        guard environment[key] != nil else { return nil }
        let value = EnvHelpers.getEnvInt(key: key, defaultValue: -1, environment: environment)
        return value >= 0 ? value : nil
    }

    /// The rejected inbound backlog warning is logged once per process.
    static let rejectedInboundBacklogWarning = OnceFlag()
}

/// A session's inbound backlog count, shared by its event loop (which adds what it reads, and
/// stops reading at the bound) and its inbound chain (which subtracts what it delivered, from
/// any thread). One lock covers the counts and the pause, so the chain sees every pause the
/// loop started and asks for the resume exactly when the backlog drains; it hops to the loop
/// only then.
final class InboundBacklogCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let bound: InboundBacklogBound
    private var messages = 0
    private var bytes = 0
    private var paused = false

    init(bound: InboundBacklogBound) {
        self.bound = bound
    }

    /// Adds one read message. Returns the new counts, and whether this read started a pause.
    func add(bytes count: Int) -> (messages: Int, bytes: Int, startedPause: Bool) {
        lock.lock()
        defer { lock.unlock() }
        messages += 1
        bytes += count
        let starts = !paused && bound.isExceeded(messages: messages, bytes: bytes)
        if starts { paused = true }
        return (messages, bytes, starts)
    }

    /// Subtracts a delivered batch. Returns whether the backlog is now drained while paused:
    /// the caller then asks the loop to resume (`resumeIfDrained`).
    func subtract(messages delivered: Int, bytes count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        messages -= delivered
        bytes -= count
        return paused && bound.isDrained(messages: messages, bytes: bytes)
    }

    /// Ends the pause if the backlog is drained. Returns whether it did.
    func resumeIfDrained() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard paused, bound.isDrained(messages: messages, bytes: bytes) else { return false }
        paused = false
        return true
    }

    /// Ends the pause whatever the backlog (the handler is removed). Returns whether one ended.
    func endPause() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { paused = false }
        return paused
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    var queuedMessages: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
