// CountingTransport's wait for answers (`waitForAnswers(atLeast:)`): the tickless runner waits
// on it for the replies of the inputs it submitted. An input that is accepted but never answered
// must not hang the run: once the inputs are settled (every handler ran and the adapter's writer
// handed over what it queued), the wait returns and `InputCounts` reports the shortfall.

import Foundation
import Testing
@testable import EncodingBenchmark

@Suite("CountingTransport: the wait for answers is bounded by the inputs settling")
struct CountingTransportAnswerWaitTests {
    /// An action response frame as the JSON encoding writes it (`ActionResponsePeek` finds it).
    private static let replyFrame = Data(#"{"kind":"actionResponse","payload":{"requestID":"r","response":{}}}"#.utf8)

    @Test("An input accepted but never answered: the wait returns when the answers are final, and the shortfall is reported")
    func unansweredInputEndsTheWait() async throws {
        let transport = CountingTransport(countsErrors: true, countsReplies: true)
        let ticket = await transport.beginAnswerWait()
        // Two inputs submitted and accepted; only one is answered.
        await transport.send(Self.replyFrame, to: .broadcast)
        #expect(await transport.replyFrameCount() == 1)

        let waiting = Probe()
        let waiter = Task {
            await transport.waitForAnswers(atLeast: 2)
            waiting.finish()
        }
        // Not final yet: the wait is still open (the writer may hold the second reply).
        #expect(await waiting.finishes(within: .milliseconds(200)) == false)

        await transport.markAnswersFinal(ticket: ticket)
        // The limit is this test's own; the wait itself has no timer.
        let returned = await waiting.finishes(within: .seconds(10))
        #expect(returned, "the wait must return once the answers are final, though one reply is missing")
        guard returned else { return }
        await waiter.value

        // The run's counts show the shortfall, and `requireComplete` would exit 1 on it.
        var counts = InputCounts(rooms: 1, expectedPerRoom: 2, countsReplies: true)
        counts.submitted = [2]
        counts.applied = [2]
        counts.rejected = [await transport.errorFrameCount()]
        counts.replied = [await transport.replyFrameCount()]
        let shortfall = counts.shortfall(label: "t")
        #expect(shortfall?.contains("room 0") == true, "\(shortfall ?? "nil")")
        #expect(shortfall?.contains("replied 1") == true, "\(shortfall ?? "nil")")
    }

    @Test("A final mark of an earlier wait doesn't end a later one")
    func staleTicketIsIgnored() async {
        let transport = CountingTransport(countsErrors: true, countsReplies: true)
        let stale = await transport.beginAnswerWait()
        _ = await transport.beginAnswerWait()
        let waiting = Probe()
        Task {
            await transport.waitForAnswers(atLeast: 1)
            waiting.finish()
        }
        await transport.markAnswersFinal(ticket: stale)
        #expect(await waiting.finishes(within: .milliseconds(200)) == false)
        // The reply itself still ends it, as before.
        await transport.send(Self.replyFrame, to: .broadcast)
        #expect(await waiting.finishes(within: .seconds(10)))
    }

    @Test("Replies reaching the count end the wait with no final mark")
    func answeredInputsEndTheWait() async {
        let transport = CountingTransport(countsErrors: true, countsReplies: true)
        _ = await transport.beginAnswerWait()
        let waiting = Probe()
        Task {
            await transport.waitForAnswers(atLeast: 2)
            waiting.finish()
        }
        await transport.send(Self.replyFrame, to: .broadcast)
        await transport.send(Self.replyFrame, to: .broadcast)
        #expect(await waiting.finishes(within: .seconds(10)))
    }
}

/// A one-shot signal a test can wait on for a limited time.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var callbacks: [@Sendable () -> Void] = []

    func finish() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            finished = true
            defer { callbacks = [] }
            return callbacks
        }
        pending.forEach { $0() }
    }

    /// Whether `finish()` was called within `limit`: the limit is the test's own, not the wait's.
    func finishes(within limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once(continuation)
            let alreadyDone: Bool = lock.withLock {
                if finished { return true }
                callbacks.append { once.resume(true) }
                return false
            }
            if alreadyDone { once.resume(true); return }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(false)
            }
        }
    }
}

/// Resumes its continuation at most once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        let taken = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
