import { distribution, type Distribution } from "./samples";

/**
 * Input-to-visible latency (#64): from sending a move event until a state frame first shows its
 * point. Both lands echo the event's point into synced state as it was sent:
 * - hero-defense `MoveTo { target }` sets `players[id].targetPosition`, clamped to the world,
 *   which the `moveTo` generator's targets are already inside;
 * - visibility-test `MoveViewer { position }` sets `viewers[id].position`.
 *
 * The server diffs a `Position2` as one value (`SyncEngine.isAtomicType`), so the point arrives
 * whole, in one of two wire shapes: keyed, `{ v: { x, y } }` (the json encoding), or positional,
 * `[x, y]` (the opcode encodings since #271, also nested in an added object, a firstSync and a
 * merged entry's values). Paths may be hashed or indexed and keys compressed; the value keeps one
 * of those two shapes. The tracker scans the state part of each state frame (not an opcode-107
 * frame's events: a `PlayerShootEvent.from` equals a target once the player reaches it) for a
 * pending point; it needs neither the schema nor the client's state. A false match needs another
 * point with exactly the same fixed-point x and y in the same frame's state.
 *
 * The matcher is keyed to the wire shape, so an encoding change can silently stop it from seeing
 * anything; `inputLatencyHitRateFailure` gates the share of inputs seen.
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

/** A positional point: an array of exactly two integers. */
function positionalPoint(value: unknown[]): EchoPoint | undefined {
    return value.length === 2 && Number.isInteger(value[0]) && Number.isInteger(value[1])
        ? { x: value[0] as number, y: value[1] as number }
        : undefined;
}

/**
 * Calls `visit` for every point anywhere in `raw`: a keyed `{ v: { x, y } }` object or a
 * positional `[x, y]` array (integer coordinates).
 */
export function forEachPoint(raw: unknown, visit: (x: number, y: number) => void): void {
    if (typeof raw !== "object" || raw === null) return;
    if (Array.isArray(raw)) {
        const point = positionalPoint(raw);
        if (point) {
            visit(point.x, point.y);
            return;
        }
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

/** Opcode 107 (`[107, stateUpdate, events]`): the state update only. Other frames: as they are. */
export function statePartOf(raw: unknown): unknown {
    return Array.isArray(raw) && raw[0] === 107 ? raw[1] : raw;
}

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
        forEachPoint(statePartOf(raw), (x, y) => {
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

/**
 * The least share of a phase's inputs that must be seen (`--input-latency-min-seen`, default).
 * Without impairment every input is seen: 2997 of 2997 (messagepack) and 2998 of 2998 (json) in a
 * 10-room, 5-player, 1-per-second local run after the positional fix. Before it, about 5 % were.
 */
export const INPUT_LATENCY_MIN_SEEN_DEFAULT = 0.95;
/** Below this many inputs in a phase, the share isn't gated. */
export const INPUT_LATENCY_GATE_MIN_SENT = 100;

/**
 * A phase's failure when too few of its inputs were seen: the matcher is keyed to the wire shape
 * of the echoed point, so an encoding change shows up here as a share near 0, not as fast
 * latencies. `minSeen` 0 turns the gate off (a run whose impairment may hide inputs).
 */
export function inputLatencyHitRateFailure(m: InputLatencyMeasurement | undefined, minSeen: number): string | undefined {
    if (!m || minSeen <= 0 || m.sent < INPUT_LATENCY_GATE_MIN_SENT) return undefined;
    const share = m.seen / m.sent;
    if (share >= minSeen) return undefined;
    return (
        `inputToVisible seen ${m.seen} of ${m.sent} (${(share * 100).toFixed(1)} %) < ${(minSeen * 100).toFixed(0)} %: ` +
        `the input-latency matcher (input-latency.ts forEachPoint) isn't finding the echoed points; ` +
        `check the wire shape of the echoed value`
    );
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
