import Foundation
import Testing
@testable import SwiftStateTree

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `ProcessSignals.ignoreSIGPIPE()` (#273). Each case runs in a child process (an exit test), so
/// it never changes the test process's disposition. Each child first resets SIGPIPE to the
/// default: an ignored signal is inherited, and SwiftNIO ignores it process-wide on Linux once
/// a test has opened a socket. A child reports a failed check through its exit code.
@Suite("Process signals: SIGPIPE")
struct ProcessSignalsTests {
    @Test("without the helper, a write to a closed pipe ends the process with SIGPIPE")
    func closedPipeKillsWithoutHelper() async {
        await #expect(processExitsWith: .signal(SIGPIPE)) {
            _ = signal(SIGPIPE, SIG_DFL)
            let writeEnd = closedPipeWriteEnd()
            var byte: UInt8 = 0x41
            _ = write(writeEnd, &byte, 1)
            exit(2)  // not reached: the write raises SIGPIPE
        }
    }

    @Test("with the helper, a write to a closed pipe returns EPIPE and the throwing write throws")
    func closedPipeGivesEPIPEWithHelper() async {
        await #expect(processExitsWith: .success) {
            _ = signal(SIGPIPE, SIG_DFL)
            ProcessSignals.ignoreSIGPIPE()
            let writeEnd = closedPipeWriteEnd()
            var byte: UInt8 = 0x41
            let written = write(writeEnd, &byte, 1)
            guard written == -1, errno == EPIPE else { exit(3) }
            let handle = FileHandle(fileDescriptor: writeEnd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: Data([0x41]))
                exit(4)  // the write must not succeed
            } catch {
                exit(0)
            }
        }
    }

    @Test("the helper reports whether it changed the disposition; a second call does nothing")
    func idempotent() async {
        await #expect(processExitsWith: .success) {
            _ = signal(SIGPIPE, SIG_DFL)
            guard !ProcessSignals.isSIGPIPEIgnored() else { exit(5) }
            guard ProcessSignals.ignoreSIGPIPE() else { exit(6) }
            guard ProcessSignals.isSIGPIPEIgnored() else { exit(7) }
            guard !ProcessSignals.ignoreSIGPIPE() else { exit(8) }
            guard ProcessSignals.isSIGPIPEIgnored() else { exit(9) }
            exit(0)
        }
    }
}

/// A pipe whose read end is closed: its write end, where a write raises SIGPIPE or gives EPIPE.
private func closedPipeWriteEnd() -> Int32 {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { exit(10) }
    close(fds[0])
    return fds[1]
}
