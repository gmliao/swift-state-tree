// Sources/ServerLoadTest/Models.swift
//
// Data models for load test results.

import Foundation

// MARK: - Second Sample

struct SecondSample: Sendable {
    let t: Int
    let roomsTarget: Int
    let roomsCreated: Int
    let roomsActiveExpected: Int
    let playersActiveExpected: Int
    let actionsSentThisSecond: Int
    let sentBytesPerSecond: Int
    let recvBytesPerSecond: Int
    let sentMessagesPerSecond: Int
    let recvMessagesPerSecond: Int
    let processCPUSeconds: Double?
    let processRSSBytes: UInt64?
    let avgMessageSize: Double
    let estimatedTicksPerSecond: Double
    let estimatedSyncsPerSecond: Double
    let estimatedUpdatesPerSecond: Double
}

// MARK: - Load Test Summary

struct LoadTestSummary: Sendable {
    let totalSeconds: Int
    let rampUpSeconds: Int
    let steadySeconds: Int
    let rampDownSeconds: Int
    let roomsTarget: Int
    let roomsCreated: Int
    let playersCreated: Int
    let totalSentBytes: Int
    let totalReceivedBytes: Int
    let totalSentMessages: Int
    let totalReceivedMessages: Int
    let peakRSSBytes: UInt64?
    let endRSSBytes: UInt64?

    var avgSentBytesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSentBytes) / Double(totalSeconds)
    }

    var avgRecvBytesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalReceivedBytes) / Double(totalSeconds)
    }

    var avgSentMessagesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSentMessages) / Double(totalSeconds)
    }

    var avgRecvMessagesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalReceivedMessages) / Double(totalSeconds)
    }
}
