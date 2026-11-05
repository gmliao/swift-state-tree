/**
 * Load-client CPU: every worker samples its own process CPU time (`process.cpuUsage()`, user +
 * system) through a phase, and the measured window's CPU share is read from those samples. At a
 * high event rate the client's event loop adds lag to RTT, so the report shows how busy the
 * load client was next to it.
 */

/** One sample: wall time (ms since epoch) and the process's cumulative CPU time (ms). */
export type CpuSample = [t: number, cpuMs: number];

export const CPU_SAMPLE_INTERVAL_MS = 500;

/** The process's cumulative CPU time (user + system), ms. */
export function processCpuMs(): number {
    const usage = process.cpuUsage();
    return (usage.user + usage.system) / 1000;
}

/**
 * Samples this process's CPU time every `intervalMs` until stopped; the returned function stops
 * it, takes a last sample and returns them all.
 */
export function startCpuSampler(
    intervalMs = CPU_SAMPLE_INTERVAL_MS,
    now: () => number = Date.now,
    cpuMs: () => number = processCpuMs
): () => CpuSample[] {
    const samples: CpuSample[] = [[now(), cpuMs()]];
    const timer = setInterval(() => samples.push([now(), cpuMs()]), intervalMs);
    (timer as { unref?: () => void }).unref?.();
    return () => {
        clearInterval(timer);
        samples.push([now(), cpuMs()]);
        return samples;
    };
}

/** CPU time at `t`, interpolated between the samples around it; undefined outside them. */
export function cpuAt(samples: CpuSample[], t: number): number | undefined {
    if (samples.length === 0 || t < samples[0][0] || t > samples[samples.length - 1][0]) {
        return undefined;
    }
    for (let i = 1; i < samples.length; i += 1) {
        const [t1, c1] = samples[i];
        if (t <= t1) {
            const [t0, c0] = samples[i - 1];
            return t1 === t0 ? c1 : c0 + ((c1 - c0) * (t - t0)) / (t1 - t0);
        }
    }
    return samples[samples.length - 1][1];
}

export interface ClientCpu {
    /** Workers whose samples cover the window. */
    workers: number;
    /** Each worker's CPU in the window, % of one core (100 = one core busy). */
    perWorkerPct: { min: number; mean: number; max: number };
    /** All workers together, % of one core. */
    totalPct: number;
    /** CPUs the load client sees (`os.cpus().length`). */
    cores: number;
}

/** The workers' CPU share over `[from, to)` from their samples. */
export function measureClientCpu(perWorker: CpuSample[][], from: number, to: number, cores: number): ClientCpu {
    const pct: number[] = [];
    if (to > from) {
        for (const samples of perWorker) {
            const start = cpuAt(samples, from);
            const end = cpuAt(samples, to);
            if (start !== undefined && end !== undefined) {
                pct.push(((end - start) / (to - from)) * 100);
            }
        }
    }
    const round1 = (n: number) => Math.round(n * 10) / 10;
    const total = pct.reduce((sum, p) => sum + p, 0);
    return {
        workers: pct.length,
        perWorkerPct: {
            min: pct.length > 0 ? round1(Math.min(...pct)) : 0,
            mean: pct.length > 0 ? round1(total / pct.length) : 0,
            max: pct.length > 0 ? round1(Math.max(...pct)) : 0
        },
        totalPct: round1(total),
        cores
    };
}
