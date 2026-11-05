import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runScenario } from "./run";
import { buildReport, writeReportFiles } from "./report/render-html";
import { readSystemMetrics } from "./system-metrics";
import { LAYOUTS } from "./layout";
import type { Layout } from "./layout";
import { BOUNDARY_MODES, CONNECT_MODES, DEFAULT_CONNECT_RATE } from "./connect-schedule";
import type { BoundaryMode, ConnectMode } from "./connect-schedule";

export interface CliArgs {
    scenarioPath: string;
    workers: number;
    systemMetricsPath?: string;
    outputDir?: string;
    outputName?: string;
    /** `rooms` (default) or `per-connection` (legacy: one land per connection). */
    layout: Layout;
    /** `ramp` (default) or `burst` (legacy: all connections at once). */
    connectMode: ConnectMode;
    /** Ramp rate over all workers, connections per second. */
    connectRatePerSecond: number;
    /** `clean` (default: close frames) or `abrupt` (drop sockets, as the old tool did). */
    boundaryMode: BoundaryMode;
    /** Run phases whose ramp is longer than the phase (a warning instead of an error). */
    allowPartialRamp: boolean;
    /** Land id prefix (default: a new id per run). */
    runId?: string;
}

export function parseArgs(argv: string[]): CliArgs {
    const args = argv.slice(2);
    let scenarioPath = "scenarios/hero-defense/default.json";
    let workers = Math.max(1, os.cpus().length);
    let systemMetricsPath: string | undefined;
    let outputDir: string | undefined;
    let outputName: string | undefined;
    let layout: Layout = "rooms";
    let connectMode: ConnectMode = "ramp";
    let connectRatePerSecond = DEFAULT_CONNECT_RATE;
    let boundaryMode: BoundaryMode = "clean";
    let allowPartialRamp = false;
    let runId: string | undefined;

    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        if (arg === "--scenario") {
            scenarioPath = args[i + 1];
            i += 1;
        } else if (arg === "--workers") {
            workers = Number(args[i + 1]);
            i += 1;
        } else if (arg === "--system-metrics") {
            systemMetricsPath = args[i + 1];
            i += 1;
        } else if (arg === "--output-dir") {
            outputDir = args[i + 1];
            i += 1;
        } else if (arg === "--output-name") {
            outputName = args[i + 1];
            i += 1;
        } else if (arg === "--layout") {
            const value = args[i + 1];
            if (!LAYOUTS.includes(value as Layout)) {
                throw new Error(`--layout must be one of ${LAYOUTS.join(", ")} (got ${value})`);
            }
            layout = value as Layout;
            i += 1;
        } else if (arg === "--connect") {
            const value = args[i + 1];
            if (!CONNECT_MODES.includes(value as ConnectMode)) {
                throw new Error(`--connect must be one of ${CONNECT_MODES.join(", ")} (got ${value})`);
            }
            connectMode = value as ConnectMode;
            i += 1;
        } else if (arg === "--connect-rate") {
            const value = Number(args[i + 1]);
            if (!Number.isFinite(value) || value <= 0) {
                throw new Error(`--connect-rate must be a positive number (got ${args[i + 1]})`);
            }
            connectRatePerSecond = value;
            i += 1;
        } else if (arg === "--boundary") {
            const value = args[i + 1];
            if (!BOUNDARY_MODES.includes(value as BoundaryMode)) {
                throw new Error(`--boundary must be one of ${BOUNDARY_MODES.join(", ")} (got ${value})`);
            }
            boundaryMode = value as BoundaryMode;
            i += 1;
        } else if (arg === "--allow-partial-ramp") {
            allowPartialRamp = true;
        } else if (arg === "--run-id") {
            const value = args[i + 1];
            if (!value || !/^[A-Za-z0-9_-]+$/.test(value)) {
                throw new Error(`--run-id must be letters, digits, '-' or '_' (got ${value})`);
            }
            runId = value;
            i += 1;
        }
    }

    return {
        scenarioPath,
        workers,
        systemMetricsPath,
        outputDir,
        outputName,
        layout,
        connectMode,
        connectRatePerSecond,
        boundaryMode,
        allowPartialRamp,
        runId
    };
}

export async function main(): Promise<void> {
    const {
        scenarioPath,
        workers,
        systemMetricsPath,
        outputDir,
        outputName,
        layout,
        connectMode,
        connectRatePerSecond,
        boundaryMode,
        allowPartialRamp,
        runId
    } = parseArgs(process.argv);
    const resolvedPath = path.resolve(process.cwd(), scenarioPath);
    if (!fs.existsSync(resolvedPath)) {
        throw new Error(`Scenario not found: ${resolvedPath}`);
    }
    const result = await runScenario(resolvedPath, {
        workers,
        layout,
        connectMode,
        connectRatePerSecond,
        boundaryMode,
        allowPartialRamp,
        runId
    });
    const metricsPath = systemMetricsPath ? path.resolve(process.cwd(), systemMetricsPath) : undefined;
    const systemMetrics = metricsPath && fs.existsSync(metricsPath) ? readSystemMetrics(metricsPath) : { system: [] };
    const report = buildReport(result, systemMetrics);
    const outputDirectory = outputDir ? path.resolve(process.cwd(), outputDir) : path.resolve(process.cwd(), "results");
    const baseName = outputName ?? `ws-loadtest-${Date.now()}`;
    writeReportFiles(report, outputDirectory, baseName);
    console.log(`Report written to ${outputDirectory}/${baseName}.{json,html}`);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}
