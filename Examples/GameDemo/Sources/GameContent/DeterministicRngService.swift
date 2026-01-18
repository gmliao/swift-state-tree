import Foundation

public final class DeterministicRngService: @unchecked Sendable {
    private var rng: DeterministicRng
    private let lock = NSLock()

    public init(seed: UInt64) {
        self.rng = DeterministicRng(seed: seed)
    }

    public func nextInt(in range: ClosedRange<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextInt(in: range)
    }

    public func nextInt(in range: Range<Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextInt(in: range)
    }

    public func nextFloat(in range: Range<Float>) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return rng.nextFloat(in: range)
    }
}
