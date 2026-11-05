import { describe, it, expect } from "vitest";
import { summarizeServerSync } from "../src/server-sync";
import { serverSyncSection } from "../src/report/render-html";

function line(counters: Record<string, number>): string {
    return JSON.stringify({ ts: 1, lag_ms: 0, counters: { actions: 0, ...counters } });
}

const window = (cycles: number, overdue: number, extra: Partial<Record<string, number>> = {}) =>
    line({
        syncCycles: cycles,
        syncSkipsBacklog: 0,
        syncSkipsBusy: 0,
        syncDeferredTurns: 0,
        syncFolds: overdue,
        syncOverdueFolds: overdue,
        ...extra
    });

describe("summarizeServerSync", () => {
    it("sums the windows, takes the max window and the overdue-fold rate per 1000 syncs", () => {
        const raw = [
            window(1000, 0),
            window(1000, 3, { syncSkipsBacklog: 2, syncFolds: 10 }),
            "not json",
            window(2000, 1, { syncDeferredTurns: 4 })
        ].join("\n");
        const summary = summarizeServerSync(raw);
        expect(summary).not.toBeNull();
        expect(summary?.windows).toBe(3);
        expect(summary?.totals.syncCycles).toBe(4000);
        expect(summary?.totals.syncOverdueFolds).toBe(4);
        expect(summary?.totals.syncFolds).toBe(11);
        expect(summary?.maxWindow.syncCycles).toBe(2000);
        expect(summary?.maxWindow.syncSkipsBacklog).toBe(2);
        expect(summary?.maxWindow.syncDeferredTurns).toBe(4);
        expect(summary?.windowsWithOverdueFold).toBe(2);
        expect(summary?.overdueFoldsPer1000Syncs).toBe(1);
    });

    it("is null for a profile from a server without the counters, or an empty one", () => {
        expect(summarizeServerSync(line({ stateUpdates: 5 }))).toBeNull();
        expect(summarizeServerSync("")).toBeNull();
    });

    it("gives no rate when no sync cycle committed", () => {
        expect(summarizeServerSync(window(0, 0))?.overdueFoldsPer1000Syncs).toBeNull();
    });
});

describe("serverSyncSection", () => {
    it("says n/a without counters, never 0", () => {
        const html = serverSyncSection(null);
        expect(html).toContain("n/a");
        expect(html).not.toContain("per 1000 syncs: 0");
    });

    it("shows the rate and the windows with an overdue fold", () => {
        const html = serverSyncSection(summarizeServerSync(window(2000, 1)));
        expect(html).toContain("overdue folds per 1000 syncs: 0.50");
        expect(html).toContain("windows with an overdue fold: 1 of 1");
    });
});
