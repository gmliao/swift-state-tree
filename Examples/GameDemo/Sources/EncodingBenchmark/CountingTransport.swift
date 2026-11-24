// Examples/GameDemo/Sources/EncodingBenchmark/CountingTransport.swift
//
// Mock transport implementation for counting bytes and messages.

import Foundation
import LoadTestPacing
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - Counting Transport

actor CountingTransport: Transport {
    var delegate: TransportDelegate?

    private var sentBytes: Int = 0
    private var sentMessages: Int = 0
    /// Frames kept for `--capture-views`; nil when this room isn't captured.
    private var captured: [CapturedFrame]?
    /// `--inputs-from-wire`: error frames sent (`ErrorFramePeek`), the inputs the server refused.
    /// Counted only when `countsErrors`, so other runs send exactly as before.
    private var errorFrames: Int = 0
    private let countsErrors: Bool
    /// `--game-type visibility-test-tickless`: action response frames sent (`ActionResponsePeek`),
    /// the replies the land's handlers produced. Counted only when `countsReplies`.
    private var replyFrames: Int = 0
    private let countsReplies: Bool
    /// A run's wait for its replies (`waitForAnswers(atLeast:)`): resumed by the `send(_:to:)`
    /// that brings replies plus error frames to its count.
    private var answerWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    /// `--join-through-router on`: each session's first sync sequence since the last
    /// `resetCounts()` (`sendToSession`). Empty on the default path.
    private var firstSyncSeqs: [SessionID: UInt64] = [:]

    init(capturing: Bool = false, countsErrors: Bool = InputRun.fromWire, countsReplies: Bool = false) {
        captured = capturing ? [] : nil
        self.countsErrors = countsErrors
        self.countsReplies = countsReplies
    }

    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sentBytes += message.count
        sentMessages += 1
        if countsErrors, ErrorFramePeek.isError(message) { errorFrames += 1 }
        if countsReplies, ActionResponsePeek.isActionResponse(message) { replyFrames += 1 }
        captured?.append(CapturedFrame(target: ViewCapture.target(target), data: message))
        if let waiter = answerWaiter, replyFrames + errorFrames >= waiter.count {
            answerWaiter = nil
            waiter.continuation.resume()
        }
    }

    /// Returns once `count` of the run's inputs have been answered: reply frames plus error
    /// frames (a refused input is answered with an error and never gets a reply) since the last
    /// `resetCounts()`. Waits on the counter, with no timer: `send(_:to:)` resumes it. Needs
    /// `countsReplies` and `countsErrors`; one waiter at a time.
    func waitForAnswers(atLeast count: Int) async {
        precondition(countsReplies && countsErrors, "waitForAnswers needs countsReplies and countsErrors")
        guard replyFrames + errorFrames < count else { return }
        precondition(answerWaiter == nil, "one waiter at a time")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            answerWaiter = (count, continuation)
        }
    }

    /// Action response frames sent since the last `resetCounts()` (0 unless `countsReplies`).
    func replyFrameCount() -> Int { replyFrames }

    /// A frame for one session from its router-path connection, with the frame's sync sequence
    /// (nil for a frame without one): counted as `send(_:to:)` counts it.
    func sendToSession(_ message: Data, session: SessionID, syncSeq: UInt64?) {
        if let syncSeq, firstSyncSeqs[session] == nil { firstSyncSeqs[session] = syncSeq }
        send(message, to: .session(session))
    }

    /// The lowest and highest of the sessions' first sync sequences since the last
    /// `resetCounts()`; nil when no session got one.
    func firstSyncSeqRange() -> (min: UInt64, max: UInt64)? {
        guard let low = firstSyncSeqs.values.min(), let high = firstSyncSeqs.values.max() else { return nil }
        return (low, high)
    }

    /// The frames captured since the last call.
    func takeCaptured() -> [CapturedFrame] {
        defer { if captured != nil { captured = [] } }
        return captured ?? []
    }

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    func resetCounts() {
        sentBytes = 0
        sentMessages = 0
        errorFrames = 0
        replyFrames = 0
        firstSyncSeqs.removeAll(keepingCapacity: true)
    }

    /// Error frames sent since the last `resetCounts()` (0 unless `countsErrors`).
    func errorFrameCount() -> Int { errorFrames }

    func snapshotCounts() -> (bytes: Int, messages: Int) {
        (sentBytes, sentMessages)
    }
}
