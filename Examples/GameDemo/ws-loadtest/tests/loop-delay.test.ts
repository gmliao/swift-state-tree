import { afterEach, describe, it, expect, vi } from "vitest";
import { loopDelayFromHistogram, startLoopDelayMonitor, summarizeLoopDelay } from "../src/loop-delay";

describe("event-loop delay", () => {
    it("reports the delay beyond the sampling interval, in ms", () => {
        // A 1 ms monitor: 1.2 ms between samples is 0.2 ms of delay; a value under the
        // interval is 0.
        const histogram = {
            count: 100,
            max: 26_000_000,
            percentile: (p: number) => (p === 50 ? 1_200_000 : p === 99 ? 3_500_000 : 0),
            min: 900_000
        };
        expect(loopDelayFromHistogram(histogram, 1)).toEqual({ p50Ms: 0.2, p99Ms: 2.5, maxMs: 25, samples: 100 });
        expect(loopDelayFromHistogram({ ...histogram, percentile: () => 500_000 }, 1)?.p50Ms).toBe(0);
    });

    it("has no delay without samples", () => {
        expect(loopDelayFromHistogram({ count: 0, max: 0, min: 0, percentile: () => 0 }, 1)).toBeNull();
    });

    it("summarizes the workers: mean and worst p50 and p99, worst max", () => {
        const summary = summarizeLoopDelay([
            { p50Ms: 0.2, p99Ms: 2, maxMs: 10, samples: 900 },
            null,
            { p50Ms: 0.6, p99Ms: 8, maxMs: 40, samples: 800 },
            undefined
        ]);
        expect(summary).toEqual({ workers: 2, p50Ms: { mean: 0.4, max: 0.6 }, p99Ms: { mean: 5, max: 8 }, maxMs: 40 });
        expect(summarizeLoopDelay([null]).workers).toBe(0);
    });

    afterEach(() => {
        vi.useRealTimers();
    });

    /** A histogram that logs when sampling turns on and off, at the (fake) wall clock. */
    function fakeHistogram() {
        const calls: string[] = [];
        const histogram = {
            count: 0,
            max: 4_000_000,
            min: 1_000_000,
            percentile: () => 2_000_000,
            enable: () => calls.push(`enable@${Date.now()}`),
            disable: () => calls.push(`disable@${Date.now()}`)
        };
        return { histogram, calls };
    }

    it("samples only from the window start to stop", () => {
        // Fake timers and a fake histogram: the test checks the window, not a real loop's delay,
        // so a loaded machine can't fail it (#258).
        vi.useFakeTimers({ now: 1_000_000 });
        const { histogram, calls } = fakeHistogram();
        const stop = startLoopDelayMonitor(1_000_060, 1, () => histogram);
        vi.advanceTimersByTime(59);
        expect(calls).toEqual([]);
        vi.advanceTimersByTime(1);
        expect(calls).toEqual(["enable@1000060"]);
        histogram.count = 150;
        vi.advanceTimersByTime(150);
        expect(stop()).toEqual({ p50Ms: 1, p99Ms: 1, maxMs: 3, samples: 150 });
        expect(calls).toEqual(["enable@1000060", "disable@1000210"]);
        vi.advanceTimersByTime(10_000);
        expect(calls).toHaveLength(2);
    });

    it("has no delay when stopped before the window start, and never starts sampling", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const { histogram, calls } = fakeHistogram();
        const stop = startLoopDelayMonitor(1_010_000, 1, () => histogram);
        vi.advanceTimersByTime(5_000);
        expect(stop()).toBeNull();
        vi.advanceTimersByTime(10_000);
        expect(calls).toEqual([]);
    });
});
