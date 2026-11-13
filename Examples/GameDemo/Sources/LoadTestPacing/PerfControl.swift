// Examples/GameDemo/Sources/LoadTestPacing/PerfControl.swift
//
// A client for Linux perf's control FIFOs, so a benchmark can count events over a chosen span
// only: `perf stat --delay=-1 --control fifo:<ctl>,<ack> -- <benchmark>` starts with the events
// disabled, and the benchmark writes `enable` / `disable` around the span (#517).

import Foundation
import SwiftStateTree
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Environment keys of the perf counter window.
public enum PerfControlEnvKeys {
    /// `<ctl-fifo>,<ack-fifo>`: the two FIFOs given to perf's `--control fifo:<ctl>,<ack>`.
    /// Both are required: without the ack a toggle races the span it brackets.
    public static let control = "ENCODING_BENCHMARK_PERF_CONTROL"
    /// `nonsync` (default), `ticks` or `iteration`: which span the counters cover.
    public static let window = "ENCODING_BENCHMARK_PERF_WINDOW"
}

/// The span a perf counter window covers in the serial multi-room runners.
public enum PerfWindowMode: String, Sendable, CaseIterable {
    /// Everything in a timed iteration except `syncNow()`: what `timeMs − syncMs` measures.
    case nonsync
    /// The `stepTickOnce()` loop only. It leaves out the input injection (the hero-defense
    /// runner's moves, the generic runner's `--actions-per-player`); without injected inputs it
    /// is the same span as `nonsync` in the generic runner.
    case ticks
    /// The whole timed iteration, every room's inputs, ticks and `syncNow()`: what `timeMs`
    /// measures. For work whose place inside the iteration isn't fixed, such as server event
    /// encode (in the sync phase under in-turn sync, at the tick's flush otherwise).
    case iteration
}

public enum PerfControlError: Error, Equatable, CustomStringConvertible {
    case malformedControl(String)
    case windowWithoutControl
    case unknownWindow(String)
    case openFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)
    /// The ack FIFO closed or returned something other than `ack` before the command was applied.
    case noAck(path: String, received: String)
    /// `enable` while enabled or `disable` while disabled: the brackets are unbalanced.
    case unbalanced(command: String)

    public var description: String {
        switch self {
        case .malformedControl(let raw):
            return "\(PerfControlEnvKeys.control)=\(raw): expected <ctl-fifo>,<ack-fifo>"
        case .windowWithoutControl:
            return "\(PerfControlEnvKeys.window) is set but \(PerfControlEnvKeys.control) isn't"
        case .unknownWindow(let raw):
            let modes = PerfWindowMode.allCases.map(\.rawValue).joined(separator: "|")
            return "\(PerfControlEnvKeys.window)=\(raw): expected \(modes)"
        case .openFailed(let path, let code):
            return "perf control: can't open \(path) (errno \(code))"
        case .writeFailed(let path, let code):
            return "perf control: write to \(path) failed (errno \(code))"
        case .noAck(let path, let received):
            return "perf control: no ack on \(path) (received \(received.debugDescription))"
        case .unbalanced(let command):
            return "perf control: unbalanced \(command)"
        }
    }
}

/// The parsed perf window settings; nil when the environment doesn't ask for a window.
public struct PerfControlSettings: Equatable, Sendable {
    public let controlPath: String
    public let ackPath: String
    public let mode: PerfWindowMode

    public init(controlPath: String, ackPath: String, mode: PerfWindowMode) {
        self.controlPath = controlPath
        self.ackPath = ackPath
        self.mode = mode
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(PerfControlError) -> PerfControlSettings? {
        let control = EnvHelpers.getEnvStringOptional(key: PerfControlEnvKeys.control, environment: environment)
        let window = EnvHelpers.getEnvStringOptional(key: PerfControlEnvKeys.window, environment: environment)
        guard let control else {
            if window != nil { throw .windowWithoutControl }
            return nil
        }
        let parts = control.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw .malformedControl(control)
        }
        let mode: PerfWindowMode
        if let window {
            guard let parsed = PerfWindowMode(rawValue: window) else { throw .unknownWindow(window) }
            mode = parsed
        } else {
            mode = .nonsync
        }
        return PerfControlSettings(controlPath: parts[0], ackPath: parts[1], mode: mode)
    }
}

/// Writes perf's `enable` / `disable` commands and waits for each ack, so the counters are on
/// before the span's first instruction and off before the next span starts.
///
/// Not thread-safe: the serial runners call it from one task, one bracket at a time.
public final class PerfControl {
    public let controlPath: String
    public let ackPath: String
    /// Commands sent (each `enable` and each `disable`).
    public private(set) var toggles = 0
    public private(set) var isEnabled = false
    private let controlFD: Int32
    private let ackFD: Int32

    /// Opens both FIFOs. perf holds its ends open from its start, so neither open blocks for long.
    public init(controlPath: String, ackPath: String) throws(PerfControlError) {
        self.controlPath = controlPath
        self.ackPath = ackPath
        let control = open(controlPath, O_WRONLY)
        guard control >= 0 else { throw .openFailed(path: controlPath, errno: errno) }
        let ack = open(ackPath, O_RDONLY)
        guard ack >= 0 else {
            let code = errno
            close(control)
            throw .openFailed(path: ackPath, errno: code)
        }
        controlFD = control
        ackFD = ack
    }

    deinit {
        close(controlFD)
        close(ackFD)
    }

    public func enable() throws(PerfControlError) {
        guard !isEnabled else { throw .unbalanced(command: "enable") }
        try send("enable")
        isEnabled = true
    }

    public func disable() throws(PerfControlError) {
        guard isEnabled else { throw .unbalanced(command: "disable") }
        try send("disable")
        isEnabled = false
    }

    private func send(_ command: String) throws(PerfControlError) {
        let line = Array("\(command)\n".utf8)
        let written = line.withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }
        guard written == line.count else { throw .writeFailed(path: controlPath, errno: errno) }
        toggles += 1
        try readAck()
    }

    /// perf answers each command with `ack\n` and a NUL. NULs are skipped, so the reply is
    /// accepted whether or not the previous reply's NUL was read with it.
    private func readAck() throws(PerfControlError) {
        var received: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = read(ackFD, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else {
                throw .noAck(path: ackPath, received: String(decoding: received, as: UTF8.self))
            }
            if byte == 0 { continue }
            if byte == UInt8(ascii: "\n") { break }
            received.append(byte)
            if received.count > 64 { break }
        }
        guard received == Array("ack".utf8) else {
            throw .noAck(path: ackPath, received: String(decoding: received, as: UTF8.self))
        }
    }
}
