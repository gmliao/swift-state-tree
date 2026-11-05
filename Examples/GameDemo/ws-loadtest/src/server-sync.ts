import fs from "node:fs";

/**
 * Server-side sync counters from the transport profiler's JSONL (`TRANSPORT_PROFILE_JSONL_PATH`,
 * written by `run-ws-loadtest.sh --profile`). Each line is one window (1 s by default) of
 * server-wide deltas summed over every land.
 */
export const SERVER_SYNC_FIELDS = [
    "syncCycles",
    "syncSkipsBacklog",
    "syncSkipsBusy",
    "syncDeferredTurns",
    "syncFolds",
    "syncOverdueFolds"
] as const;

export type ServerSyncField = (typeof SERVER_SYNC_FIELDS)[number];
export type ServerSyncCounts = Record<ServerSyncField, number>;

export interface ServerSyncSummary {
    /** Profile windows that carry the sync counters. */
    windows: number;
    /** Sums over those windows. */
    totals: ServerSyncCounts;
    /** The largest value of each counter in one window. */
    maxWindow: ServerSyncCounts;
    /** Windows with at least one fold into an overdue tick. */
    windowsWithOverdueFold: number;
    /** Overdue folds per 1000 committed sync cycles; null when no cycle committed. */
    overdueFoldsPer1000Syncs: number | null;
}

function zeroCounts(): ServerSyncCounts {
    return Object.fromEntries(SERVER_SYNC_FIELDS.map((field) => [field, 0])) as ServerSyncCounts;
}

/**
 * Summarizes a profile. Returns null when no window carries the sync counters (a profile from a
 * server older than these counters, or an empty one), so the report shows "n/a", never 0.
 */
export function summarizeServerSync(raw: string): ServerSyncSummary | null {
    const totals = zeroCounts();
    const maxWindow = zeroCounts();
    let windows = 0;
    let windowsWithOverdueFold = 0;
    for (const line of raw.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("{")) {
            continue;
        }
        let counters: Record<string, unknown> | undefined;
        try {
            counters = (JSON.parse(trimmed) as { counters?: Record<string, unknown> }).counters;
        } catch {
            continue;
        }
        if (!counters || !SERVER_SYNC_FIELDS.every((field) => typeof counters?.[field] === "number")) {
            continue;
        }
        windows += 1;
        for (const field of SERVER_SYNC_FIELDS) {
            const value = counters[field] as number;
            totals[field] += value;
            maxWindow[field] = Math.max(maxWindow[field], value);
        }
        if ((counters.syncOverdueFolds as number) > 0) {
            windowsWithOverdueFold += 1;
        }
    }
    if (windows === 0) {
        return null;
    }
    const overdueFoldsPer1000Syncs =
        totals.syncCycles > 0 ? (totals.syncOverdueFolds * 1000) / totals.syncCycles : null;
    return { windows, totals, maxWindow, windowsWithOverdueFold, overdueFoldsPer1000Syncs };
}

/** Reads and summarizes a profile file; null when it is missing or has no sync counters. */
export function readServerSync(filePath: string | undefined): ServerSyncSummary | null {
    if (!filePath || !fs.existsSync(filePath)) {
        return null;
    }
    return summarizeServerSync(fs.readFileSync(filePath, "utf-8"));
}
