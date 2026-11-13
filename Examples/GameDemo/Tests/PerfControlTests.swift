import Foundation
import Testing
import LoadTestPacing
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `PerfControl`: the client side of perf's `--control fifo:<ctl>,<ack>` protocol, against a fake
/// perf that reads command lines and answers each with `ack\n` and a NUL, as perf does.
@Suite("Perf control window")
struct PerfControlTests {
    @Test("Settings: unset is no window; nonsync is the default; malformed values are refused")
    func settings() throws {
        #expect(try PerfControlSettings.fromEnvironment([:]) == nil)
        #expect(
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.control: "/c,/a"])
                == PerfControlSettings(controlPath: "/c", ackPath: "/a", mode: .nonsync))
        #expect(
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.control: "/c,/a", PerfControlEnvKeys.window: "ticks"])
                == PerfControlSettings(controlPath: "/c", ackPath: "/a", mode: .ticks))
        #expect(throws: PerfControlError.malformedControl("/c")) {
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.control: "/c"])
        }
        #expect(throws: PerfControlError.malformedControl("/c,")) {
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.control: "/c,"])
        }
        #expect(throws: PerfControlError.unknownWindow("sync")) {
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.control: "/c,/a", PerfControlEnvKeys.window: "sync"])
        }
        #expect(throws: PerfControlError.windowWithoutControl) {
            try PerfControlSettings.fromEnvironment([PerfControlEnvKeys.window: "ticks"])
        }
    }

    @Test("Each enable and disable is sent as a line and waits for its ack")
    func roundTrip() throws {
        let fifos = try Fifos()
        let perf = FakePerf(fifos: fifos, answers: 4)
        let control = try PerfControl(controlPath: fifos.control, ackPath: fifos.ack)
        try control.enable()
        #expect(control.isEnabled)
        try control.disable()
        try control.enable()
        try control.disable()
        #expect(control.toggles == 4)
        #expect(!control.isEnabled)
        #expect(perf.finish() == ["enable", "disable", "enable", "disable"])
    }

    @Test("Unbalanced brackets are refused before anything is sent")
    func unbalanced() throws {
        let fifos = try Fifos()
        let perf = FakePerf(fifos: fifos, answers: 0)
        let control = try PerfControl(controlPath: fifos.control, ackPath: fifos.ack)
        #expect(throws: PerfControlError.unbalanced(command: "disable")) { try control.disable() }
        #expect(control.toggles == 0)
        #expect(perf.finish() == [])
    }

    @Test("A closed ack FIFO is an error, not a silent miss")
    func noAck() throws {
        let fifos = try Fifos()
        // Answers nothing: reads the command, then closes its end of the ack FIFO.
        let perf = FakePerf(fifos: fifos, answers: 0, readsBeforeClose: 1)
        let control = try PerfControl(controlPath: fifos.control, ackPath: fifos.ack)
        #expect(throws: PerfControlError.noAck(path: fifos.ack, received: "")) { try control.enable() }
        #expect(perf.finish() == ["enable"])
    }
}

/// Two FIFOs in a fresh temporary directory, removed on deinit.
private final class Fifos {
    let directory: URL
    let control: String
    let ack: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-control-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        control = directory.appendingPathComponent("ctl").path
        ack = directory.appendingPathComponent("ack").path
        guard mkfifo(control, 0o600) == 0, mkfifo(ack, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Plays perf's side on its own thread: opens the control FIFO for reading and the ack FIFO for
/// writing (in the order the client opens its ends), reads command lines, and answers the first
/// `answers` of them with `ack\n\0`. With `readsBeforeClose`, it reads that many commands
/// without answering, then closes both ends.
private final class FakePerf: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var commands: [String] = []

    init(fifos: Fifos, answers: Int, readsBeforeClose: Int? = nil) {
        let controlPath = fifos.control
        let ackPath = fifos.ack
        Thread.detachNewThread { [self] in
            let control = open(controlPath, O_RDONLY)
            let ack = open(ackPath, O_WRONLY)
            defer {
                close(control)
                close(ack)
                done.signal()
            }
            var answered = 0
            var received = 0
            while true {
                if let limit = readsBeforeClose, received == limit { return }
                if readsBeforeClose == nil, answered == answers { return }
                guard let line = Self.readLine(control) else { return }
                received += 1
                lock.withLock { commands.append(line) }
                if readsBeforeClose == nil {
                    let reply: [UInt8] = Array("ack\n".utf8) + [0]
                    _ = reply.withUnsafeBytes { write(ack, $0.baseAddress, $0.count) }
                    answered += 1
                }
            }
        }
    }

    /// Waits for the fake to close its ends (the client's next read sees EOF) and returns the
    /// commands it received.
    func finish() -> [String] {
        done.wait()
        return lock.withLock { commands }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            guard read(fd, &byte, 1) == 1 else { return nil }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
}
