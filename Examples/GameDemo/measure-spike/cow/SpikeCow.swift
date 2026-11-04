// Spike measurement only (not for merge): CoW copy accounting for @Sync collections (SPIKE_COW=1).
//
// On each mutation through `Sync.wrappedValue` (an emulated get/set `_modify`), two copies are
// forced and timed separately:
// - "holder": the stored buffer is made unique in place first. It copies only when someone else
//   holds the buffer (a sync snapshot from beginSync, a cached previous state, ...): the copy a
//   `_modify` accessor would still pay once #94 is fixed.
// - "94": the get/set temporary is made unique: the copy every nested write pays today (#94).
// Holder copies made while the keeper is inside beginSync ... endSync are also counted per cycle.

import Foundation

public protocol _SpikeCowOps {
    /// Makes the collection at `p` unique; returns (copied, elements, shallow bytes).
    static func spikeForceUnique(_ p: UnsafeMutableRawPointer) -> (Bool, Int, Int)
}

extension Dictionary: _SpikeCowOps {
    public static func spikeForceUnique(_ p: UnsafeMutableRawPointer) -> (Bool, Int, Int) {
        let d = p.assumingMemoryBound(to: Self.self)
        let n = d.pointee.count
        guard n > 0 else { return (false, 0, 0) }
        let before = p.load(as: UInt.self)
        d.pointee.reserveCapacity(0)
        return (p.load(as: UInt.self) != before, n, n * MemoryLayout<Element>.stride)
    }
}

extension Array: _SpikeCowOps {
    public static func spikeForceUnique(_ p: UnsafeMutableRawPointer) -> (Bool, Int, Int) {
        let a = p.assumingMemoryBound(to: Self.self)
        let n = a.pointee.count
        guard n > 0 else { return (false, 0, 0) }
        let before = p.load(as: UInt.self)
        a.pointee.reserveCapacity(0)
        return (p.load(as: UInt.self) != before, n, n * MemoryLayout<Element>.stride)
    }
}

extension Set: _SpikeCowOps {
    public static func spikeForceUnique(_ p: UnsafeMutableRawPointer) -> (Bool, Int, Int) {
        let s = p.assumingMemoryBound(to: Self.self)
        let n = s.pointee.count
        guard n > 0 else { return (false, 0, 0) }
        let before = p.load(as: UInt.self)
        s.pointee.reserveCapacity(0)
        return (p.load(as: UInt.self) != before, n, n * MemoryLayout<Element>.stride)
    }
}

public enum SpikeCow {
    public static let enabled: Bool = ProcessInfo.processInfo.environment["SPIKE_COW"] == "1"

    /// Per-keeper accumulator, installed as the thread's current one around synchronous mutations.
    public final class Cycle: @unchecked Sendable {
        public var syncing = false
        public var holderCopies = 0
        public var holderBytes = 0
        public init() {}
    }

    private static let key: pthread_key_t = {
        var k = pthread_key_t()
        pthread_key_create(&k, nil)
        return k
    }()

    @inline(__always)
    public static func with<R>(_ cycle: Cycle, _ body: () throws -> R) rethrows -> R {
        guard enabled else { return try body() }
        let previous = pthread_getspecific(key)
        pthread_setspecific(key, Unmanaged.passUnretained(cycle).toOpaque())
        defer { pthread_setspecific(key, previous) }
        return try body()
    }

    private static func ns(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) * 1_000_000_000 + Int(c.attoseconds / 1_000_000_000)
    }

    public static func noteHolder(bytes: Int, duration: Duration) {
        SpikeMetrics.count("cowHolderCopies")
        SpikeMetrics.count("cowHolderBytes", by: bytes)
        SpikeMetrics.count("cowHolderNs", by: ns(duration))
        if let p = pthread_getspecific(key) {
            let cycle = Unmanaged<Cycle>.fromOpaque(p).takeUnretainedValue()
            if cycle.syncing {
                cycle.holderCopies += 1
                cycle.holderBytes += bytes
                SpikeMetrics.count("cowHolderCopiesInSync")
            }
        }
    }

    public static func note94(bytes: Int, duration: Duration) {
        SpikeMetrics.count("cow94Copies")
        SpikeMetrics.count("cow94Bytes", by: bytes)
        SpikeMetrics.count("cow94Ns", by: ns(duration))
    }

    public static func beginCycle(_ cycle: Cycle) {
        guard enabled else { return }
        cycle.syncing = true
        cycle.holderCopies = 0
        cycle.holderBytes = 0
    }

    public static func endCycle(_ cycle: Cycle) {
        guard enabled, cycle.syncing else { return }
        cycle.syncing = false
        // Per-cycle counts stored as "microseconds" so the histogram holds the exact integer.
        SpikeMetrics.record("cowHolderPerCycle", duration: .microseconds(cycle.holderCopies))
        SpikeMetrics.count("cowCycles")
    }
}
