// Tests/LoadTestPacingTests.swift
//
// Pacing of the in-process load generator (ServerLoadTest): send offsets, plans, and a dry run
// with a counting sender and a deadline-based sampler.

import Foundation
import LoadTestPacing
import Testing

private actor SendLog {
    private(set) var times: [ContinuousClock.Instant] = []
    func record() { times.append(ContinuousClock.now) }
    var count: Int { times.count }
}

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@Suite("LoadTestPacing")
struct LoadTestPacingTests {
    @Test("Offsets are stable, inside the period, and spread keys that differ only at the end")
    func offsets() {
        let period = Duration.seconds(1)
        let keys = (0 ..< 1000).map { "session-\($0)" }
        let offsets = keys.map { milliseconds(LoadTestPacing.offset(for: $0, period: period)) }
        #expect(offsets.allSatisfy { $0 >= 0 && $0 < 1000 })
        #expect(LoadTestPacing.offset(for: "session-7", period: period) == LoadTestPacing.offset(for: "session-7", period: period))
        // Every tenth of the period gets some keys.
        let tenths = Set(offsets.map { Int($0 / 100) })
        #expect(tenths.count == 10)
        // One room's players (keys differing in the last character) are not bunched together.
        let room = (0 ..< 5).map { milliseconds(LoadTestPacing.offset(for: "room-3-s\($0)", period: period)) }.sorted()
        let gaps = zip(room.dropFirst(), room).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 > 2 })
    }

    @Test("A spread plan is time-ordered, with each key's sends one step apart")
    func spreadPlan() {
        let plan = LoadTestPacing.actionPlan(keys: ["a", "b", "c"], perKey: 2, period: .seconds(1))
        #expect(plan.count == 6)
        #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.offset <= $1.offset })
        for index in 0 ..< 3 {
            let sends = plan.filter { $0.index == index }.map(\.offset)
            #expect(sends.count == 2)
            #expect(sends[1] - sends[0] == .milliseconds(500))
            #expect(sends.allSatisfy { $0 >= .zero && $0 < .seconds(1) })
        }
        let joins = LoadTestPacing.joinPlan(count: 4, period: .seconds(1))
        #expect(joins.map(\.offset) == [.zero, .milliseconds(250), .milliseconds(500), .milliseconds(750)])
    }

    @Test("A burst plan puts every send at the period start")
    func burstPlan() {
        let plan = LoadTestPacing.actionPlan(keys: ["a", "b"], perKey: 3, period: .seconds(1), mode: .burst)
        #expect(plan.count == 6)
        #expect(plan.allSatisfy { $0.offset == .zero })
        #expect(LoadTestPacing.joinPlan(count: 3, period: .seconds(1), mode: .burst).allSatisfy { $0.offset == .zero })
    }

    /// Runs `periods` periods of `keys` sessions at 1 send per period on deadline-based periods,
    /// with a sampler that reads the cumulative count at each period's end.
    private func dryRun(mode: LoadTestPacing.Mode, keys: Int, period: Duration, periods: Int)
        async -> (log: [ContinuousClock.Instant], samples: [Int], origin: ContinuousClock.Instant)
    {
        let log = SendLog()
        let names = (0 ..< keys).map { "room-\($0 / 5)-s\($0 % 5)" }
        let origin = ContinuousClock.now + .milliseconds(20)
        let generator = Task {
            for p in 0 ..< periods {
                let start = origin + period * p
                let plan = LoadTestPacing.actionPlan(keys: names, perKey: 1, period: period, mode: mode)
                await LoadTestPacing.run(plan, from: start) { _ in await log.record() }
                await LoadTestPacing.sleep(until: start + period)
            }
        }
        var samples: [Int] = []
        var last = 0
        for p in 0 ..< periods {
            await LoadTestPacing.sleep(until: origin + period * (p + 1))
            let now = await log.count
            samples.append(now - last)
            last = now
        }
        await generator.value
        return (await log.times, samples, origin)
    }

    @Test("Dry run: spread sends cover the period and every sample is near the target")
    func dryRunSpread() async {
        let period = Duration.milliseconds(400)
        let (times, samples, origin) = await dryRun(mode: .spread, keys: 100, period: period, periods: 3)
        #expect(times.count == 300)
        for p in 0 ..< 3 {
            let start = origin + period * p
            let inPeriod = times.filter { $0 >= start && $0 < start + period }.map { milliseconds($0 - start) }
            // The sends span the period instead of arriving at its start.
            #expect((inPeriod.min() ?? 400) < 40)
            #expect((inPeriod.max() ?? 0) > 360)
            // No 10% slice of the period holds more than a quarter of its sends.
            let slices = Dictionary(grouping: inPeriod, by: { Int($0 / 40) }).values.map(\.count)
            #expect((slices.max() ?? 0) <= 25)
        }
        // A sample never catches 0 or 2 periods' sends; only sends right at a boundary move.
        #expect(samples.allSatisfy { abs($0 - 100) <= 10 }, "samples \(samples)")
    }

    @Test("Dry run: burst sends arrive together at the period start")
    func dryRunBurst() async {
        let period = Duration.milliseconds(400)
        let (times, samples, origin) = await dryRun(mode: .burst, keys: 100, period: period, periods: 3)
        #expect(times.count == 300)
        for p in 0 ..< 3 {
            let start = origin + period * p
            let inPeriod = times.filter { $0 >= start && $0 < start + period }.map { milliseconds($0 - start) }
            #expect(inPeriod.count == 100)
            #expect((inPeriod.max() ?? 400) < 100)
        }
        #expect(samples == [100, 100, 100])
    }

    @Test("A late period catches up instead of shifting later deadlines")
    func lateCatchUp() async {
        let origin = ContinuousClock.now
        // A deadline already in the past returns at once.
        let before = ContinuousClock.now
        await LoadTestPacing.sleep(until: origin - .milliseconds(50))
        #expect(ContinuousClock.now - before < .milliseconds(20))
        // Sends whose time has passed start at once, in plan order.
        let log = SendLog()
        let plan = LoadTestPacing.joinPlan(count: 5, period: .milliseconds(100))
        await LoadTestPacing.run(plan, from: origin - .seconds(1)) { _ in await log.record() }
        #expect(await log.count == 5)
        #expect(ContinuousClock.now - before < .milliseconds(50))
    }
}
