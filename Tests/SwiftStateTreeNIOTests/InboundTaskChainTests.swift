// Tests/SwiftStateTreeNIOTests/InboundTaskChainTests.swift
//
// A session's connect, messages and disconnect reach the transport in the order the channel saw
// them. Each used to run in its own Task, so a client's join could reach the transport before the
// connection was registered: the router answered "unknown session", the transport dropped that
// answer (no queue for the session yet), and the client waited for a join response forever.

import Foundation
import Testing
@testable import SwiftStateTreeNIO

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

@Suite("Inbound task chain")
struct InboundTaskChainTests {
    @Test("A slow connect still runs before the messages queued after it")
    func slowFirstOperationKeepsOrder() async {
        let chain = InboundTaskChain()
        let log = OrderLog()
        chain.enqueue {
            // A connect that is slow to reach the transport (a busy executor in CI).
            try? await Task.sleep(for: .milliseconds(50))
            log.append("connect")
        }
        for index in 0..<5 {
            chain.enqueue { log.append("message-\(index)") }
        }
        chain.enqueue { log.append("disconnect") }
        await chain.waitForIdle()
        #expect(log.all == ["connect"] + (0..<5).map { "message-\($0)" } + ["disconnect"])
    }

    @Test("Operations enqueued after the chain went idle still run")
    func enqueueAfterIdle() async {
        let chain = InboundTaskChain()
        let log = OrderLog()
        chain.enqueue { log.append("a") }
        await chain.waitForIdle()
        chain.enqueue { log.append("b") }
        await chain.waitForIdle()
        #expect(log.all == ["a", "b"])
    }
}
