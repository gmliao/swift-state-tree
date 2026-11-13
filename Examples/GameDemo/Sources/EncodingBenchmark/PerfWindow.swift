// Examples/GameDemo/Sources/EncodingBenchmark/PerfWindow.swift
//
// The perf counter window (#517): with ENCODING_BENCHMARK_PERF_CONTROL set, the serial
// multi-room runners enable perf's counters around the off-path span of every timed iteration
// and disable them before `syncNow()`, so `perf stat --delay=-1 --control fifo:<ctl>,<ack>`
// counts that span only. Unset, nothing here runs.

import Foundation
import LoadTestPacing

enum PerfWindowRun {
    /// The open window, set once in `main()` before any run; nil without the env.
    nonisolated(unsafe) static var current: PerfWindow?

    /// Opens the window the environment asks for. Exits with a message on a malformed setting or
    /// a FIFO that can't be opened.
    static func start(config: BenchmarkConfig, isMultiRoom: Bool) {
        let settings: PerfControlSettings?
        do {
            settings = try PerfControlSettings.fromEnvironment()
        } catch {
            refuse(error.description)
        }
        guard let settings else { return }
        if let refusal = refusal(config, isMultiRoom: isMultiRoom) {
            refuse(refusal)
        }
        do {
            let control = try PerfControl(controlPath: settings.controlPath, ackPath: settings.ackPath)
            current = PerfWindow(mode: settings.mode, control: control)
        } catch {
            refuse(error.description)
        }
    }

    /// Why a window can't bracket this run, or nil. Only one serial multi-room run per process
    /// has a span to bracket and one count to attribute.
    static func refusal(_ config: BenchmarkConfig, isMultiRoom: Bool) -> String? {
        let unsupported = [
            (config.parallel, "parallel runs (pass --parallel false)"),
            (config.runAll, "--all (one window per run keeps the counts attributable)"),
            (config.compareParallel, "--compare-parallel"),
            (config.scalabilityTest, "--scalability"),
            (config.hashCost, "--hash-cost"),
            (config.compareWorkerPool, "--compare-worker-pool"),
            (config.useWorkerPool, "--use-worker-pool"),
            (!isMultiRoom, "the single-room path (use the multi-room options)"),
        ].filter(\.0).map(\.1)
        guard !unsupported.isEmpty else { return nil }
        return "\(PerfControlEnvKeys.control) doesn't support \(unsupported.joined(separator: ", "))"
    }

    private static func refuse(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
        exit(2)
    }
}

/// Brackets one span per room and iteration. `begin(_:)` / `end(_:)` act only for the span the
/// mode names, so each runner marks both spans and the mode picks one.
final class PerfWindow {
    let mode: PerfWindowMode
    private let control: PerfControl

    init(mode: PerfWindowMode, control: PerfControl) {
        self.mode = mode
        self.control = control
    }

    func begin(_ span: PerfWindowMode) {
        guard span == mode else { return }
        do { try control.enable() } catch { fatalError("\(error)") }
    }

    func end(_ span: PerfWindowMode) {
        guard span == mode else { return }
        do { try control.disable() } catch { fatalError("\(error)") }
    }

    /// Either mode: in the generic runner both name the tick loop.
    func beginEither() { begin(mode) }

    func endEither() { end(mode) }

    /// `perfWindow` in the result JSON, after checking the window ran and closed.
    func report() -> [String: Any] {
        guard control.toggles > 0, !control.isEnabled else {
            fatalError("perf window \(mode.rawValue): \(control.toggles) toggles, enabled at the end: \(control.isEnabled)")
        }
        return ["mode": mode.rawValue, "toggles": control.toggles]
    }
}
