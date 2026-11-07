import { distribution, type Distribution } from "./samples";

/**
 * Input-to-visible latency (#64): from sending a move event until a state frame first shows its
 * point. Both lands echo the event's point into synced state as it was sent:
 * - hero-defense `MoveTo { target }` sets `players[id].targetPosition`, clamped to the world,
 *   which the `moveTo` generator's targets are already inside;
 * - visibility-test `MoveViewer { position }` sets `viewers[id].position`.
 *
 * The server diffs a `Position2` as one value (`SyncEngine.isAtomicType`), so the point arrives
 * as a whole `{ v: { x, y } }` object in every encoding; paths may be hashed and keys
 * compressed, but values are not. The tracker scans each state frame's values for a pending
 * point; it needs neither the schema nor the client's state. A false match needs another object
 * with exactly the same fixed-point x and y in the same frame.
 */

/** An input not seen within this many ms is counted as timed out, not timed. */
export const INPUT_LATENCY_TIMEOUT_MS = 5_000;
/** Pending inputs per connection; past this the oldest is counted as superseded. */
export const INPUT_LATENCY_MAX_PENDING = 8;

export interface EchoPoint {
    x: number;
    y: number;
}

/** Per-connection samples, by the send time of each input. */
export interface InputLatencyMetrics {
    latencyMs: number[];
    /** Send time of each timed input, parallel to `latencyMs`. */
    latencySentAt: number[];
    /** Dropped past `INPUT_LATENCY_MAX_PENDING` (a newer target can overwrite it before a sync). */
    supersededSentAt: number[];
    /** Not seen within `INPUT_LATENCY_TIMEOUT_MS`. */
    timedOutSentAt: number[];
}

export function emptyInputLatencyMetrics(): InputLatencyMetrics {
    return { latencyMs: [], latencySentAt: [], supersededSentAt: [], timedOutSentAt: [] };
}

function pointOf(value: unknown): EchoPoint | undefined {
    if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
    const v = (value as { v?: unknown }).v;
    if (typeof v !== "object" || v === null || Array.isArray(v)) return undefined;
    const { x, y } = v as { x?: unknown; y?: unknown };
    return Number.isInteger(x) && Number.isInteger(y) ? { x: x as number, y: y as number } : undefined;
}

/** The point of an event payload: its first top-level `{ v: { x, y } }` value with integer coordinates. */
export function echoPointOf(payload: Record<string, unknown>): EchoPoint | undefined {
    for (const value of Object.values(payload)) {
        const point = pointOf(value);
        if (point) return point;
    }
    return undefined;
}

/** Calls `visit` for every `{ v: { x, y } }` object (integer coordinates) anywhere in `raw`. */
export function forEachPoint(raw: unknown, visit: (x: number, y: number) => void): void {
    if (typeof raw !== "object" || raw === null) return;
    if (Array.isArray(raw)) {
        for (const item of raw) forEachPoint(item, visit);
        return;
    }
    const point = pointOf(raw);
    if (point) {
        visit(point.x, point.y);
        return;
    }
    for (const value of Object.values(raw as Record<string, unknown>)) forEachPoint(value, visit);
}

const keyOf = (x: number, y: number) => `${x},${y}`;

export class InputLatencyTracker {
    metrics: InputLatencyMetrics = emptyInputLatencyMetrics();
    /** Oldest first. */
    private pending: Array<{ key: string; sentAt: number }> = [];
    /** Raw samples (`--samples-dir`): every move event's outcome, as it is decided. */
    onSample?: (sentAt: number, seenAt: number | null, end?: "superseded" | "timedOut" | "pendingAtEnd" | "closedBeforeSeen") => void;

    get pendingCount(): number {
        return this.pending.length;
    }

    recordSent(point: EchoPoint, sentAt: number): void {
        if (this.pending.length >= INPUT_LATENCY_MAX_PENDING) {
            const superseded = this.pending.shift()!.sentAt;
            this.metrics.supersededSentAt.push(superseded);
            this.onSample?.(superseded, null, "superseded");
        }
        this.pending.push({ key: keyOf(point.x, point.y), sentAt });
    }

    /** A received state frame (decoded, before classification). */
    observe(raw: unknown, now: number): void {
        if (this.pending.length === 0) return;
        this.expire(now);
        if (this.pending.length === 0) return;
        forEachPoint(raw, (x, y) => {
            const key = keyOf(x, y);
            const index = this.pending.findIndex((p) => p.key === key);
            if (index >= 0) {
                const [{ sentAt }] = this.pending.splice(index, 1);
                this.metrics.latencyMs.push(now - sentAt);
                this.metrics.latencySentAt.push(sentAt);
                this.onSample?.(sentAt, now);
            }
        });
    }

    expire(now: number): void {
        while (this.pending.length > 0 && now - this.pending[0].sentAt > INPUT_LATENCY_TIMEOUT_MS) {
            const timedOut = this.pending.shift()!.sentAt;
            this.metrics.timedOutSentAt.push(timedOut);
            this.onSample?.(timedOut, null, "timedOut");
        }
    }

    /** The connection closed: the raw samples get the events still pending, with how it closed. */
    drainOnClose(end: "pendingAtEnd" | "closedBeforeSeen"): void {
        for (const { sentAt } of this.pending) {
            this.onSample?.(sentAt, null, end);
        }
        this.pending = [];
    }

    /** Starts a new phase's metrics; pending inputs carry over and count where they were sent. */
    resetMetrics(): void {
        this.metrics = emptyInputLatencyMetrics();
    }
}

export interface InputLatencyMeasurement {
    /** Inputs sent in the window that were seen, superseded or timed out (still pending: not counted). */
    sent: number;
    seen: number;
    superseded: number;
    timedOut: number;
    latencyMs: Distribution;
}

const inWindow = (at: number, from: number, to: number) => at >= from && at < to;

/** Inputs sent in `[from, to)`; null when no input was tracked, so reports without move events keep their shape. */
export function measureInputLatency(
    reports: Array<Partial<InputLatencyMetrics>>,
    from: number,
    to: number
): InputLatencyMeasurement | null {
    const latencies: number[] = [];
    let superseded = 0;
    let timedOut = 0;
    let tracked = false;
    for (const r of reports) {
        const sentAt = r.latencySentAt ?? [];
        const ms = r.latencyMs ?? [];
        tracked ||= sentAt.length + (r.supersededSentAt?.length ?? 0) + (r.timedOutSentAt?.length ?? 0) > 0;
        sentAt.forEach((at, i) => {
            if (inWindow(at, from, to)) latencies.push(ms[i]);
        });
        superseded += (r.supersededSentAt ?? []).filter((at) => inWindow(at, from, to)).length;
        timedOut += (r.timedOutSentAt ?? []).filter((at) => inWindow(at, from, to)).length;
    }
    if (!tracked) return null;
    return {
        sent: latencies.length + superseded + timedOut,
        seen: latencies.length,
        superseded,
        timedOut,
        latencyMs: distribution(latencies)
    };
}
