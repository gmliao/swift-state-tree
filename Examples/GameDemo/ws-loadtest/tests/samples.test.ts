import { describe, it, expect } from "vitest";
import { selectByTime, windowSamples } from "../src/samples";
import { measurePhase } from "../src/run";
import type { WorkerPhaseReport } from "../src/worker-runner";

function report(partial: Partial<WorkerPhaseReport>): WorkerPhaseReport {
    return {
        rttMs: [], rttAt: [], stateUpdateIntervalsMs: [], updateAt: [], sendLagMs: [], sentAt: [],
        errorCount: 0, disconnectCount: 0, actionsSent: 0, closes: [],
        connectionsOpened: 0, connectionsStarted: 0, joinedAtEnd: 0, connectionsReused: 0, connectionsClosed: 0, connectRampMs: 0,
        ...partial
    };
}

describe("samples", () => {
    it("selects by completion time", () => {
        expect(selectByTime([1, 2, 3], [100, 200, 300], 150, 300)).toEqual([2]);
    });

    it("buckets into windows and flags the warm-up", () => {
        const windows = windowSamples(
            { rttMs: [10, 20, 30], rttAt: [1100, 1900, 2500], stateUpdateIntervalsMs: [100], updateAt: [2100], sentAt: [1050, 1200, 2050] },
            1000, 2000, 1000, 1000
        );
        expect(windows.map((w) => [w.startMs, w.warmup, w.rtt.count, w.update.count, w.sent])).toEqual([
            [0, true, 2, 0, 2],
            [1000, false, 1, 1, 1]
        ]);
        expect(windows[0].rtt.max).toBe(20);
    });
});

describe("measurePhase", () => {
    it("excludes the warm-up, reports the send rate against the target and late sends", () => {
        // Origin 0, 4 s phase, 1 s warm-up, 2 clients at 1/s.
        const r = report({
            rttMs: [500, 10, 12, 400],
            rttAt: [300, 1500, 2500, 3500],
            sentAt: [100, 1100, 2100, 3600],
            sendLagMs: [0, 0, 0, 1500],
            joinedAtEnd: 2
        });
        const m = measurePhase([r], 0, 4000, 1000, 1000, 1);
        expect(m.excludedSamples).toEqual({ rtt: 1, update: 0 });
        expect(m.measuredMs).toBe(3000);
        expect(m.sendRate.targetPerSecond).toBe(2);
        expect(m.sendRate.sentInWindow).toBe(3);
        expect(m.sendRate.achievedPerSecond).toBeCloseTo(1, 5);
        expect(m.sendRate.lateSends).toBe(1);
        expect(m.windows).toHaveLength(4);
        expect(m.windows[0].warmup).toBe(true);
    });
});
