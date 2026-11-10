import { describe, it, expect } from "vitest";
import { eluAt, measureClientElu, processElu, startEluSampler, type EluSample } from "../src/client-elu";

describe("client ELU", () => {
    // Half busy throughout: active and idle grow alike.
    const half: EluSample[] = [
        [1_000, 0, 0],
        [2_000, 500, 500],
        [3_000, 1_000, 1_000]
    ];
    // Busy throughout.
    const busy: EluSample[] = [
        [1_000, 0, 0],
        [3_000, 2_000, 0]
    ];

    it("interpolates active and idle time between samples and refuses times outside them", () => {
        expect(eluAt(half, 1_500)).toEqual([250, 250]);
        expect(eluAt(half, 2_000)).toEqual([500, 500]);
        expect(eluAt(half, 999)).toBeUndefined();
        expect(eluAt(half, 3_001)).toBeUndefined();
        expect(eluAt([], 1_000)).toBeUndefined();
    });

    it("gives each worker's ELU in the window", () => {
        expect(measureClientElu([half, busy], 1_500, 2_500)).toEqual({ workers: 2, perWorker: { min: 0.5, mean: 0.75, max: 1 } });
    });

    it("reads the window only: a worker busy before it and idle in it is 0", () => {
        const busyThenIdle: EluSample[] = [
            [0, 0, 0],
            [1_000, 1_000, 0],
            [3_000, 1_000, 2_000]
        ];
        expect(measureClientElu([busyThenIdle], 1_000, 3_000).perWorker.max).toBe(0);
    });

    it("leaves out a worker whose samples don't cover the window, or show no loop time", () => {
        const late: EluSample[] = [
            [2_000, 0, 0],
            [3_000, 100, 900]
        ];
        const stalled: EluSample[] = [
            [1_000, 5, 5],
            [3_000, 5, 5]
        ];
        const elu = measureClientElu([half, late, stalled], 1_500, 2_500);
        expect(elu.workers).toBe(1);
        expect(elu.perWorker).toEqual({ min: 0.5, mean: 0.5, max: 0.5 });
        expect(measureClientElu([half], 2_000, 2_000)).toEqual({ workers: 0, perWorker: { min: 0, mean: 0, max: 0 } });
    });

    it("samples from start to stop", async () => {
        let t = 0;
        let active = 0;
        const stop = startEluSampler(5, () => (t += 10), () => ({ active: (active += 3), idle: active }));
        await new Promise((resolve) => setTimeout(resolve, 30));
        const samples = stop();
        expect(samples.length).toBeGreaterThanOrEqual(3);
        for (let i = 1; i < samples.length; i += 1) {
            expect(samples[i][0]).toBeGreaterThan(samples[i - 1][0]);
            expect(samples[i][1]).toBeGreaterThan(samples[i - 1][1]);
        }
    });

    it("reads this process's event loop", () => {
        const { active, idle } = processElu();
        expect(active).toBeGreaterThanOrEqual(0);
        expect(idle).toBeGreaterThanOrEqual(0);
    });
});
