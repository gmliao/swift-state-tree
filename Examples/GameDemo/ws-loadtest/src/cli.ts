import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runScenario } from "./run";
import { buildReport, writeReportFiles } from "./report/render-html";
import { readSystemMetrics } from "./system-metrics";
import { measuredSpans, readProfileAfter, serverSyncByPhase } from "./server-sync";
import { LAYOUTS } from "./layout";
import type { Layout } from "./layout";
import { BOUNDARY_MODES, CONNECT_MODES, DEFAULT_CONNECT_RATE } from "./connect-schedule";
import type { BoundaryMode, ConnectMode } from "./connect-schedule";
import { DEFAULT_WINDOW_MS, SEND_MODES } from "./send-schedule";
import type { SendMode } from "./send-schedule";

export interface CliArgs {
    scenarioPath: string;
    workers: number;
    systemMetricsPath?: string;
    /** The server's transport profile JSONL; its sync counters go in the report's `serverSync`. */
    transportProfilePath?: string;
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
    /** Join failures and a joined count below target don't fail a phase. */
    allowJoinFailures: boolean;
    /** Land id prefix (default: a new id per run). */
    runId?: string;
    /** `spread` (default: per-client offsets, RTT from the intended send) or `lockstep` (legacy). */
    sendMode: SendMode;
    /** Per-window sample length in ms. */
    windowMs: number;
    /** Warm-up for every phase, overriding the scenario and the default. */
    warmupSeconds?: number;
    /** `MoveTo` events per player per second (moving players); 0 turns them off. Unset: the scenario's events. */
    moveToRate?: number;
    /** Seed of the event payload generators, overriding the scenario's. */
    eventSeed?: number;
}

export function parseArgs(argv: string[]): CliArgs {
    const args = argv.slice(2);
    let scenarioPath = "scenarios/hero-defense/default.json";
    let workers = Math.max(1, os.cpus().length);
    let systemMetricsPath: string | undefined;
    let transportProfilePath: string | undefined;
    let outputDir: string | undefined;
    let outputName: string | undefined;
    let layout: Layout = "rooms";
    let connectMode: ConnectMode = "ramp";
    let connectRatePerSecond = DEFAULT_CONNECT_RATE;
    let boundaryMode: BoundaryMode = "clean";
    let allowPartialRamp = false;
    let allowJoinFailures = false;
    let runId: string | undefined;
    let sendMode: SendMode = "spread";
    let windowMs = DEFAULT_WINDOW_MS;
    let warmupSeconds: number | undefined;
    let moveToRate: number | undefined;
    let eventSeed: number | undefined;

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
        } else if (arg === "--transport-profile") {
            transportProfilePath = args[i + 1];
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
        } else if (arg === "--allow-join-failures") {
            allowJoinFailures = true;
        } else if (arg === "--run-id") {
            const value = args[i + 1];
            if (!value || !/^[A-Za-z0-9_-]+$/.test(value)) {
                throw new Error(`--run-id must be letters, digits, '-' or '_' (got ${value})`);
            }
            runId = value;
            i += 1;
        } else if (arg === "--send") {
            const value = args[i + 1];
            if (!SEND_MODES.includes(value as SendMode)) {
                throw new Error(`--send must be one of ${SEND_MODES.join(", ")} (got ${value})`);
            }
            sendMode = value as SendMode;
            i += 1;
        } else if (arg === "--window-ms") {
            const value = Number(args[i + 1]);
            if (!Number.isFinite(value) || value <= 0) {
                throw new Error(`--window-ms must be a positive number (got ${args[i + 1]})`);
            }
            windowMs = value;
            i += 1;
        } else if (arg === "--warmup-seconds") {
            const value = Number(args[i + 1]);
            if (!Number.isFinite(value) || value < 0) {
                throw new Error(`--warmup-seconds must be 0 or more (got ${args[i + 1]})`);
            }
            warmupSeconds = value;
            i += 1;
        } else if (arg === "--move-to-rate") {
            const value = Number(args[i + 1]);
            if (!Number.isFinite(value) || value < 0) {
                throw new Error(`--move-to-rate must be 0 or more (got ${args[i + 1]})`);
            }
            moveToRate = value;
            i += 1;
        } else if (arg === "--event-seed") {
            const value = Number(args[i + 1]);
            if (!Number.isInteger(value)) {
                throw new Error(`--event-seed must be an integer (got ${args[i + 1]})`);
            }
            eventSeed = value;
            i += 1;
        }
    }

    return {
        scenarioPath,
        workers,
        systemMetricsPath,
        transportProfilePath,
        outputDir,
        outputName,
        layout,
        connectMode,
        connectRatePerSecond,
        boundaryMode,
        allowPartialRamp,
        allowJoinFailures,
        runId,
        sendMode,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed
    };
}

export async function main(): Promise<void> {
    const {
        scenarioPath,
        workers,
        systemMetricsPath,
        transportProfilePath,
        outputDir,
        outputName,
        layout,
        connectMode,
        connectRatePerSecond,
        boundaryMode,
        allowPartialRamp,
        allowJoinFailures,
        runId,
        sendMode,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed
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
        allowJoinFailures,
        runId,
        sendMode,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed
    });
    const metricsPath = systemMetricsPath ? path.resolve(process.cwd(), systemMetricsPath) : undefined;
    const systemMetrics = metricsPath && fs.existsSync(metricsPath) ? readSystemMetrics(metricsPath) : { system: [] };
    const profilePath = transportProfilePath ? path.resolve(process.cwd(), transportProfilePath) : undefined;
    // The server sync counters cover each phase's measured window, the span of the client
    // metrics; wait for the profile window that closes the last one to be flushed.
    const spans = measuredSpans(result.phases);
    const lastEnd = spans.reduce((max, span) => Math.max(max, span.endAt), 0);
    const profile = await readProfileAfter(profilePath, lastEnd);
    const report = buildReport(result, systemMetrics, serverSyncByPhase(profile, spans));
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
