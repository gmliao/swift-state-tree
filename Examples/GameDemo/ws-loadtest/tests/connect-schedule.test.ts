import { describe, it, expect } from "vitest";
import { connectDelaysMs, DEFAULT_CONNECT_RATE } from "../src/connect-schedule";

describe("connectDelaysMs", () => {
    const keys = Array.from({ length: 100 }, (_, i) => `room-p5-${i}-s0`);

    it("opens everything at once in burst mode", () => {
        expect(connectDelaysMs(keys, "burst", 1000, 4).every((d) => d === 0)).toBe(true);
    });

    it("spreads a worker's share of the rate with jitter inside each slot", () => {
        // 1000/s over 4 workers: 250/s per worker, a 4 ms slot.
        const delays = connectDelaysMs(keys, "ramp", 1000, 4);
        delays.forEach((d, i) => {
            expect(d).toBeGreaterThanOrEqual(i * 4);
            expect(d).toBeLessThan((i + 1) * 4);
        });
        for (let i = 1; i < delays.length; i += 1) expect(delays[i]).toBeGreaterThan(delays[i - 1]);
        expect(new Set(delays.map((d) => (d % 4).toFixed(3))).size).toBeGreaterThan(50);
        // Reproducible.
        expect(connectDelaysMs(keys, "ramp", 1000, 4)).toEqual(delays);
    });

    it("never puts more than rate connections in a second over all workers", () => {
        const workers = 5;
        const perWorker = Array.from({ length: workers }, (_, w) =>
            connectDelaysMs(Array.from({ length: 600 }, (_, i) => `w${w}-${i}`), "ramp", DEFAULT_CONNECT_RATE, workers)
        );
        const all = perWorker.flat();
        const perSecond = new Map<number, number>();
        for (const d of all) perSecond.set(Math.floor(d / 1000), (perSecond.get(Math.floor(d / 1000)) ?? 0) + 1);
        expect(Math.max(...perSecond.values())).toBeLessThanOrEqual(DEFAULT_CONNECT_RATE);
        expect(Math.max(...all)).toBeLessThan(3000);
    });
});
