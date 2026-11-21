// Tests/SwiftStateTreeTransportTests/OutboundWriterSyncCycleDrainWaitTests.swift
//
// `OutboundWriter.waitForSyncCycleDrain` returns when its task is cancelled, before or after it
// registers, and when the consumer ends, and leaves no bookkeeping behind (#726 review).

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@Suite("OutboundWriter sync-cycle drain wait")
struct OutboundWriterSyncCycleDrainWaitTests {
    private static let logger = Logger(label: "outbound-sync-cycle-drain-wait")

    private func frame(_ text: String) -> SessionFrame {
        SessionFrame(data: Data(text.utf8), sessionID: SessionID("drain-wait-session"), connectionGeneration: nil)
    }

    /// A writer whose transport never returns, with one sync cycle element in it.
    private func busyWriter(_ transport: BlockingTransport) -> OutboundWriter {
        transport.block()
        let writer = OutboundWriter(transport: transport, maxBytes: 1 << 20, logger: Self.logger)
        writer.enqueue([frame("stuck cycle")], isSyncCycle: true)
        return writer
    }

    /// `true` when `wait` returned within `testHangBound`. When the bound runs out first, the
    /// transport is released: the writer drains and resumes every registered wait, so a wait
    /// the writer would never have resumed returns and the test fails by name instead of
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

    /// Awaits `wait`, cancelling it when the awaiting task is cancelled: the bound's cancel then
    /// ends a wait the writer never resumes, so the test fails by name instead of hanging.
    private static func value(of wait: Task<Void, Never>) async {
        await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
    }

    /// Starts a wait on `writer` and returns once it registered, or `nil` when it never did. The
    /// registration hook arrives at an open gate, and the test waits with the gate's arrival
    /// waiter, which its own bound and cancellation both end.
    private func registeredWait(_ writer: OutboundWriter) async -> Task<Void, Never>? {
        let registered = TestGate()
        registered.open()
        writer.setOnSyncCycleDrainWaitRegisteredForTesting { Task { await registered.arrive() } }
        let wait = Task { await writer.waitForSyncCycleDrain() }
        guard await registered.waitForArrivals(1) else {
            wait.cancel()
            return nil
        }
        return wait
    }

    @Test("a writer holding a sync cycle: a wait cancelled before it starts returns and leaves nothing")
    func cancelledBeforeRegistration() async {
        let transport = BlockingTransport()
        let writer = busyWriter(transport)
        defer { transport.release() }
        let returned = await returnsWithinBound(releasing: transport) {
            withUnsafeCurrentTask { $0?.cancel() }
            await writer.waitForSyncCycleDrain()
        }
        #expect(returned, "the cancelled wait never returned")
        #expect(writer.syncCycleDrainWaitEntriesForTesting == 0)
    }

    @Test("a writer holding a sync cycle: a registered wait returns when cancelled and leaves nothing")
    func cancelledAfterRegistration() async throws {
        let transport = BlockingTransport()
        let writer = busyWriter(transport)
        defer { transport.release() }
        let wait = try #require(await registeredWait(writer), "the wait never registered")
        #expect(writer.syncCycleDrainWaitEntriesForTesting == 1)
        wait.cancel()
        #expect(await returnsWithinBound(releasing: transport) { await Self.value(of: wait) }, "the cancelled wait never returned")
        #expect(writer.syncCycleDrainWaitEntriesForTesting == 0)
    }

    @Test("a registered wait returns when the consumer ends without sending, and leaves nothing")
    func consumerEndWakesTheWait() async throws {
        let transport = BlockingTransport()
        let writer = busyWriter(transport)
        defer { transport.release() }
        let wait = try #require(await registeredWait(writer), "the wait never registered")
        // The transport never returns, so teardown gives up on the consumer and releases waiters.
        #expect(await writer.finish(timeout: .milliseconds(10)) == false, "the blocked writer drained")
        #expect(await returnsWithinBound(releasing: transport) { await Self.value(of: wait) }, "the consumer's end didn't wake the wait")
        #expect(writer.syncCycleDrainWaitEntriesForTesting == 0)
    }
}
