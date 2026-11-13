// Examples/GameDemo/Sources/EncodingBenchmark/CountingTransport.swift
//
// Mock transport implementation for counting bytes and messages.

import Foundation
import LoadTestPacing
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

    init(capturing: Bool = false, countsErrors: Bool = InputRun.fromWire) {
        captured = capturing ? [] : nil
        self.countsErrors = countsErrors
    }

    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sentBytes += message.count
        sentMessages += 1
        if countsErrors, ErrorFramePeek.isError(message) { errorFrames += 1 }
        captured?.append(CapturedFrame(target: ViewCapture.target(target), data: message))
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
    }

    /// Error frames sent since the last `resetCounts()` (0 unless `countsErrors`).
    func errorFrameCount() -> Int { errorFrames }

    func snapshotCounts() -> (bytes: Int, messages: Int) {
        (sentBytes, sentMessages)
    }
}
