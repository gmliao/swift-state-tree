// Spike measurement only: CoW savepoint worst case, a first write into the largest dictionary
// (monsters) while a savepoint copy of the state is alive, versus the same write without it.
import Foundation

public enum SpikeSavepointBench {
    public static func run(sizes: [Int], iterations: Int) -> String {
        var lines: [String] = []
        for n in sizes {
            var state = HeroDefenseState()
            for i in 0..<n {
                var m = MonsterState()
                m.id = i
                state.monsters[i] = m
            }
            let without = measure(iterations) { i in
                state.monsters[i % n]?.health -= 1
            }
            let with = measure(iterations) { i in
                let savepoint = state
                state.monsters[i % n]?.health -= 1
                withExtendedLifetime(savepoint) {}
            }
            lines.append("monsters=\(n) without p50=\(without.p50)us p99=\(without.p99)us max=\(without.max)us | with p50=\(with.p50)us p99=\(with.p99)us max=\(with.max)us | checksum=\(state.monsters[0]?.health ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    private static func measure(_ iterations: Int, _ body: (Int) -> Void) -> (p50: Double, p99: Double, max: Double) {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for i in 0..<iterations {
            let start = ContinuousClock.now
            body(i)
            let c = (ContinuousClock.now - start).components
            samples.append(Double(c.seconds) * 1e6 + Double(c.attoseconds) / 1e12)
        }
        samples.sort()
        let at = { (q: Double) in (samples[min(samples.count - 1, Int(Double(samples.count) * q))] * 100).rounded() / 100 }
        return (at(0.5), at(0.99), (samples.last! * 100).rounded() / 100)
    }
}
