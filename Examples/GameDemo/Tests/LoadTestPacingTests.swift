// Tests/LoadTestPacingTests.swift
//
// Pacing of the in-process load generator (ServerLoadTest): send offsets, plans, and a dry run
// with a counting sender and a deadline-based sampler.

import Foundation
import LoadTestPacing
import Testing

private actor SendLog {
    private(set) var times: [ContinuousClock.Instant] = []
    /// The period each send was scheduled for, parallel to `times`.
    private(set) var periods: [Int] = []
    func record(period: Int) {
        times.append(ContinuousClock.now)
        periods.append(period)
    }
    var count: Int { times.count }
}

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@Suite("LoadTestPacing")
struct LoadTestPacingTests {
    @Test("A ramp-down period's actions never target a session it closes")
    func rampDownActionsSkipClosingSessions() {
        let joined = ["s1", "s2", "s3", "s4", "s5"]
        let split = LoadTestPacing.rampDownPeriod(joined: joined, closeCount: 2)
        #expect(split.closing == ["s1", "s2"])
        #expect(split.actionTargets == ["s3", "s4", "s5"])
        #expect(Set(split.closing).isDisjoint(with: split.actionTargets))
        // The last ramp-down second closes everyone: no actions are planned.
        let last = LoadTestPacing.rampDownPeriod(joined: joined, closeCount: 8)
        #expect(last.closing == joined && last.actionTargets.isEmpty)
        // Every planned action reaches an open session, so all of them can be recorded.
        let plan = LoadTestPacing.actionPlan(keys: split.actionTargets, perKey: 4, period: .seconds(1))
        #expect(plan.count == 12)
        #expect(plan.allSatisfy { !split.closing.contains(split.actionTargets[$0.index]) })
    }

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

    @Test("An aligned plan puts every send at the period start")
    func alignedPlan() {
        let plan = LoadTestPacing.actionPlan(keys: ["a", "b"], perKey: 3, period: .seconds(1), mode: .aligned)
        #expect(plan.count == 6)
        #expect(plan.allSatisfy { $0.offset == .zero })
        #expect(LoadTestPacing.joinPlan(count: 3, period: .seconds(1), mode: .aligned).allSatisfy { $0.offset == .zero })
    }

