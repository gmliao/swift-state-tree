import { describe, it, expect } from "vitest";
import { parseSystemMetrics, serverCpuByPhase, summarizeServerCpu, withIntervalRates, type SystemMetricSample } from "../src/system-metrics";

/**
 * A synthetic cumulative series: one sample per second from wall time `t0`, monotonic from 0,
 * with the given CPU rate (percent, 100 = one core) over each interval ending at the sample.
 */
function series(t0: number, ratesPct: number[]): SystemMetricSample[] {
    const samples: SystemMetricSample[] = [{ ts: Math.floor(t0 / 1000), tsMs: t0, monoMs: 0, cpuSec: 5, cpuPct: null, rssMb: 1, load1: 0 }];
    let cpuSec = 5;
    ratesPct.forEach((rate, i) => {
        cpuSec += rate / 100;
        const tsMs = t0 + (i + 1) * 1000;
        samples.push({ ts: Math.floor(tsMs / 1000), tsMs, monoMs: (i + 1) * 1000, cpuSec, cpuPct: null, rssMb: 1, load1: 0 });
    });
    return samples;
}

describe("parseSystemMetrics", () => {
    it("parses partial JSON without closing bracket", () => {
        const raw = `{"system":[\n{"ts":1,"cpuPct":10,"rssMb":1.5,"load1":0.2}\n`;
        const metrics = parseSystemMetrics(raw);
        expect(metrics.system.length).toBe(1);
        expect(metrics.system[0].ts).toBe(1);
    });

    it("parses the collector's partial output (trailing commas) and derives interval rates", () => {
        const raw = `{"system":[\n{"ts":1,"tsMs":1000,"monoMs":0,"cpuSec":10,"rssMb":1,"load1":0},\n{"ts":2,"tsMs":2000,"monoMs":1000,"cpuSec":12.5,"rssMb":1,"load1":0}`;
        const metrics = parseSystemMetrics(raw);
        expect(metrics.system.map((sample) => sample.cpuPct)).toEqual([null, 250]);
    });

    it("leaves an older lifetime-average file's cpuPct as it was", () => {
        const raw = `{"system":[{"ts":1,"cpuPct":40,"rssMb":1,"load1":0},{"ts":2,"cpuPct":41,"rssMb":1,"load1":0}]}`;
        const metrics = parseSystemMetrics(raw);
        expect(metrics.system.map((sample) => sample.cpuPct)).toEqual([40, 41]);
        expect(serverCpuByPhase(metrics, [{ phase: "steady", startAt: 0, endAt: 10_000 }])).toBeNull();
    });
});

describe("server CPU rates", () => {
    it("are per interval, not a lifetime average", () => {
        // A ramp from idle to 800%: a lifetime average (cumulative / elapsed since start) would
        // lag far behind; the interval rate follows the load.
        const rates = withIntervalRates(series(1_000_000, [0, 0, 0, 800, 800, 800])).map((sample) => sample.cpuPct);
        expect(rates[0]).toBeNull();
        rates.slice(1).forEach((rate, i) => expect(rate).toBeCloseTo([0, 0, 0, 800, 800, 800][i], 6));
    });

    it("use the monotonic interval, not the wall clock", () => {
        const samples = series(1_000_000, [100, 100]);
        // A wall-clock step between the samples changes nothing.
        samples[2] = { ...samples[2], tsMs: samples[2].tsMs! + 5000 };
        expect(withIntervalRates(samples).map((sample) => sample.cpuPct)).toEqual([null, 100, 100]);
    });

    it("summarize the intervals inside the measured window: time-weighted mean, p95, max", () => {
        const t0 = 1_000_000;
        // 21 intervals: start-up at 50%, then 20 at 600–790%.
        const ratesPct = [50, ...Array.from({ length: 20 }, (_, i) => 600 + i * 10)];
        const samples = series(t0, ratesPct);
        // The window starts after the start-up interval: samples 1..21.
        const summary = summarizeServerCpu(samples, t0 + 1000, t0 + 21_000);
        expect(summary).not.toBeNull();
        expect(summary!.intervals).toBe(20);
        expect(summary!.meanPct).toBeCloseTo(695, 6);
        expect(summary!.p95Pct).toBeCloseTo(780, 6);
        expect(summary!.maxPct).toBeCloseTo(790, 6);
        expect(summary!.coveredStartAt).toBe(t0 + 1000);
        expect(summary!.coveredEndAt).toBe(t0 + 21_000);
    });

    it("weight the mean by interval length", () => {
        const samples = series(0, [100, 100]);
        // The second interval is 3 s long at 300%: (1 + 9) CPU-s over 4 s = 250%, not (100 + 300) / 2.
        samples[2] = { ...samples[2], monoMs: 4000, tsMs: 4000, cpuSec: (samples[1].cpuSec ?? 0) + 9 };
        expect(summarizeServerCpu(samples, 0, 10_000)!.meanPct).toBeCloseTo(250, 6);
    });

    it("give null for a window with fewer than two samples, per phase", () => {
        const samples = series(0, [100, 100, 100]);
        const phases = serverCpuByPhase({ system: samples }, [
            { phase: "steady", startAt: 0, endAt: 3000 },
            { phase: "post", startAt: 2500, endAt: 3200 }
        ]);
        expect(phases![0].summary!.meanPct).toBeCloseTo(100, 6);
        expect(phases![1].summary).toBeNull();
    });
});
