import Foundation
import Testing
@testable import SwiftStateTree

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `ProcessSignals.shutdownSignals` (#351). The SIGTERM cases run in a child process (an exit
/// test), so the test process never gets SIGTERM. Signals are sent with `kill(getpid(), …)`, a
/// process-directed signal like a supervisor's, not the thread-directed `raise`. A child reports
/// a failed check through its exit code.
@Suite("Process signals: shutdown signals", .timeLimit(.minutes(1)))
struct ShutdownSignalsTests {
    @Test("a signal sent after the call returns is delivered on the stream")
    func deliversAfterReturn() async {
        // SIGUSR2 only, and without the second-signal exit: this runs in the test process.
        let stream = ProcessSignals.shutdownSignals([SIGUSR2], escalates: false)
        #expect(kill(getpid(), SIGUSR2) == 0)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == SIGUSR2)
    }

    @Test("the first SIGTERM goes to the stream and does not end the process")
    func firstSignalIsDelivered() async {
        await #expect(processExitsWith: .success) {
            let stream = ProcessSignals.shutdownSignals([SIGINT, SIGTERM])
            guard kill(getpid(), SIGTERM) == 0 else { exit(3) }
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() == SIGTERM else { exit(4) }
            exit(0)
        }
    }

    @Test("a second SIGTERM ends the process with 143 (128 + SIGTERM), through the handler's exit")
    func secondSigtermExits() async {
        await #expect(processExitsWith: .exitCode(128 + SIGTERM)) {
            let stream = ProcessSignals.shutdownSignals([SIGINT, SIGTERM])
            guard kill(getpid(), SIGTERM) == 0 else { exit(3) }
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() == SIGTERM else { exit(4) }
            guard kill(getpid(), SIGTERM) == 0 else { exit(5) }
            // As below: the exit ends the wait.
            for _ in 0..<100 { usleep(100_000) }
            exit(2)
        }
    }

    @Test("a second signal ends the process with 128 + signal, whichever of the set it is")
    func secondSignalExits() async {
        await #expect(processExitsWith: .exitCode(128 + SIGINT)) {
            let stream = ProcessSignals.shutdownSignals([SIGINT, SIGTERM])
            guard kill(getpid(), SIGTERM) == 0 else { exit(3) }
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() == SIGTERM else { exit(4) }
            guard kill(getpid(), SIGINT) == 0 else { exit(5) }
            // The reader thread exits the process; wait for it here, with an upper bound, so
            // this thread doesn't exit first. Not a timing assertion: the exit ends the wait.
            for _ in 0..<100 { usleep(100_000) }
            exit(2)
        }
    }

    @Test("a child process started with exec gets the default SIGTERM action back")
    func handlerResetAcrossExec() async {
        await #expect(processExitsWith: .success) {
            _ = ProcessSignals.shutdownSignals([SIGINT, SIGTERM])
            // `sh -c 'kill -TERM $$'` ends the shell with SIGTERM only if the default action
            // was restored by exec; an ignored signal would be inherited and the shell exit 0.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "kill -TERM $$; exit 0"]
            do { try process.run() } catch { exit(3) }
            process.waitUntilExit()
            guard process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM else { exit(4) }
            exit(0)
        }
    }
}
