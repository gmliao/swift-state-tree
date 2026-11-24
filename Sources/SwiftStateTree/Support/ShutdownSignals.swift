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
#elseif os(Windows)
import ucrt
#endif

extension ProcessSignals {
    /// SIGINT and SIGTERM; on Windows also SIGBREAK, which the CRT raises for Ctrl-Break.
    public static var defaultShutdownSignals: [Int32] {
        #if os(Windows)
        [SIGINT, SIGTERM, SIGBREAK]
        #else
        [SIGINT, SIGTERM]
        #endif
    }

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
    /// - **On Windows** the setup differs: the C runtime's `signal()` handler, not `sigaction`,
    ///   catches the signals, and it runs on a thread the runtime starts for each Ctrl-C and
    ///   Ctrl-Break. The runtime resets a caught signal to its default before it calls the
    ///   handler, so the handler arms the signal again at once; the second signal still ends the
    ///   process with `128 + signal`. Windows never raises SIGTERM for a process (only `raise`
    ///   in this process does), so a supervisor has to stop it another way. When the console
    ///   window is closed, Windows ends the process a moment after the close event, so a
    ///   graceful shutdown isn't guaranteed there. The signal tests are POSIX-only, so CI doesn't
    ///   cover these paths.
    ///
    /// - Parameter signals: The signals to catch. Defaults to SIGINT and SIGTERM (plus SIGBREAK
    ///   on Windows).
    public static func shutdownSignals(_ signals: [Int32] = defaultShutdownSignals) -> AsyncStream<Int32> {
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

#if os(Windows)
/// One `_write` to the pipe, with `errno` saved and restored. The pipe has no non-blocking mode
/// here, so a full pipe would block this thread until the reader drains it; the reader does so
/// at once, and 4096 bytes are far more than a person can send with Ctrl-C.
///
/// The runtime resets a caught signal to its default before it calls the handler (System V
/// semantics), so the first thing the handler does is arm the signal again. Without that, a
/// second Ctrl-C would end the process through the runtime default, not with `128 + signal`.
private func shutdownSignalHandler(_ signal: Int32) {
    _ = ucrt.signal(signal, shutdownSignalHandler)
    let saved = errno
    var byte = UInt8(truncatingIfNeeded: signal)
    _ = _write(shutdownSignalWriteFD, &byte, 1)
    errno = saved
}
#else
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
#endif

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
        #if os(Windows)
        // _pipe has no O_NONBLOCK / FD_CLOEXEC equivalents; _O_NOINHERIT keeps it from children.
        guard _pipe(&fds, 4096, _O_BINARY | _O_NOINHERIT) == 0 else {
            preconditionFailure("ShutdownSignals: _pipe() failed (errno \(errno))")
        }
        #else
        guard pipe(&fds) == 0 else {
            preconditionFailure("ShutdownSignals: pipe() failed (errno \(errno))")
        }
        // Not inherited by a child process; the write end never blocks the handler.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        #endif
        readFD = fds[0]
        shutdownSignalWriteFD = fds[1]
        let fd = readFD
        let thread = Thread { [self] in readLoop(fd: fd) }
        thread.name = "swiftstatetree.shutdown-signals"
        thread.start()
    }

    private func install(_ signal: Int32) {
        #if os(Windows)
        // `signal()` returns SIG_ERR, `(void (*)(int))-1`, for a signal the runtime doesn't support;
        // Swift doesn't import that name, so compare the bits.
        let previous = ucrt.signal(signal, shutdownSignalHandler)
        guard unsafeBitCast(previous, to: Int.self) != -1 else {
            preconditionFailure("ShutdownSignals: signal(\(signal)) failed (errno \(errno))")
        }
        #else
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
        #endif
    }

    private func readLoop(fd: Int32) {
        while true {
            var byte: UInt8 = 0
            #if os(Windows)
            let count = Int(_read(fd, &byte, 1))
            #else
            let count = read(fd, &byte, 1)
            #endif
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
