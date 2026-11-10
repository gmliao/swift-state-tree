/**
 * Load-client event-loop utilization (ELU): every worker samples its own cumulative event-loop
 * active and idle time (`performance.eventLoopUtilization()`) through a phase, and the measured
 * window's ELU is read from those samples: active time over active plus idle time in the window.
 * With the workers' CPU (`client-cpu`) it tells whether the load client is the bottleneck it
 * measures: a worker near ELU 1 can't keep its send schedule.
 */

import { performance } from "node:perf_hooks";

/** One sample: wall time (ms since epoch), and the event loop's cumulative active and idle time (ms). */
export type EluSample = [t: number, activeMs: number, idleMs: number];

/** This process's cumulative event-loop active and idle time, ms. */
export function processElu(): { active: number; idle: number } {
    const { active, idle } = performance.eventLoopUtilization();
    return { active, idle };
}

/**
 * Samples this process's event loop every `intervalMs` until stopped; the returned function stops
 * it, takes a last sample and returns them all.
 */
export function startEluSampler(
    intervalMs: number,
    now: () => number = Date.now,
    read: () => { active: number; idle: number } = processElu
): () => EluSample[] {
    const take = (): EluSample => {
        const { active, idle } = read();
        return [now(), active, idle];
    };
    const samples: EluSample[] = [take()];
    const timer = setInterval(() => samples.push(take()), intervalMs);
    (timer as { unref?: () => void }).unref?.();
    return () => {
        clearInterval(timer);
        samples.push(take());
        return samples;
    };
}

/** Active and idle time at `t`, interpolated between the samples around it; undefined outside them. */
export function eluAt(samples: EluSample[], t: number): [activeMs: number, idleMs: number] | undefined {
    if (samples.length === 0 || t < samples[0][0] || t > samples[samples.length - 1][0]) {
        return undefined;
    }
    for (let i = 1; i < samples.length; i += 1) {
        const [t1, a1, i1] = samples[i];
        if (t <= t1) {
            const [t0, a0, i0] = samples[i - 1];
            if (t1 === t0) {
                return [a1, i1];
            }
            const f = (t - t0) / (t1 - t0);
            return [a0 + (a1 - a0) * f, i0 + (i1 - i0) * f];
        }
    }
    const [, a, i] = samples[samples.length - 1];
    return [a, i];
}

export interface ClientElu {
    /** Workers whose samples cover the window. */
    workers: number;
    /** Each worker's ELU in the window, 0-1 (1 = its event loop never idle). */
    perWorker: { min: number; mean: number; max: number };
}

/** One worker's ELU over `[from, to)`; undefined if its samples don't cover it or show no loop time. */
function windowElu(samples: EluSample[], from: number, to: number): number | undefined {
    if (to <= from) {
        return undefined;
    }
    const start = eluAt(samples, from);
    const end = eluAt(samples, to);
    if (start === undefined || end === undefined) {
        return undefined;
    }
    const active = end[0] - start[0];
    const total = active + (end[1] - start[1]);
    return total > 0 ? active / total : undefined;
}

/** The workers' ELU over `[from, to)` from their samples. */
export function measureClientElu(perWorker: EluSample[][], from: number, to: number): ClientElu {
    const elu = perWorker.map((samples) => windowElu(samples, from, to)).filter((e): e is number => e !== undefined);
    const round3 = (n: number) => Math.round(n * 1000) / 1000;
    const sum = elu.reduce((total, e) => total + e, 0);
    return {
        workers: elu.length,
        perWorker: {
            min: elu.length > 0 ? round3(Math.min(...elu)) : 0,
            mean: elu.length > 0 ? round3(sum / elu.length) : 0,
            max: elu.length > 0 ? round3(Math.max(...elu)) : 0
        }
    };
}