    /// Runs `periods` periods of `keys` sessions at 1 send per period, with a sampler that reads
    /// the cumulative count at each period's end.
    private func dryRun(mode: LoadTestPacing.Mode, keys: Int, period: Duration, periods: Int)
        async -> (log: [ContinuousClock.Instant], scheduledPeriods: [Int], samples: [Int], origin: ContinuousClock.Instant)
    {
        let log = SendLog()
        let names = (0 ..< keys).map { "room-\($0 / 5)-s\($0 % 5)" }
        let origin = ContinuousClock.now + .milliseconds(20)
        let generator = Task {
            await LoadTestPacing.runPeriods(
                origin: origin,
                period: period,
                count: periods,
                limit: LoadTestPacing.InFlightLimit(cap: 10_000),
                plan: { p in
                    LoadTestPacing.actionPlan(keys: names, perKey: 1, period: period, mode: mode)
                        .map { LoadTestPacing.Scheduled(offset: $0.offset, item: p) }
                },
                perform: { p in await log.record(period: p) }
            )
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
        return (await log.times, await log.periods, samples, origin)
    }

    @Test("Dry run: spread sends cover the period and every sample is near the target")
    func dryRunSpread() async {
        let period = Duration.milliseconds(400)
        let (times, _, samples, origin) = await dryRun(mode: .spread, keys: 100, period: period, periods: 3)
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

    @Test("Dry run: aligned sends arrive together at the period start")
    func dryRunAligned() async {
        let period = Duration.milliseconds(400)
        let (times, scheduledPeriods, _, origin) = await dryRun(mode: .aligned, keys: 100, period: period, periods: 3)
        #expect(times.count == 300)
        // Counted by the period each send was scheduled for, not by when a sampler woke up: a
        // late sampler wake (CI runners) moved sends across sample windows before.
        for p in 0 ..< 3 {
            let start = origin + period * p
            let lags = zip(times, scheduledPeriods).filter { $0.1 == p }.map { milliseconds($0.0 - start) }
            #expect(lags.count == 100)
            // Loose timing check: aligned sends go out at the period start, not spread over it.
            #expect(lags.allSatisfy { $0 >= 0 }, "period \(p) lags \(lags.min() ?? 0)")
            #expect((lags.max() ?? 400) < 200, "period \(p) max lag \(lags.max() ?? 0) ms")
        }
    }

    @Test("A slow sender doesn't stretch periods: in-flight sends are recorded and the cap holds")
    func slowSender() async {
        // 20 sends per 100 ms period, each taking 250 ms, cap 30.
        let period = Duration.milliseconds(100)
        let concurrency = Concurrency()
        let stats = StatsLog()
        let origin = ContinuousClock.now + .milliseconds(20)
        let started = ContinuousClock.now
        await LoadTestPacing.runPeriods(
            origin: origin,
            period: period,
            count: 4,
            limit: LoadTestPacing.InFlightLimit(cap: 30),
            // macOS timer leeway delays short sleeps by up to ~10 ms.
            lateAfter: .milliseconds(40),
            plan: { _ in (0 ..< 20).map { LoadTestPacing.Scheduled(offset: period / 20 * $0, item: $0) } },
            perform: { _ in
                await concurrency.enter()
                try? await Task.sleep(for: .milliseconds(250))
                await concurrency.leave()
            },
            onPeriod: { await stats.append($0) }
        )
        let periods = await stats.all
        #expect(periods.count == 4)
        // Each period starts on its own deadline, not after the previous period's sends.
        #expect(periods.allSatisfy { $0.startLag < .milliseconds(40) && !$0.late }, "\(periods)")
        // Earlier sends are still in flight at later deadlines, and the cap skips the excess.
        #expect(periods[0].inFlightAtDeadline == 0)
        #expect(periods[1].inFlightAtDeadline == 20)
        #expect(periods[1].skippedByCap == 10)
        #expect(periods[2].skippedByCap > 0)
        #expect(periods.allSatisfy { $0.started + $0.skippedByCap == $0.planned })
        // Never more than the cap at once: no catch-up burst beyond it.
        #expect(await concurrency.peak <= 30)
        // 4 periods plus the last sends' 250 ms, not 4 × 250 ms of serialized periods.
        #expect(ContinuousClock.now - started < .milliseconds(900))
    }

    @Test("A slow period is recorded as late, and its catch-up sends stay within the cap")
    func latePeriod() async {
        // Planning period 1 takes 250 ms (> the 100 ms period): periods 1-3 start late.
        let period = Duration.milliseconds(100)
        let concurrency = Concurrency()
        let stats = StatsLog()
        let origin = ContinuousClock.now + .milliseconds(20)
        await LoadTestPacing.runPeriods(
            origin: origin,
            period: period,
            count: 4,
            limit: LoadTestPacing.InFlightLimit(cap: 15),
            lateAfter: .milliseconds(40),
            plan: { p in
                if p == 1 { try? await Task.sleep(for: .milliseconds(250)) }
                return (0 ..< 10).map { LoadTestPacing.Scheduled(offset: period / 10 * $0, item: $0) }
            },
            perform: { _ in
                await concurrency.enter()
                try? await Task.sleep(for: .milliseconds(30))
                await concurrency.leave()
            },
            onPeriod: { await stats.append($0) }
        )
        let periods = await stats.all
        #expect(periods.count == 4)
        #expect(!periods[0].late)
        #expect(periods[1].late)
        #expect(periods[1].startLag >= .milliseconds(240))
        // Period 1's sends were all overdue and started at once, bounded by the cap.
        #expect(await concurrency.peak <= 15)
        #expect(periods.filter(\.late).count >= 2)
    }

    @Test("Cancelling a run stops it: no further period starts")
    func cancellation() async {
        let period = Duration.milliseconds(50)
        let stats = StatsLog()
        let planned = Counter()
        let origin = ContinuousClock.now + .milliseconds(10)
        let run = Task {
            await LoadTestPacing.runPeriods(
                origin: origin,
                period: period,
                count: 20,
                limit: LoadTestPacing.InFlightLimit(cap: 100),
                plan: { _ in
                    await planned.increment()
                    return (0 ..< 5).map { LoadTestPacing.Scheduled(offset: period / 5 * $0, item: $0) }
                },
                perform: { _ in },
                onPeriod: { await stats.append($0) }
            )
        }
        // Cancel inside period 2.
        await LoadTestPacing.sleep(until: origin + period * 2 + .milliseconds(20))
        run.cancel()
        let cancelledAt = ContinuousClock.now
        await run.value
        #expect(ContinuousClock.now - cancelledAt < .milliseconds(30))
        let plannedPeriods = await planned.value
        #expect(plannedPeriods >= 2 && plannedPeriods <= 4, "planned \(plannedPeriods)")
        // Nothing starts after the cancel, so the remaining 16+ periods never run.
        await LoadTestPacing.sleep(until: ContinuousClock.now + period * 3)
        #expect(await planned.value == plannedPeriods)
        #expect(await stats.all.count <= plannedPeriods)
    }

    @Test("A past deadline returns at once")
    func pastDeadline() async {
        let before = ContinuousClock.now
        await LoadTestPacing.sleep(until: before - .milliseconds(50))
        #expect(ContinuousClock.now - before < .milliseconds(20))
    }
}

private actor Concurrency {
    private var current = 0
    private(set) var peak = 0
    func enter() {
        current += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor StatsLog {
    private(set) var all: [LoadTestPacing.PeriodStats] = []
    func append(_ stats: LoadTestPacing.PeriodStats) { all.append(stats) }
}
