// Sources/SwiftStateTree/Support/ShutdownSignals.swift
//
// SIGINT/SIGTERM as an async stream, for a graceful shutdown (#351).

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

extension ProcessSignals {
    /// The shutdown signals delivered to this process, as a stream: a server awaits the first
    /// element, then shuts down (`NIOLandHost.runUntilShutdownSignal` does both).
    ///
    /// **A second signal ends the process at once**, with exit status `128 + signal` (the shell
    /// convention): an operator who presses Ctrl-C twice, or a supervisor that sends SIGTERM
    /// twice, is not held up by a shutdown that hangs. The count is shared by every signal in
    /// every stream this returns, so SIGINT after SIGTERM counts too.
    ///
    /// How it works: a `sigaction` handler (with `SA_RESTART`) writes one byte to a pipe, and a
    /// thread of its own reads the pipe. The handler is installed when this call returns, so a
    /// signal sent afterwards is never lost. The setup is the same on Linux and Darwin (Dispatch
    /// signal sources are not: libdispatch on Linux installs a handler of its own).
    ///
    /// Like `ignoreSIGPIPE`, this changes process-wide state, so the library never calls it for
    /// you. Things to know:
    /// - **The handler stays** for the life of the process: the signals no longer end the
    ///   process with the default action, only through the stream's owner or a second signal.
    /// - **Children:** a handler, unlike an ignored signal, is reset to the default across
    ///   `exec`, so a child process you spawn gets SIGINT and SIGTERM normally.
    /// - **Calling it again** returns another stream fed by the same handler and thread.
    ///
    /// - Parameter signals: The signals to catch. Defaults to SIGINT and SIGTERM.
    public static func shutdownSignals(_ signals: [Int32] = [SIGINT, SIGTERM]) -> AsyncStream<Int32> {
        ShutdownSignalReader.shared.subscribe(signals: signals, escalates: true)
    }

    /// `shutdownSignals(_:)` without the second-signal exit (tests, which send a signal to the
    /// test process itself).
    static func shutdownSignals(_ signals: [Int32], escalates: Bool) -> AsyncStream<Int32> {
        ShutdownSignalReader.shared.subscribe(signals: signals, escalates: escalates)
    }
}

/// The pipe's write end, read by the signal handler. Set before any handler is installed, so the
/// handler never runs this global's lazy initialization.
nonisolated(unsafe) private var shutdownSignalWriteFD: Int32 = -1

/// Async-signal-safe: one `write`, with `errno` saved and restored (a signal can land between
/// another thread's failing call and its read of `errno`). A full pipe (`EAGAIN`) drops the
/// byte: the pipe then already holds bytes the reader hasn't consumed, so the shutdown starts
/// anyway, and a second delivery is already in the pipe.
private let shutdownSignalHandler: @convention(c) (Int32) -> Void = { signal in
    let saved = errno
    var byte = UInt8(truncatingIfNeeded: signal)
    _ = write(shutdownSignalWriteFD, &byte, 1)
    errno = saved
}

/// The self-pipe, its reader thread and the streams it feeds (one per process).
final class ShutdownSignalReader: @unchecked Sendable {
    static let shared = ShutdownSignalReader()

    private struct Subscriber {
        let signals: Set<Int32>
        let continuation: AsyncStream<Int32>.Continuation
    }

    private let lock = NSLock()
    private var readFD: Int32 = -1
    private var installed: Set<Int32> = []
    private var subscribers: [Subscriber] = []
    /// Set once a stream with the second-signal exit exists.
    private var escalates = false
    /// Signals delivered while `escalates` is set.
    private var deliveries = 0

    private init() {}

    func subscribe(signals: [Int32], escalates: Bool) -> AsyncStream<Int32> {
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        lock.lock()
        defer { lock.unlock() }
        startIfNeeded()
        subscribers.append(Subscriber(signals: Set(signals), continuation: continuation))
        if escalates { self.escalates = true }
        for signal in signals where !installed.contains(signal) {
            install(signal)
            installed.insert(signal)
        }
        return stream
    }

    /// Creates the pipe and starts the reader, once. Called under the lock.
    private func startIfNeeded() {
        guard readFD < 0 else { return }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            preconditionFailure("ShutdownSignals: pipe() failed (errno \(errno))")
        }
        // Not inherited by a child process; the write end never blocks the handler.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        readFD = fds[0]
        shutdownSignalWriteFD = fds[1]
        let fd = readFD
        let thread = Thread { [self] in readLoop(fd: fd) }
        thread.name = "swiftstatetree.shutdown-signals"
        thread.start()
    }

    private func install(_ signal: Int32) {
        var action = sigaction()
        #if canImport(Glibc)
        action.__sigaction_handler.sa_handler = shutdownSignalHandler
        #elseif canImport(Musl)
        // Untested on Musl: no static Linux SDK was available when this was written.
        action.__sa_handler.sa_handler = shutdownSignalHandler
        #else
        action.__sigaction_u.__sa_handler = shutdownSignalHandler
        #endif
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        guard sigaction(signal, &action, nil) == 0 else {
            preconditionFailure("ShutdownSignals: sigaction(\(signal)) failed (errno \(errno))")
        }
    }

    private func readLoop(fd: Int32) {
        while true {
            var byte: UInt8 = 0
            let count = read(fd, &byte, 1)
            if count == 1 {
                deliver(Int32(byte))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func deliver(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if escalates {
            deliveries += 1
            if deliveries >= 2 { _exit(128 + signal) }
        }
        for subscriber in subscribers where subscriber.signals.contains(signal) {
            subscriber.continuation.yield(signal)
        }
    }
}
