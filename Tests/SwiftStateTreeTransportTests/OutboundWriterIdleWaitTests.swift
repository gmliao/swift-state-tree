// Tests/SwiftStateTreeTransportTests/OutboundWriterIdleWaitTests.swift
//
// `OutboundWriter.waitForIdle` returns when its task is cancelled, before or after it registers,
// and leaves no bookkeeping behind (#718 review).

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@Suite("OutboundWriter idle wait")
struct OutboundWriterIdleWaitTests {
    private static let logger = Logger(label: "outbound-idle-wait")

    private func frame(_ text: String) -> SessionFrame {
        SessionFrame(data: Data(text.utf8), sessionID: SessionID("idle-wait-session"), connectionGeneration: nil)
    }

    /// `true` when `wait` returned within `testHangBound`. When the bound runs out first, the
    /// transport is released: the writer drains and resumes every registered idle wait, so a
    /// wait the writer would never have resumed returns and the test fails by name instead of
    /// hanging.
    private func returnsWithinBound(
        releasing transport: BlockingTransport,
        _ wait: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await wait()
                return true
            }
            group.addTask {
                try? await safeTaskSleep(for: testHangBound)
                transport.release()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// A wait whose task is cancelled before it starts.
    private func cancelledBeforeWait(_ writer: OutboundWriter, _ transport: BlockingTransport) async -> Bool {
        await returnsWithinBound(releasing: transport) {
            withUnsafeCurrentTask { $0?.cancel() }
            await writer.waitForIdle()
        }
    }

    @Test("an idle writer: a wait cancelled before it starts returns and leaves nothing")
    func cancelledBeforeOnIdleWriter() async {
        let transport = BlockingTransport()
        let writer = OutboundWriter(transport: transport, maxBytes: 1 << 20, logger: Self.logger)
        #expect(await cancelledBeforeWait(writer, transport), "the cancelled wait never returned")
        #expect(writer.idleWaitEntriesForTesting == 0)
    }

    @Test("a writer whose transport never returns: a wait cancelled before it starts returns and leaves nothing")
    func cancelledBeforeOnBusyWriter() async {
        let transport = BlockingTransport()
        transport.block()
        defer { transport.release() }
        let writer = OutboundWriter(transport: transport, maxBytes: 1 << 20, logger: Self.logger)
        writer.enqueue([frame("stuck")])
        #expect(await cancelledBeforeWait(writer, transport), "the cancelled wait never returned")
        #expect(writer.idleWaitEntriesForTesting == 0)
    }

    @Test("a writer whose transport never returns: a registered wait returns when cancelled and leaves nothing")
    func cancelledAfterRegistration() async {
        let transport = BlockingTransport()
        transport.block()
        defer { transport.release() }
        let writer = OutboundWriter(transport: transport, maxBytes: 1 << 20, logger: Self.logger)
        writer.enqueue([frame("stuck")])
        let wait = Task { await writer.waitForIdle() }
        let registered = await withinHangBound {
            // wall-clock: nothing reports the registration; the loop yields, it doesn't sleep
            while writer.idleWaitEntriesForTesting == 0, !Task.isCancelled { await Task.yield() }
        }
        #expect(registered, "the wait never registered")
        wait.cancel()
        #expect(await returnsWithinBound(releasing: transport) { await wait.value }, "the cancelled wait never returned")
        #expect(writer.idleWaitEntriesForTesting == 0)
    }
}
