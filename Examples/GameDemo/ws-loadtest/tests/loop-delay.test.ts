import { describe, it, expect } from "vitest";
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

    it("measures only from the window start to stop", async () => {
        // A loop blocked before the window start is not counted.
        const from = Date.now() + 60;
        const stop = startLoopDelayMonitor(from);
        const blockUntil = Date.now() + 40;
        while (Date.now() < blockUntil) {
            // busy
        }
        await new Promise((resolve) => setTimeout(resolve, 150));
        const delay = stop();
        expect(delay).not.toBeNull();
        expect(delay!.samples).toBeGreaterThan(10);
        expect(delay!.maxMs).toBeLessThan(30);
    });

    it("has no delay when stopped before the window start", () => {
        const stop = startLoopDelayMonitor(Date.now() + 10_000);
        expect(stop()).toBeNull();
    });
});
