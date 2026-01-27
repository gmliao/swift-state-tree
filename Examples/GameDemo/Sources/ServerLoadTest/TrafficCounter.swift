// Sources/ServerLoadTest/TrafficCounter.swift
//
// Actor for thread-safe traffic measurement.

import Foundation

actor TrafficCounter {
    private var sentBytes: Int = 0
    private var recvBytes: Int = 0
    private var sentMessages: Int = 0
    private var recvMessages: Int = 0
    private var messageSizes: [Int] = []
    private var messageSizesLimit: Int = 10000

    func recordSent(bytes: Int) {
        sentBytes += bytes
        sentMessages += 1
        if messageSizes.count < messageSizesLimit {
            messageSizes.append(bytes)
        }
    }

    func recordReceived(bytes: Int) {
        recvBytes += bytes
        recvMessages += 1
        if messageSizes.count < messageSizesLimit {
            messageSizes.append(bytes)
        }
    }

    func snapshot() -> TrafficSnapshot {
        let avgSize = messageSizes.isEmpty ? 0.0 : Double(messageSizes.reduce(0, +)) / Double(messageSizes.count)
        return TrafficSnapshot(
            sentBytes: sentBytes,
            recvBytes: recvBytes,
            sentMessages: sentMessages,
            recvMessages: recvMessages,
            avgMessageSize: avgSize
        )
    }

    func reset() {
        messageSizes.removeAll(keepingCapacity: true)
    }
}

struct TrafficSnapshot: Sendable {
    let sentBytes: Int
    let recvBytes: Int
    let sentMessages: Int
    let recvMessages: Int
    let avgMessageSize: Double
}
