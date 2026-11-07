// Examples/GameDemo/Sources/EncodingBenchmark/CountingTransport.swift
//
// Mock transport implementation for counting bytes and messages.

import Foundation
import SwiftStateTreeTransport

// MARK: - Counting Transport

actor CountingTransport: Transport {
    var delegate: TransportDelegate?

    private var sentBytes: Int = 0
    private var sentMessages: Int = 0
    /// Frames kept for `--capture-views`; nil when this room isn't captured.
    private var captured: [CapturedFrame]?

    init(capturing: Bool = false) {
        captured = capturing ? [] : nil
    }

    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sentBytes += message.count
        sentMessages += 1
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
    }

    func snapshotCounts() -> (bytes: Int, messages: Int) {
        (sentBytes, sentMessages)
    }
}
