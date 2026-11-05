import { describe, it, expect } from "vitest";
import { connectDelaysMs, connectingWorkers, DEFAULT_CONNECT_RATE, rampDurationMs } from "../src/connect-schedule";
import { planPhaseConnections } from "../src/layout";
import { newConnectionsPerWorker } from "../src/run";

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

describe("rampDurationMs", () => {
    it("is the busiest worker's share at the per-worker rate", () => {
        // 1000/s over 4 active workers is 250/s each; 500 new connections take 2 s.
        expect(rampDurationMs([500, 400, 300, 0, 200], "ramp", 1000)).toBe(2000);
        expect(rampDurationMs([500, 400], "burst", 1000)).toBe(0);
        expect(rampDurationMs([0, 0], "ramp", 1000)).toBe(0);
    });
});

describe("ramp when a phase adds connections on only some workers", () => {
    it("20 → 21 rooms on 3 workers: the one connecting worker gets the whole rate", () => {
        const plans = [
            planPhaseConnections("preflight", { rooms: 20, playersPerRoom: 5 }, 3, "rooms", "r1"),
            planPhaseConnections("steady", { rooms: 21, playersPerRoom: 5 }, 3, "rooms", "r1")
        ];
        const newPerWorker = newConnectionsPerWorker(plans)[1];
        // Room 20 goes to worker 20 % 3 = 2; its 5 players are the only new connections.
        expect(newPerWorker).toEqual([0, 0, 5]);
        expect(connectingWorkers(newPerWorker)).toBe(1);

        const rate = 10;
        const rampMs = rampDurationMs(newPerWorker, "ramp", rate);
        expect(rampMs).toBe(500);
        const keys = plans[1][2].filter((spec) => !plans[0][2].some((old) => old.key === spec.key)).map((spec) => spec.key);
        const delays = connectDelaysMs(keys, "ramp", rate, connectingWorkers(newPerWorker));
        // The schedule matches the check: 5 connections in 500 ms is the full 10/s.
        expect(Math.max(...delays)).toBeLessThan(rampMs);
        expect(Math.max(...delays)).toBeGreaterThanOrEqual(400);
        const achievedPerSecond = keys.length / (rampMs / 1000);
        expect(achievedPerSecond).toBe(rate);
    });
});

