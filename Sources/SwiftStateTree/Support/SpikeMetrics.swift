// Measurement only (do not merge): env-gated latency histograms and counters.
// SPIKE_METRICS_PATH=<file.jsonl> enables it; every SPIKE_METRICS_INTERVAL_S (default 5) seconds
// one JSON line with that window's histograms (microsecond buckets) and counters is appended.

import Foundation

public enum SpikeMetrics {
    public static let isEnabled: Bool = ProcessInfo.processInfo.environment["SPIKE_METRICS_PATH"] != nil

    @inline(__always)
    public static func now() -> ContinuousClock.Instant { ContinuousClock.now }

    @inline(__always)
    public static func record(_ name: String, since start: ContinuousClock.Instant) {
        guard isEnabled else { return }
        record(name, duration: ContinuousClock.now - start)
    }

    public static func record(_ name: String, duration: Duration) {
        guard isEnabled else { return }
        let c = duration.components
        let us = Int(c.seconds) * 1_000_000 + Int(c.attoseconds / 1_000_000_000_000)
        store.record(name, us: max(0, us))
    }

    public static func count(_ name: String, by n: Int = 1) {
        guard isEnabled else { return }
        store.count(name, by: n)
    }

    /// Prints the first adapter's in-turn sync decision to stderr, once per process
    /// (unconditional, not through the logger: run scripts may raise LOG_LEVEL).
    public static func reportAdapterInTurnSyncOnce(_ enabled: Bool, landID: String) {
        adapterReport.lock.lock()
        defer { adapterReport.lock.unlock() }
        guard !adapterReport.done else { return }
        adapterReport.done = true
        FileHandle.standardError.write(Data("effective inTurnSync=\(enabled) source=TransportAdapter land=\(landID)\n".utf8))
    }

    private final class OnceFlag: @unchecked Sendable {
        let lock = NSLock()
        var done = false
    }

    private static let adapterReport = OnceFlag()

    private static let store = Store()

    /// Buckets: 1 us up to 1 ms, 10 us up to 100 ms, 1 ms above (capped at 10 s).
    private static func bucket(_ us: Int) -> Int {
        if us < 1_000 { return us }
        if us < 100_000 { return us / 10 * 10 }
        return min(us, 10_000_000) / 1_000 * 1_000
    }

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var histograms: [String: [Int: Int]] = [:]
        private var counters: [String: Int] = [:]
        private let path: String
        private let interval: Double

        init() {
            let env = ProcessInfo.processInfo.environment
            path = env["SPIKE_METRICS_PATH"] ?? ""
            interval = Double(env["SPIKE_METRICS_INTERVAL_S"] ?? "") ?? 5
            guard !path.isEmpty else { return }
            FileManager.default.createFile(atPath: path, contents: nil)
            let thread = Thread { [self] in
                while true {
                    Thread.sleep(forTimeInterval: interval)
                    flush()
                }
            }
            thread.start()
        }

        func record(_ name: String, us: Int) {
            let b = SpikeMetrics.bucket(us)
            lock.lock()
            histograms[name, default: [:]][b, default: 0] += 1
            lock.unlock()
        }

        func count(_ name: String, by n: Int) {
            lock.lock()
            counters[name, default: 0] += n
            lock.unlock()
        }

        private func flush() {
            lock.lock()
            let h = histograms
            let c = counters
            histograms.removeAll(keepingCapacity: true)
            counters.removeAll(keepingCapacity: true)
            lock.unlock()
            var obj: [String: Any] = ["t": Date().timeIntervalSince1970, "counters": c]
            obj["hist"] = h.mapValues { buckets in buckets.sorted { $0.key < $1.key }.map { [$0.key, $0.value] } }
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
    }
}
