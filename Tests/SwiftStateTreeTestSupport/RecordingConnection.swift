// Tests/SwiftStateTreeTestSupport/RecordingConnection.swift
//
// A fake WebSocket connection that records what the server sent it: every frame in order, and
// the close (code and reason). Shared by the shutdown tests and the differential harness (#555).

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Records the frames sent to it, in order, and its close.
package actor RecordingConnection: WebSocketConnection {
    private struct FrameWaiter {
        let condition: @Sendable ([Data]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The bound on a wait for a frame that never comes.
    private let hangBound: Duration

    package private(set) var frames: [Data] = []
    package private(set) var closeCode: UInt16?
    /// The close's reason: empty for `close()`, the given one for `close(with:)`.
    package private(set) var closeReason: String?
    package private(set) var closed = false
    private var frameWaiters: [Int: FrameWaiter] = [:]
    private var nextWaiterID = 0

    package init(hangBound: Duration = testHangBound) {
        self.hangBound = hangBound
    }

    package func send(_ data: Data) async throws {
        frames.append(data)
        let sent = frames
        for (id, waiter) in frameWaiters where waiter.condition(sent) {
            frameWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }

    package func close() async throws {
        closed = true
        closeCode = 1000
        closeReason = ""
    }

    package func close(with close: SessionClose) async throws {
        closed = true
        closeCode = close.code
        closeReason = close.reason
    }

    /// The frames that decode as JSON transport messages, for tests that read them. A strict
    /// comparison reads `frames` instead: this drops what doesn't decode.
    package var messages: [TransportMessage] { Self.messages(in: frames) }

    private static func messages(in frames: [Data]) -> [TransportMessage] {
        frames.compactMap { try? JSONDecoder().decode(TransportMessage.self, from: $0) }
    }

    /// The codes of the error messages sent so far.
    package var errorCodes: [String] {
        messages.compactMap { message in
            if case .error(let payload) = message.payload { return payload.code } else { return nil }
        }
    }

    /// Waits until the transport messages sent so far meet `condition`; resumed by `send`, not
    /// by polling. `false` after the hang bound, when the frame never comes.
    package func waitUntilFrames(_ condition: @escaping @Sendable ([TransportMessage]) -> Bool) async -> Bool {
        await waitUntilRawFrames { condition(Self.messages(in: $0)) }
    }

    /// Waits until a first-sync state frame was sent: the commit that sends it has run (#390).
    package func waitForFirstSync() async -> Bool {
        await waitUntilRawFrames { frames in
            frames.contains { String(decoding: $0, as: UTF8.self).contains("\"firstSync\"") }
        }
    }

    /// `waitUntilFrames` over every frame sent, state frames included.
    package func waitUntilRawFrames(_ condition: @escaping @Sendable ([Data]) -> Bool) async -> Bool {
        if condition(frames) { return true }
        let id = nextWaiterID
        nextWaiterID += 1
        let hangGuard = Task { [weak self, hangBound] in
            try? await safeTaskSleep(for: hangBound)
            await self?.expireWaiter(id)
        }
        defer { hangGuard.cancel() }
        return await withCheckedContinuation { continuation in
            frameWaiters[id] = FrameWaiter(condition: condition, continuation: continuation)
        }
    }

    private func expireWaiter(_ id: Int) {
        frameWaiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }
}
