import { describe, it, expect } from "vitest";
import { measuredSpans, parseProfileWindows, serverSyncByPhase, summarizeServerSync } from "../src/server-sync";
import { serverSyncSection } from "../src/report/render-html";

function line(ts: number, counters: Record<string, number>): string {
    return JSON.stringify({ ts, lag_ms: 0, counters: { actions: 0, ...counters } });
}

/** A window line taken at `ts` (seconds), with `cycles` sync cycles and `overdue` overdue folds. */
const at = (ts: number, cycles: number, overdue: number, extra: Partial<Record<string, number>> = {}) =>
    line(ts * 1000, {
        syncCycles: cycles,
        syncSkipsBacklog: 0,
        syncSkipsBusy: 0,
        syncDeferredTurns: 0,
        syncFolds: overdue,
        syncOverdueFolds: overdue,
        ...extra
    });

describe("parseProfileWindows: the final window", () => {
    it("leaves out a final line (#351), a short window written at shutdown, from counts and maxima", () => {
        const final = JSON.stringify({ ...JSON.parse(at(12.2, 5000, 5)), final: true, interval_ms: 200 });
        const raw = [at(10, 0, 0), at(11, 1000, 1), at(12, 1000, 1), final, at(13, 1000, 1)].join("\n");
        const windows = parseProfileWindows(raw);
        expect(windows.map((w) => [w.startAt, w.endAt])).toEqual([[10_000, 11_000], [11_000, 12_000], [12_200, 13_000]]);
        const summary = summarizeServerSync(windows, 10_000, 13_000);
        expect(summary?.windows).toBe(3);
        expect(summary?.maxWindow.syncCycles).toBe(1000);
    });
});

describe("summarizeServerSync", () => {
    it("counts only windows wholly inside the span and states the covered span", () => {
        // Windows: (10,11] (11,12] (12,13] (13,14]; the span [11, 13.5] holds (11,12] and (12,13].
        const raw = [
            at(10, 999, 9),
            at(11, 999, 9),
            at(12, 1000, 3, { syncSkipsBacklog: 2, syncDeferredTurns: 1, syncFolds: 10 }),
            "not json",
            at(13, 2000, 1),
            at(14, 999, 9)
        ].join("\n");
        const summary = summarizeServerSync(parseProfileWindows(raw), 11_000, 13_500);
        expect(summary?.windows).toBe(2);
        expect(summary?.span).toEqual({ requestedStartAt: 11_000, requestedEndAt: 13_500, coveredStartAt: 11_000, coveredEndAt: 13_000 });
        expect(summary?.totals.syncCycles).toBe(3000);
        expect(summary?.totals.syncOverdueFolds).toBe(4);
        expect(summary?.totals.syncFolds).toBe(11);
        expect(summary?.maxWindow.syncCycles).toBe(2000);
        expect(summary?.maxWindow.syncSkipsBacklog).toBe(2);
        expect(summary?.windowsWithOverdueFold).toBe(2);
        expect(summary?.overdueFoldsPer1000Syncs).toBeCloseTo(4 / 3);
    });

    it("is null when no window lies inside the span", () => {
        const windows = parseProfileWindows([at(10, 1, 0), at(11, 1, 0)].join("\n"));
        expect(summarizeServerSync(windows, 10_500, 11_500)).toBeNull();
    });

    it("gives no rate when no sync cycle committed", () => {
        const windows = parseProfileWindows([at(1, 0, 0), at(2, 0, 0)].join("\n"));
        expect(summarizeServerSync(windows, 0, 5000)?.overdueFoldsPer1000Syncs).toBeNull();
    });
});

