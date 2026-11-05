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

/** Buckets the phase's samples into windows of `windowMs` from `originAt` to `originAt + durationMs`. */
export function windowSamples(
    samples: TimedSamples,
    originAt: number,
    durationMs: number,
    windowMs: number,
    warmupMs: number
): WindowSample[] {
    const count = Math.max(1, Math.ceil(durationMs / windowMs));
    const rtt: number[][] = Array.from({ length: count }, () => []);
    const update: number[][] = Array.from({ length: count }, () => []);
    const sent = new Array<number>(count).fill(0);
    const bucket = (t: number) => {
        const i = Math.floor((t - originAt) / windowMs);
        return i >= 0 && i < count ? i : -1;
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
        startMs: i * windowMs,
        warmup: i * windowMs < warmupMs,
        rtt: distribution(values),
        update: distribution(update[i]),
        sent: sent[i]
    }));
}
