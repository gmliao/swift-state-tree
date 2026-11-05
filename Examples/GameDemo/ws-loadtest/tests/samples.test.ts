import { describe, it, expect } from "vitest";
import { coveredMs, selectByTime, windowEdges, windowSamples } from "../src/samples";
import { aggregateReports, measurePhase } from "../src/run";
import type { WorkerPhaseReport } from "../src/worker-runner";

function report(partial: Partial<WorkerPhaseReport>): WorkerPhaseReport {
    return {
        rttMs: [], rttAt: [], stateUpdateIntervalsMs: [], updateAt: [], sendLagMs: [], sentAt: [],
        errorCount: 0, disconnectCount: 0, actionsSent: 0, closes: [],
        errorAt: [], pendingAtEnd: [], lateResponseOrigins: [], activeIntervals: [],
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

    it("splits windows at the warm-up boundary instead of flagging a straddling window", () => {
        expect(windowEdges(4000, 1000, 1500)).toEqual([0, 1000, 1500, 2500, 3500, 4000]);
        expect(windowEdges(3000, 1000, 0)).toEqual([0, 1000, 2000, 3000]);
        expect(windowEdges(2000, 1000, 2000)).toEqual([0, 1000, 2000]);
        const windows = windowSamples(
            { rttMs: [1, 2, 3], rttAt: [1400, 1600, 3900], stateUpdateIntervalsMs: [], updateAt: [], sentAt: [] },
            0, 4000, 1000, 1500
        );
        expect(windows.map((w) => [w.startMs, w.endMs, w.warmup, w.rtt.count])).toEqual([
            [0, 1000, true, 0],
            [1000, 1500, true, 1],
            [1500, 2500, false, 1],
            [2500, 3500, false, 0],
            [3500, 4000, false, 1]
        ]);
    });

    it("sums interval coverage inside a range", () => {
        expect(coveredMs([[0, 4000], [2500, 4000], [5000, 6000]], 1000, 4000)).toBe(4500);
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
            joinedAtEnd: 2,
            // One client the whole phase, one joined at 2.5 s: 1.5 clients on average over [1, 4) s.
            activeIntervals: [[0, 4000], [2500, 4000]]
        });
        const m = measurePhase([r], 0, 4000, 1000, 1000, 1);
        expect(m.excludedSamples).toEqual({ rtt: 1, update: 0 });
        expect(m.measuredMs).toBe(3000);
        expect(m.sendRate.targetPerSecond).toBe(1.5);
        expect(m.sendRate.sentInWindow).toBe(3);
        expect(m.sendRate.achievedPerSecond).toBeCloseTo(1, 5);
        expect(m.sendRate.lateSends).toBe(1);
        expect(m.windows).toHaveLength(4);
        expect(m.windows[0].warmup).toBe(true);
    });

    it("reports unanswered requests over the phase and for the measured window", () => {
        // Phase end 10 s, warm-up 2 s, timeout 5 s.
        const r = report({
            pendingAtEnd: [500, 3000, 9900],
            lateResponseOrigins: [1000, 4000]
        });
        const m = measurePhase([r], 0, 10_000, 2000, 1000, 1);
        expect(m.unanswered.timeoutMs).toBe(5000);
        expect(m.unanswered.phase).toEqual({ pendingAtEnd: 3, timedOutAtEnd: 2, lateResponses: 2 });
        expect(m.unanswered.measured).toEqual({ pendingAtEnd: 2, timedOutAtEnd: 1, lateResponses: 1 });
    });
});

describe("aggregateReports", () => {
    it("counts errors, server closes and sends in the measured window only", () => {
        const r = report({
            errorAt: [500, 1500, 3999, 4000],
            errorCount: 4,
            sentAt: [100, 1000, 2000],
            actionsSent: 3,
            closes: [
                { t: 900, key: "a", landInstanceId: "l", initiator: "server", code: 1001, reason: "", joined: true },
                { t: 1200, key: "b", landInstanceId: "l", initiator: "server", code: 1001, reason: "", joined: true },
                { t: 1300, key: "c", landInstanceId: "l", initiator: "client", code: 1000, reason: "", joined: true }
            ],
            disconnectCount: 2
        });
        const measured = aggregateReports([r], 1000, 4000);
        expect(measured).toMatchObject({ errorCount: 2, disconnectCount: 1, actionsSent: 2 });
    });
});
