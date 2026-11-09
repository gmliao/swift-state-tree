// Tests/SwiftStateTreeNIOTests/StopFenceTests.swift
//
// The stop fence (#351): after `stop`, nothing reaches the event loop; `stop` waits for the
// hand-offs already past the check, up to its cap.

import Dispatch
import Foundation
import NIOCore
import NIOPosix
import Testing
import SwiftStateTreeTransport

/// A counter safe to bump from any thread.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("StopFence", .timeLimit(.minutes(1)))
struct StopFenceTests {
    @Test("after stop, a hand-off is dropped and counted, and its body doesn't run")
    func dropsAfterStop() async {
        let fence = StopFence()
        #expect(fence.submit {})
        await fence.stop()
        var ran = false
        #expect(!fence.submit { ran = true })
        #expect(!ran)
        #expect(fence.droppedCount == 1)
    }

    @Test("stop returns only after a hand-off already past the check has finished")
    func stopWaitsForInFlight() async {
        let fence = StopFence()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let bodyDone = LockedCount()
        Thread {
            fence.submit {
                entered.signal()
                release.wait()
                bodyDone.add()
            }
        }.start()
        blockingWait(entered)
        // Whichever comes first: `stop` reaching its wait (the body is still blocked), or `stop`
        // returning. The body is released only after the first, so a stop that doesn't wait
        // returns while the body is blocked, and that is what it reads.
        let (events, sink) = AsyncStream.makeStream(of: String.self)
        let stopTask = Task { () -> (Int, Int) in
            let remaining = await fence.stop(cap: .seconds(30), waiting: { sink.yield("waiting") })
            let done = bodyDone.count
            sink.yield("returned")
            return (remaining, done)
        }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == "waiting", "stop returned before the hand-off past its check finished")
        release.signal()
        let (remaining, doneAtReturn) = await stopTask.value
        #expect(remaining == 0)
        #expect(doneAtReturn == 1, "stop returned before the hand-off past its check finished")
    }

    @Test("stop gives up at its cap and reports the hand-offs still in flight")
    func stopCapped() async {
        let fence = StopFence()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread {
            fence.submit {
                entered.signal()
                release.wait()
            }
        }.start()
        blockingWait(entered)
        let remaining = await fence.stop(cap: .milliseconds(20))
        #expect(remaining == 1)
        release.signal()
    }

    @Test("every hand-off that passed the fence ran on the loop, under a concurrent stop and group shutdown")
    func noSubmitAfterShutdown() async throws {
        for _ in 0..<20 {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let loop = group.next()
            let fence = StopFence()
            let submitted = LockedCount()
            let executed = LockedCount()
            let senders = 8
            let started = DispatchSemaphore(value: 0)
            let threads = (0..<senders).map { _ in
                Thread {
                    started.signal()
                    for _ in 0..<2_000 {
                        fence.submit { submitted.add(); loop.execute { executed.add() } }
                    }
                }
            }
            threads.forEach { $0.start() }
            for _ in 0..<senders { blockingWait(started) }
            await fence.stop(cap: .seconds(5))
            try await group.shutdownGracefully()
            // A loop drains its queued tasks before it shuts down, so every hand-off that was
            // submitted before the stop ran; one submitted after it would be lost.
            #expect(executed.count == submitted.count)
        }
    }
}

/// `DispatchSemaphore.wait` from a synchronous frame: the tests block only until a thread they
/// started reaches its point.
private func blockingWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
