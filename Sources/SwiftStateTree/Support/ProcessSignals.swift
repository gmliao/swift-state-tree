#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Process-wide signal setup for programs that host lands or write a lot of output (#273).
public enum ProcessSignals {
    /// Ignores SIGPIPE for the whole process, so a write to a closed pipe or socket returns
    /// `EPIPE` instead of ending the process. The throwing writes (`FileHandle.write(contentsOf:)`)
    /// then turn it into an error the caller handles: the log handler drops the line, the stderr
    /// diagnostics are skipped.
    ///
    /// Call it first in `main`, before any output. It changes a process-wide setting, so the
    /// library never calls it for you. Things to know:
    /// - **Linux:** SwiftNIO already ignores SIGPIPE for the whole process the first time it
    ///   creates a socket. This call covers what runs before that, and programs that never open
    ///   one.
    /// - **Darwin:** NIO protects only its own descriptors (`F_SETNOSIGPIPE`). Without this
    ///   call, a closed stdout or stderr pipe ends the process.
    /// - **Children:** an ignored signal stays ignored across `exec`, so a child process you
    ///   spawn sees `EPIPE` too, unless it resets SIGPIPE itself.
    ///
    /// Calling it again does nothing. Tested on Linux (Glibc); untested on Musl (static Linux)
    /// and Darwin, though both use the same `signal()` call.
    ///
    /// - Returns: whether this call changed the disposition (false when SIGPIPE was ignored
    ///   already, or where the platform has no SIGPIPE).
    @discardableResult
    public static func ignoreSIGPIPE() -> Bool {
        #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
        let previous = signal(SIGPIPE, SIG_IGN)
        return handlerAddress(previous) != handlerAddress(SIG_IGN)
        #else
        return false
        #endif
    }

    /// Whether SIGPIPE is ignored for this process now (tests). Reads the disposition without
    /// changing it.
    static func isSIGPIPEIgnored() -> Bool {
        #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0 else { return false }
        // The handler field is named differently in each C library's `struct sigaction`; the
        // order matches the imports at the top of the file.
        #if canImport(Glibc)
        let handler = current.__sigaction_handler.sa_handler
        #elseif canImport(Musl)
        // Untested on Musl: no static Linux SDK was available when this was written.
        let handler = current.__sa_handler.sa_handler
        #else
        let handler = current.__sigaction_u.__sa_handler
        #endif
        return handlerAddress(handler) == handlerAddress(SIG_IGN)
        #else
        return false
        #endif
    }

    #if canImport(Glibc) || canImport(Musl) || canImport(Darwin)
    /// A signal handler as an address: `SIG_IGN` and `SIG_DFL` are sentinel values (1 and 0),
    /// not functions, so they are compared by value.
    private static func handlerAddress(_ handler: (@convention(c) (Int32) -> Void)?) -> Int {
        unsafeBitCast(handler, to: Int.self)
    }
    #endif
}
