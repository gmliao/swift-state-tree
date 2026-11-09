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
        // `posix_spawn` and `waitpid` directly, not Foundation's `Process`. The exit test's body
        // runs on a concurrency worker thread, which blocks asynchronous signals, and a child
        // inherits its spawner's signal mask: with SIGTERM blocked, `kill -TERM $$` is held
        // pending and the shell exits 7. Darwin's `Process` clears the mask; Linux's doesn't, so
        // the spawn clears it here (POSIX_SPAWN_SETSIGMASK with an empty set). It doesn't set
        // POSIX_SPAWN_SETSIGDEF: the default action must come from exec itself.
        // Exit codes: 0 pass; 10 spawn; 11 wait; 20+n exited n; 60+s another signal s.
        await #expect(processExitsWith: .success) {
            _ = ProcessSignals.shutdownSignals([SIGINT, SIGTERM])
            #if canImport(Darwin)
            var attributes: posix_spawnattr_t?
            #else
            var attributes = posix_spawnattr_t()
            #endif
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var empty = sigset_t()
            sigemptyset(&empty)
            posix_spawnattr_setsigmask(&attributes, &empty)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK))

            // `sh -c 'kill -TERM $$'` ends the shell with SIGTERM only if exec restored the
            // default action; an inherited ignore or handler would let it exit 7.
            var pid: pid_t = 0
            let arguments = ["/bin/sh", "-c", "kill -TERM $$; exit 7"]
            var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            guard posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ) == 0 else { exit(10) }
            var status: Int32 = 0
            var waited: pid_t
            repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
            guard waited == pid else { exit(11) }
            // WIFSIGNALED / WTERMSIG: the low 7 bits are the signal, 0 and 0x7f excluded.
            let signal = status & 0x7f
            guard signal != 0, signal != 0x7f else { exit(20 + min((status >> 8) & 0xff, 30)) }
            guard signal == SIGTERM else { exit(60 + signal) }
            exit(0)
        }
    }
}
