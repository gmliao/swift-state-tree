import Foundation

final class TransportCodecSizeProfiler: @unchecked Sendable {
    private struct Stats {
        var encodeCount: UInt64 = 0
        var decodeCount: UInt64 = 0
        var encodedBytes: UInt64 = 0
        var decodedBytes: UInt64 = 0
    }

    static let shared = TransportCodecSizeProfiler()
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["SST_TRANSPORT_SIZE_PROFILE"] == "1"
    private let lock = NSLock()
    private var statsByEncoding: [TransportEncoding: Stats] = [:]
    private var didRegister = false

    func enableIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegister else { return }
        didRegister = true
        atexit {
            TransportCodecSizeProfiler.shared.report()
        }
    }

    func recordEncode(encoding: TransportEncoding, bytes: Int) {
        lock.lock()
        var stats = statsByEncoding[encoding] ?? Stats()
        stats.encodeCount += 1
        stats.encodedBytes += UInt64(bytes)
        statsByEncoding[encoding] = stats
        lock.unlock()
    }

    func recordDecode(encoding: TransportEncoding, bytes: Int) {
        lock.lock()
        var stats = statsByEncoding[encoding] ?? Stats()
        stats.decodeCount += 1
        stats.decodedBytes += UInt64(bytes)
        statsByEncoding[encoding] = stats
        lock.unlock()
    }

    func report() {
        lock.lock()
        let snapshot = statsByEncoding
        lock.unlock()

        print("")
        print("Transport codec size profile (SST_TRANSPORT_SIZE_PROFILE=1)")
        for encoding in snapshot.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let stats = snapshot[encoding] else { continue }
            let encodeAvg = stats.encodeCount > 0
                ? Double(stats.encodedBytes) / Double(stats.encodeCount)
                : 0.0
            let decodeAvg = stats.decodeCount > 0
                ? Double(stats.decodedBytes) / Double(stats.decodeCount)
                : 0.0
            let encodeAvgString = String(format: "%.1f", encodeAvg)
            let decodeAvgString = String(format: "%.1f", decodeAvg)
            print("\(encoding.rawValue): encode \(stats.encodeCount) ops, \(stats.encodedBytes) bytes, avg \(encodeAvgString) bytes/op")
            print("\(encoding.rawValue): decode \(stats.decodeCount) ops, \(stats.decodedBytes) bytes, avg \(decodeAvgString) bytes/op")
        }
        print("")
    }
}
