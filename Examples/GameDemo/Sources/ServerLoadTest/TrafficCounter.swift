// Sources/ServerLoadTest/TrafficCounter.swift
//
// Actor for thread-safe traffic measurement.

import Foundation
import SwiftStateTree

actor TrafficCounter {
    private var sentBytes: Int = 0
    private var recvBytes: Int = 0
    private var sentMessages: Int = 0
    private var recvMessages: Int = 0
    private var messageSizes: [Int] = []
    private var messageSizesLimit: Int = 10000
    /// Bytes each session received (the server's encoded frames).
    private var receivedBySession: [SessionID: Int] = [:]

    func recordSent(bytes: Int) {
        sentBytes += bytes
        sentMessages += 1
        if messageSizes.count < messageSizesLimit {
            messageSizes.append(bytes)
        }
    }

    func recordReceived(bytes: Int, sessionID: SessionID) {
        receivedBySession[sessionID, default: 0] += bytes
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

    /// Received bytes per session: min, median and max over the sessions that received any.
    func receivedPerSession() -> (sessions: Int, min: Int, median: Double, max: Int)? {
        let sorted = receivedBySession.values.sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? Double(sorted[mid]) : Double(sorted[mid - 1] + sorted[mid]) / 2
        return (sorted.count, first, median, last)
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
