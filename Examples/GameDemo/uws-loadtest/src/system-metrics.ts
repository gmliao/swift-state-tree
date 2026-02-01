import fs from "node:fs";

export interface SystemMetricSample {
    ts: number;
    cpuPct: number;
    rssMb: number;
    load1: number;
}

export interface SystemMetrics {
    system: SystemMetricSample[];
}

export function parseSystemMetrics(raw: string): SystemMetrics {
    try {
        return JSON.parse(raw) as SystemMetrics;
    } catch {
        const system: SystemMetricSample[] = [];
        const lines = raw.split(/\r?\n/);
        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) {
                continue;
            }
            try {
                system.push(JSON.parse(trimmed) as SystemMetricSample);
            } catch {
                continue;
            }
        }
        return { system };
    }
}

export function readSystemMetrics(filePath: string): SystemMetrics {
    const raw = fs.readFileSync(filePath, "utf-8");
    return parseSystemMetrics(raw);
}
