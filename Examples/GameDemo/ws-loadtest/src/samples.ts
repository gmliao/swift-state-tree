import { percentile } from "./metrics";

/** Concatenates without spreading (large sample arrays overflow the call stack with push(...)). */
export function concatAll<T>(parts: T[][]): T[] {
    let total = 0;
    for (const part of parts) {
        total += part.length;
    }
    const out: T[] = new Array(total);
    let index = 0;
    for (const part of parts) {
        for (let i = 0; i < part.length; i += 1) {
            out[index++] = part[i];
        }
    }
    return out;
}

/** The values whose time is in `[from, to)`; `values` and `at` are parallel arrays. */
export function selectByTime(values: number[], at: number[], from: number, to: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < values.length; i += 1) {
        if (at[i] >= from && at[i] < to) {
            out.push(values[i]);
        }
    }
    return out;
}

export interface Distribution {
    count: number;
    p50: number;
    p95: number;
    p99: number;
    max: number;
}

export function distribution(values: number[]): Distribution {
    let max = 0;
    for (const v of values) {
        if (v > max) max = v;
    }
    return {
        count: values.length,
        p50: percentile(values, 0.5),
        p95: percentile(values, 0.95),
        p99: percentile(values, 0.99),
        max
    };
}

/** One time window of a phase. */
export interface WindowSample {
    /** Window start, ms after the phase origin. */
    startMs: number;
    /** Window end, ms after the phase origin (shorter than `windowMs` at the warm-up end and phase end). */
    endMs: number;
    /** Inside the warm-up (excluded from the phase's steady-state metrics). */
    warmup: boolean;
    rtt: Distribution;
    update: Distribution;
    /** Actions actually sent in the window. */
    sent: number;
}

export interface TimedSamples {
    rttMs: number[];
    rttAt: number[];
    stateUpdateIntervalsMs: number[];
    updateAt: number[];
    sentAt: number[];
}

/**
 * Window edges in ms after the origin. Windows of `windowMs` run from the origin to the end of
 * the warm-up and again from there to the phase end, so no window straddles the warm-up
 * boundary: the last warm-up window and the last window are cut short instead.
 */
export function windowEdges(durationMs: number, windowMs: number, warmupMs: number): number[] {
    const edges = [0];
    const boundary = Math.min(Math.max(0, warmupMs), durationMs);
    for (const end of [boundary, durationMs]) {
        let t = edges[edges.length - 1];
        while (t < end) {
            t = Math.min(t + windowMs, end);
            edges.push(t);
        }
    }
    return edges.length > 1 ? edges : [0, Math.max(durationMs, 0)];
}

/** Buckets the phase's samples into windows (see `windowEdges`) from `originAt`. */
export function windowSamples(
    samples: TimedSamples,
    originAt: number,
    durationMs: number,
    windowMs: number,
    warmupMs: number
): WindowSample[] {
    const edges = windowEdges(durationMs, windowMs, warmupMs);
    const count = edges.length - 1;
    const rtt: number[][] = Array.from({ length: count }, () => []);
    const update: number[][] = Array.from({ length: count }, () => []);
    const sent = new Array<number>(count).fill(0);
    const bucket = (t: number) => {
        const offset = t - originAt;
        if (offset < 0 || offset >= edges[count]) {
            return -1;
        }
        // Binary search for the window whose [start, end) holds offset.
        let lo = 0;
        let hi = count - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (edges[mid] <= offset) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    };
    samples.rttMs.forEach((v, i) => {
        const b = bucket(samples.rttAt[i]);
        if (b >= 0) rtt[b].push(v);
    });
    samples.stateUpdateIntervalsMs.forEach((v, i) => {
        const b = bucket(samples.updateAt[i]);
        if (b >= 0) update[b].push(v);
    });
    samples.sentAt.forEach((t) => {
        const b = bucket(t);
        if (b >= 0) sent[b] += 1;
    });
    return rtt.map((values, i) => ({
        startMs: edges[i],
        endMs: edges[i + 1],
        warmup: edges[i + 1] <= warmupMs && warmupMs > 0,
        rtt: distribution(values),
        update: distribution(update[i]),
        sent: sent[i]
    }));
}

/** Total time inside `[from, to)` covered by `intervals` (each counted separately). */
export function coveredMs(intervals: Array<[number, number]>, from: number, to: number): number {
    let total = 0;
    for (const [start, end] of intervals) {
        total += Math.max(0, Math.min(end, to) - Math.max(start, from));
    }
    return total;
}

/** Number of `times` in `[from, to)`. */
export function countInRange(times: number[], from: number, to: number): number {
    let n = 0;
    for (const t of times) {
        if (t >= from && t < to) n += 1;
    }
    return n;
}
