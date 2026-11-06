import type { MeasuredSpan } from "./server-sync";

/**
 * Server-side send backlog (#61) from the transport profiler's JSONL, per phase over its
 * measured window. Each profile line is one window, server-wide:
 * - `sendBufferedBytesMax`: the largest outbound-buffer sample of any session after a write
 *   (bytes NIO still held, not yet accepted by the socket);
 * - `sendUnwritableEpisodes`: sessions that became unwritable in the window;
 * - `sendUnwritableLongestMs`: the longest unwritable episode that ended in the window;
 * - `sendUnwritableSessions`: a gauge, sessions unwritable when the window was taken.
 * Lines without these fields (an older server) give no window, so the report says "n/a".
 * `sendBacklogCloses` (sessions closed by the send backlog bound, 4008) is optional: a server
 * before the bound has the four fields above but not this one.
 */
export const SERVER_SEND_FIELDS = [
    "sendBufferedBytesMax",
    "sendUnwritableEpisodes",
    "sendUnwritableLongestMs",
    "sendUnwritableSessions"
] as const;

export type ServerSendField = (typeof SERVER_SEND_FIELDS)[number];
type ServerSendCounts = Record<ServerSendField, number> & { sendBacklogCloses?: number };

export interface ServerSendSummary {
    /** Profile windows counted: those that lie wholly inside the span. */
    windows: number;
    coveredStartAt: number;
    coveredEndAt: number;
    /** The largest outbound-buffer sample in any counted window, bytes. */
    bufferedBytesMax: number;
    /** Unwritable episodes started in the counted windows. */
    unwritableEpisodes: number;
    /** The longest unwritable episode that ended in a counted window, ms. */
    unwritableLongestMs: number;
    /**
     * The most sessions unwritable at a window's end: a sample per window, not the peak
     * concurrency (sessions that go unwritable and recover within a window are not in it; they
     * are in `unwritableEpisodes`).
     */
    unwritableSessionsMax: number;
    /**
     * Sessions closed by the send backlog bound in the counted windows. Null unless every
     * counted window has the counter: a partial sum would read as fewer closes than happened.
     */
    backlogCloses: number | null;
}

export interface ServerSendPhase {
    phase: string;
    /** Null: no window with the send counters lies wholly inside this phase's measured window. */
    summary: ServerSendSummary | null;
}

interface SendWindow {
    startAt: number;
    endAt: number;
    counters: ServerSendCounts;
}

/** The profile's windows that carry the send counters, each from the previous line's `ts`. */
export function parseSendWindows(raw: string): SendWindow[] {
    const windows: SendWindow[] = [];
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
        if (startAt === undefined || !counters || !SERVER_SEND_FIELDS.every((field) => typeof counters[field] === "number")) {
            continue;
        }
        windows.push({ startAt, endAt: parsed.ts, counters: counters as unknown as ServerSendCounts });
    }
    return windows;
}

/** Summarizes the windows wholly inside [startAt, endAt]; null when there are none. */
export function summarizeServerSend(windows: SendWindow[], startAt: number, endAt: number): ServerSendSummary | null {
    const inside = windows.filter((w) => w.startAt >= startAt && w.endAt <= endAt);
    if (inside.length === 0) {
        return null;
    }
    return {
        windows: inside.length,
        coveredStartAt: inside[0].startAt,
        coveredEndAt: inside[inside.length - 1].endAt,
        bufferedBytesMax: Math.max(...inside.map((w) => w.counters.sendBufferedBytesMax)),
        unwritableEpisodes: inside.reduce((sum, w) => sum + w.counters.sendUnwritableEpisodes, 0),
        unwritableLongestMs: Math.max(...inside.map((w) => w.counters.sendUnwritableLongestMs)),
        unwritableSessionsMax: Math.max(...inside.map((w) => w.counters.sendUnwritableSessions)),
        backlogCloses: inside.every((w) => typeof w.counters.sendBacklogCloses === "number")
            ? inside.reduce((sum, w) => sum + (w.counters.sendBacklogCloses as number), 0)
            : null
    };
}

/** Per phase, the send backlog over its measured window; null without a profile or the counters. */
export function serverSendByPhase(raw: string | undefined, spans: MeasuredSpan[]): ServerSendPhase[] | null {
    if (raw === undefined) {
        return null;
    }
    const windows = parseSendWindows(raw);
    if (windows.length === 0) {
        return null;
    }
    return spans.map((span) => ({ phase: span.phase, summary: summarizeServerSend(windows, span.startAt, span.endAt) }));
}
