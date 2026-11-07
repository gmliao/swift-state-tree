/**
 * Load-client event-loop delay: every worker monitors its own event loop
 * (`perf_hooks.monitorEventLoopDelay`) over the measured window. A busy loop delays reading
 * frames and firing send timers, which shows up as RTT and send lag that the server did not
 * cause.
 */
import { monitorEventLoopDelay } from "node:perf_hooks";
import { timerAt } from "./timer-at";

/** The monitor's sampling interval. Each sample is the time between two ticks of it. */
export const LOOP_DELAY_RESOLUTION_MS = 1;

/** One worker's event-loop delay in the window: time beyond the sampling interval, ms. */
export interface LoopDelay {
    p50Ms: number;
    p99Ms: number;
    maxMs: number;
    samples: number;
}

/** The part of `IntervalHistogram` read here (values in ns). */
export interface DelayHistogram {
    count: number;
    max: number;
    min: number;
    percentile(p: number): number;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/** The delay beyond `resolutionMs` from a histogram; null without samples. */
export function loopDelayFromHistogram(histogram: DelayHistogram, resolutionMs: number): LoopDelay | null {
    if (histogram.count === 0) {
        return null;
    }
    const delayMs = (ns: number) => round2(Math.max(0, ns / 1e6 - resolutionMs));
    return {
        p50Ms: delayMs(histogram.percentile(50)),
        p99Ms: delayMs(histogram.percentile(99)),
        maxMs: delayMs(histogram.max),
        samples: histogram.count
    };
}

/** The part of `IntervalHistogram` the monitor drives: sampling on and off, and the reads. */
export interface SamplingHistogram extends DelayHistogram {
    enable(): unknown;
    disable(): unknown;
}

/**
 * Monitors this process's event loop from `from` (wall clock, never earlier) until stopped; the
 * returned function stops it and returns the delay, null if the window never started.
 * `createHistogram` is `perf_hooks.monitorEventLoopDelay`; tests pass a fake, so they check the
 * window without measuring a real loop.
 */
export function startLoopDelayMonitor(
    from: number,
    resolutionMs = LOOP_DELAY_RESOLUTION_MS,
    createHistogram: (resolutionMs: number) => SamplingHistogram = (resolution) => monitorEventLoopDelay({ resolution })
): () => LoopDelay | null {
    const histogram = createHistogram(resolutionMs);
    let enabled = false;
    const start = timerAt(from, () => {
        enabled = true;
        histogram.enable();
    });
    return () => {
        start.cancel();
        if (!enabled) {
            return null;
        }
        histogram.disable();
        return loopDelayFromHistogram(histogram, resolutionMs);
    };
}

export interface ClientLoopDelay {
    /** Workers with samples in the window. */
    workers: number;
    /** p50 across workers: their mean and the worst one. */
    p50Ms: { mean: number; max: number };
    /** p99 across workers: their mean and the worst one. */
    p99Ms: { mean: number; max: number };
    /** The longest delay any worker saw. */
    maxMs: number;
}

/** The workers' event-loop delay, from each worker's own window. */
export function summarizeLoopDelay(perWorker: (LoopDelay | null | undefined)[]): ClientLoopDelay {
    const delays = perWorker.filter((d): d is LoopDelay => d != null);
    const stat = (pick: (d: LoopDelay) => number) => {
        const values = delays.map(pick);
        return values.length === 0
            ? { mean: 0, max: 0 }
            : { mean: round2(values.reduce((s, v) => s + v, 0) / values.length), max: Math.max(...values) };
    };
    return {
        workers: delays.length,
        p50Ms: stat((d) => d.p50Ms),
        p99Ms: stat((d) => d.p99Ms),
        maxMs: delays.length === 0 ? 0 : Math.max(...delays.map((d) => d.maxMs))
    };
}
