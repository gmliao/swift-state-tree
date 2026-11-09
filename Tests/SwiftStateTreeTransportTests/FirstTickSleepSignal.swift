import Foundation
@testable import SwiftStateTree

/// A tick-loop clock on real time that reports the loop's first `sleepUntil` (the same
/// handshake as `InTurnSyncFoldReportTests`, for this test target). The loop publishes its first
/// tick deadline (`noteNextTickDeadline`) in its own task, just before that sleep. A test that
/// set the deadline before then could have it overwritten by the loop's (now + interval), and a
/// sync it expected to fold would not. Once the sleep is reported, the loop writes no deadline
/// until the interval has passed. The sleep is real and ends on shutdown.
///
/// Bind `tickLoopClock` around the keeper's creation (`TickLoopClock.$forNewKeepers`), then
/// `await waitUntilReached()` before setting a deadline.
final class FirstTickSleepSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var tickLoopClock: TickLoopClock {
        TickLoopClock(
            now: { ContinuousClock.now },
            sleepFor: { try? await safeTaskSleep(for: $0) },
            sleepUntil: { deadline in
                self.markReached()
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        )
    }

    private func markReached() {
        lock.lock()
        reached = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    /// Returns once the tick loop has started its first sleep (at once if it has).
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if reached {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
