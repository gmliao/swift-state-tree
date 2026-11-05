import fs from "node:fs";

/**
 * One server sample from `monitoring/collect-system-metrics.mjs`.
 *
 * `cpuSec` is the server's cumulative CPU time (user + system); `monoMs` a monotonic clock for
 * interval lengths, `tsMs` the wall clock for placing a sample in a measured window. `cpuPct`
 * is derived on parse: the CPU rate over the interval ending at this sample (100 = one core),
 * null for the first sample. Files from the older `ps -o %cpu` sampler have only `ts` and
 * `cpuPct`, a lifetime average on Linux; they parse as before and give no server CPU summary.
 */
export interface SystemMetricSample {
    ts: number;
    tsMs?: number;
    monoMs?: number;
    cpuSec?: number;
    cpuPct: number | null;
    rssMb: number;
    load1: number;
}

export interface SystemMetrics {
    system: SystemMetricSample[];
}

/** Server CPU over one measured window, from the per-interval rates (100 = one core). */
export interface ServerCpuSummary {
    /** Sampling intervals wholly inside the window. */
    intervals: number;
    /** CPU time over the covered span divided by its length: the time-weighted mean rate. */
    meanPct: number;
    p95Pct: number;
    maxPct: number;
    /** The covered span: the first counted interval's start to the last one's end, ms since epoch. */
    coveredStartAt: number;
    coveredEndAt: number;
}

export interface ServerCpuPhase {
    phase: string;
    summary: ServerCpuSummary | null;
}

function hasCumulative(sample: SystemMetricSample): sample is SystemMetricSample & { tsMs: number; monoMs: number; cpuSec: number } {
    return typeof sample.cpuSec === "number" && typeof sample.monoMs === "number" && typeof sample.tsMs === "number";
}

/**
 * Sets each cumulative sample's `cpuPct` to the rate over the interval since the previous one:
 * CPU seconds used / monotonic seconds elapsed × 100. The first sample, and one whose interval
 * has no length, gets null. Samples without the cumulative fields are left as they are.
 */
export function withIntervalRates(samples: SystemMetricSample[]): SystemMetricSample[] {
    let previous: (SystemMetricSample & { monoMs: number; cpuSec: number }) | undefined;
    return samples.map((sample) => {
        if (!hasCumulative(sample)) {
            return sample;
        }
        const elapsedMs = previous ? sample.monoMs - previous.monoMs : 0;
        const cpuPct = previous && elapsedMs > 0 ? ((sample.cpuSec - previous.cpuSec) * 1000 * 100) / elapsedMs : null;
        previous = sample;
        return { ...sample, cpuPct };
    });
}

/**
 * Server CPU over [startAt, endAt] (ms since epoch), from the intervals whose both samples lie
 * inside it. Null when no interval does, or the samples have no cumulative CPU time.
 */
export function summarizeServerCpu(samples: SystemMetricSample[], startAt: number, endAt: number): ServerCpuSummary | null {
    const inside = samples.filter(hasCumulative).filter((sample) => sample.tsMs >= startAt && sample.tsMs <= endAt);
    if (inside.length < 2) {
        return null;
    }
    const rates: number[] = [];
    for (let i = 1; i < inside.length; i++) {
        const elapsedMs = inside[i].monoMs - inside[i - 1].monoMs;
        if (elapsedMs > 0) {
            rates.push(((inside[i].cpuSec - inside[i - 1].cpuSec) * 1000 * 100) / elapsedMs);
        }
    }
    const first = inside[0];
    const last = inside[inside.length - 1];
    const spanMs = last.monoMs - first.monoMs;
    if (rates.length === 0 || spanMs <= 0) {
        return null;
    }
    const sorted = [...rates].sort((a, b) => a - b);
    return {
        intervals: rates.length,
        meanPct: ((last.cpuSec - first.cpuSec) * 1000 * 100) / spanMs,
        p95Pct: sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)],
        maxPct: sorted[sorted.length - 1],
        coveredStartAt: first.tsMs,
        coveredEndAt: last.tsMs
    };
}

/** Per phase, the server CPU over its measured window; null when the samples have no cumulative CPU time. */
export function serverCpuByPhase(
    metrics: SystemMetrics,
    spans: Array<{ phase: string; startAt: number; endAt: number }>
): ServerCpuPhase[] | null {
    if (!metrics.system.some(hasCumulative)) {
        return null;
    }
    return spans.map((span) => ({ phase: span.phase, summary: summarizeServerCpu(metrics.system, span.startAt, span.endAt) }));
}

function parseSamples(raw: string): SystemMetricSample[] {
    try {
        return (JSON.parse(raw) as SystemMetrics).system;
    } catch {
        // Still being written: one sample per line.
        const system: SystemMetricSample[] = [];
        for (const line of raw.split(/\r?\n/)) {
            const trimmed = line.trim().replace(/,$/, "");
            if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) {
                continue;
            }
            try {
                system.push(JSON.parse(trimmed) as SystemMetricSample);
            } catch {
                continue;
            }
        }
        return system;
    }
}

export function parseSystemMetrics(raw: string): SystemMetrics {
    return { system: withIntervalRates(parseSamples(raw)) };
}

export function readSystemMetrics(filePath: string): SystemMetrics {
    const raw = fs.readFileSync(filePath, "utf-8");
    return parseSystemMetrics(raw);
}
