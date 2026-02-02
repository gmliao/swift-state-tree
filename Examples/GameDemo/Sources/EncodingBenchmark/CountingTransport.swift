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

    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to _: SwiftStateTreeTransport.EventTarget) {
        sentBytes += message.count
        sentMessages += 1
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