describe("late folds (#232)", () => {
    const late = (ts: number, lateFolds: number, maxUs: number) =>
        at(ts, 1000, 0, { syncFolds: 300, syncLateFolds: lateFolds, syncFoldTickLatenessMaxUs: maxUs });

    it("sums the late folds and takes the largest lateness over the windows", () => {
        const raw = [late(0, 0, 0), late(1, 2, 6000), late(2, 1, 12_500), late(3, 0, 800)].join("\n");
        const summary = summarizeServerSync(parseProfileWindows(raw), 0, 3000);
        expect(summary?.lateFolds).toBe(3);
        expect(summary?.lateFoldsPer1000Syncs).toBeCloseTo(1);
        expect(summary?.foldTickLatenessMaxUs).toBe(12_500);
        expect(summary?.foldsPer1000Syncs).toBeCloseTo(300);
    });

    it("gives null, never 0, for a profile from a server without them", () => {
        const raw = [at(0, 1000, 5), at(1, 1000, 5), at(2, 1000, 5)].join("\n");
        const summary = summarizeServerSync(parseProfileWindows(raw), 0, 2000);
        expect(summary?.windows).toBe(2);
        expect(summary?.totals.syncOverdueFolds).toBe(10);
        expect(summary?.lateFolds).toBeNull();
        expect(summary?.lateFoldsPer1000Syncs).toBeNull();
        expect(summary?.foldTickLatenessMaxUs).toBeNull();
    });

    it("gives null when only some windows carry them", () => {
        const raw = [late(0, 0, 0), late(1, 4, 9000), at(2, 1000, 0)].join("\n");
        const summary = summarizeServerSync(parseProfileWindows(raw), 0, 2000);
        expect(summary?.windows).toBe(2);
        expect(summary?.lateFolds).toBeNull();
        expect(summary?.foldTickLatenessMaxUs).toBeNull();
    });
});

describe("serverSyncByPhase", () => {
    const phases = [
        { name: "preflight", measurement: { originAt: 0, warmupMs: 1000, measuredMs: 2000 } },
        { name: "steady", measurement: { originAt: 5000, warmupMs: 2000, measuredMs: 3000 } },
        { name: "empty", measurement: { originAt: 20_000, warmupMs: 5000, measuredMs: 0 } }
    ];

    it("takes each phase's measured window (origin + warm-up for the measured length)", () => {
        expect(measuredSpans(phases)).toEqual([
            { phase: "preflight", startAt: 1000, endAt: 3000 },
            { phase: "steady", startAt: 7000, endAt: 10_000 }
        ]);
    });

    it("leaves the warm-up out of the steady phase", () => {
        const raw = Array.from({ length: 11 }, (_, i) => at(i, 100, i === 6 ? 50 : 0)).join("\n");
        const result = serverSyncByPhase(raw, measuredSpans(phases));
        const steady = result?.find((p) => p.phase === "steady")?.summary;
        expect(steady?.windows).toBe(3);
        expect(steady?.totals.syncOverdueFolds).toBe(0); // the warm-up window (5,6] is out
    });

    it("is null without a profile, or for one from a server without the counters", () => {
        expect(serverSyncByPhase(undefined, measuredSpans(phases))).toBeNull();
        const old = [line(1000, { stateUpdates: 5 }), line(2000, { stateUpdates: 5 })].join("\n");
        expect(serverSyncByPhase(old, measuredSpans(phases))).toBeNull();
    });
});

describe("serverSyncSection", () => {
    it("says n/a without counters, never 0", () => {
        const html = serverSyncSection(null);
        expect(html).toContain("n/a");
        expect(html).not.toContain("per 1000 syncs: 0");
    });

    it("shows the covered span, the rate and the 'of which' labels", () => {
        const raw = [at(0, 0, 0), at(1, 2000, 1), at(2, 2000, 0)].join("\n");
        const html = serverSyncSection(serverSyncByPhase(raw, [{ phase: "steady", startAt: 0, endAt: 2000 }]));
        expect(html).toContain("covers 2.0 s of the measured window");
        expect(html).toContain("past-deadline (loop race) folds per 1000 syncs: 0.25");
        expect(html).toContain("windows with an overdue fold: 1 of 2");
        expect(html).toContain("of backlog skips: in-turn deferrals");
        expect(html).toContain("of folds: past deadline (loop race)");
        expect(html).toContain("late folds per 1000 syncs: n/a");
    });

    it("leads with folds and late folds per 1000 syncs, and the max lateness with its threshold", () => {
        const late = { syncFolds: 600, syncLateFolds: 3, syncFoldTickLatenessMaxUs: 7250 };
        const raw = [at(0, 0, 0, late), at(1, 2000, 1, late), at(2, 2000, 0, { ...late, syncFoldTickLatenessMaxUs: 900 })].join("\n");
        const html = serverSyncSection(serverSyncByPhase(raw, [{ phase: "steady", startAt: 0, endAt: 2000 }]));
        expect(html).toContain("folds per 1000 syncs: 300.00");
        expect(html).toContain("late folds per 1000 syncs: 1.50");
        expect(html).toContain("largest fold lateness: 7.25 ms (late above min(5 ms, tick / 4, sync / 4))");
        expect(html).toContain("Server-wide");
    });

    it("says n/a for a phase with no window inside its measured window", () => {
        const html = serverSyncSection([{ phase: "steady", summary: null }]);
        expect(html).toContain("n/a (no profile window inside the measured window)");
    });
});
