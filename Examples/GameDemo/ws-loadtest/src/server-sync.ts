import fs from "node:fs";

/**
 * Server-side sync counters from the transport profiler's JSONL (`TRANSPORT_PROFILE_JSONL_PATH`,
 * written by `run-ws-loadtest.sh --profile`). Each line is one window of server-wide deltas
 * summed over every land; its `ts` (ms since epoch) is when the window was taken, so a window
 * covers the time from the previous line's `ts` to its own.
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

/** How each counter reads in the report: the subsets say what they are a subset of. */
export const SERVER_SYNC_LABELS: Record<ServerSyncField, string> = {
    syncCycles: "sync cycles committed",
    syncSkipsBacklog: "skipped: writer backlog",
    syncSkipsBusy: "skipped: cycle in flight",
    syncDeferredTurns: "of backlog skips: in-turn deferrals",
    syncFolds: "folded into a tick turn",
    syncOverdueFolds: "of folds: into an overdue tick"
};

export interface ServerSyncSpan {
    /** The span asked for (the phase's measured window), ms since epoch. */
    requestedStartAt: number;
    requestedEndAt: number;
    /** The span the counted windows cover: the first counted window's start to the last's end. */
    coveredStartAt: number;
    coveredEndAt: number;
}

export interface ServerSyncSummary {
    /** Profile windows counted: those that lie wholly inside the span. */
    windows: number;
    span: ServerSyncSpan;
    /** Sums over those windows. */
    totals: ServerSyncCounts;
    /** The largest value of each counter in one window. */
    maxWindow: ServerSyncCounts;
    /** Windows with at least one fold into an overdue tick. */
    windowsWithOverdueFold: number;
    /** Overdue folds per 1000 committed sync cycles; null when no cycle committed. */
    overdueFoldsPer1000Syncs: number | null;
}

export interface ServerSyncPhase {
    phase: string;
    /** Null: no window with the sync counters lies wholly inside this phase's measured window. */
    summary: ServerSyncSummary | null;
}

interface ProfileWindow {
    startAt: number;
    endAt: number;
    counters: ServerSyncCounts;
}

function zeroCounts(): ServerSyncCounts {
    return Object.fromEntries(SERVER_SYNC_FIELDS.map((field) => [field, 0])) as ServerSyncCounts;
}

/**
 * The profile's windows, each from the previous line's `ts` to its own. The first line has no
 * known start and is skipped. Lines without the sync counters (an older server) give no window.
 */
export function parseProfileWindows(raw: string): ProfileWindow[] {
    const windows: ProfileWindow[] = [];
    let previousTs: number | undefined;
    for (const line of raw.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("{")) {
            continue;
        }
        let parsed: { ts?: unknown; counters?: Record<string, unknown> };
        try {
            parsed = JSON.parse(trimmed);
        } catch {
            continue;
        }
        if (typeof parsed.ts !== "number") {
            continue;
        }
        const startAt = previousTs;
        previousTs = parsed.ts;
        const counters = parsed.counters;
        if (startAt === undefined || !counters || !SERVER_SYNC_FIELDS.every((field) => typeof counters[field] === "number")) {
            continue;
        }
        windows.push({ startAt, endAt: parsed.ts, counters: counters as unknown as ServerSyncCounts });
    }
    return windows;
}

/** The last `ts` in a profile, or undefined. */
export function lastProfileTs(raw: string): number | undefined {
    let last: number | undefined;
    for (const line of raw.split(/\r?\n/)) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("{")) {
            continue;
        }
        try {
            const ts = (JSON.parse(trimmed) as { ts?: unknown }).ts;
            if (typeof ts === "number") {
                last = ts;
            }
        } catch {
            continue;
        }
    }
    return last;
}

/**
 * Summarizes the windows that lie wholly inside [startAt, endAt]. Partial windows at the edges
 * are left out, so the covered span can be up to one window shorter at each end; the summary
 * states it. Returns null when no such window carries the sync counters, so the report shows
 * "n/a", never 0.
 */
export function summarizeServerSync(windows: ProfileWindow[], startAt: number, endAt: number): ServerSyncSummary | null {
    const inside = windows.filter((w) => w.startAt >= startAt && w.endAt <= endAt);
    if (inside.length === 0) {
        return null;
    }
    const totals = zeroCounts();
    const maxWindow = zeroCounts();
    let windowsWithOverdueFold = 0;
    for (const window of inside) {
        for (const field of SERVER_SYNC_FIELDS) {
            totals[field] += window.counters[field];
            maxWindow[field] = Math.max(maxWindow[field], window.counters[field]);
        }
        if (window.counters.syncOverdueFolds > 0) {
            windowsWithOverdueFold += 1;
        }
    }
    const overdueFoldsPer1000Syncs =
        totals.syncCycles > 0 ? (totals.syncOverdueFolds * 1000) / totals.syncCycles : null;
    return {
        windows: inside.length,
        span: {
            requestedStartAt: startAt,
            requestedEndAt: endAt,
            coveredStartAt: inside[0].startAt,
            coveredEndAt: inside[inside.length - 1].endAt
        },
        totals,
        maxWindow,
        windowsWithOverdueFold,
        overdueFoldsPer1000Syncs
    };
}

/** A phase's measured window, ms since epoch (the span the client metrics use). */
export interface MeasuredSpan {
    phase: string;
    startAt: number;
    endAt: number;
}

/** The measured windows of a run's phases: origin + warm-up for the measured length. */
export function measuredSpans(
    phases: Array<{ name: string; measurement: { originAt: number; warmupMs: number; measuredMs: number } }>
): MeasuredSpan[] {
    return phases
        .filter((phase) => phase.measurement.measuredMs > 0)
        .map((phase) => {
            const startAt = phase.measurement.originAt + phase.measurement.warmupMs;
            return { phase: phase.name, startAt, endAt: startAt + phase.measurement.measuredMs };
        });
}

/**
 * Per phase, the sync counters over its measured window. Null when there is no profile file
 * or no window in it carries the sync counters (an older server).
 */
export function serverSyncByPhase(raw: string | undefined, spans: MeasuredSpan[]): ServerSyncPhase[] | null {
    if (raw === undefined) {
        return null;
    }
    const windows = parseProfileWindows(raw);
    if (windows.length === 0) {
        return null;
    }
    return spans.map((span) => ({ phase: span.phase, summary: summarizeServerSync(windows, span.startAt, span.endAt) }));
}

/**
 * Reads the profile once it holds a window taken at or after `untilAt` (the last measured
 * window's end), so that window's last profile window is flushed; gives up after `timeoutMs`
 * and reads what is there. Undefined when the file is missing.
 */
export async function readProfileAfter(filePath: string | undefined, untilAt: number, timeoutMs = 3000): Promise<string | undefined> {
    if (!filePath) {
        return undefined;
    }
    const deadline = Date.now() + timeoutMs;
    for (;;) {
        const raw = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf-8") : undefined;
        const last = raw === undefined ? undefined : lastProfileTs(raw);
        if ((last !== undefined && last >= untilAt) || Date.now() >= deadline) {
            return raw;
        }
        await new Promise((resolve) => setTimeout(resolve, 200));
    }
}
