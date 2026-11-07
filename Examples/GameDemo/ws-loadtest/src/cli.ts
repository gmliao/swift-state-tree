import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runScenario } from "./run";
import { buildReport, writeReportFiles } from "./report/render-html";
import { readSystemMetrics, serverCpuByPhase } from "./system-metrics";
import { measuredSpans, readProfileAfter, serverSyncByPhase } from "./server-sync";
import { serverSendByPhase } from "./server-send";
import { LAYOUTS, parseRoomSlots } from "./layout";
import type { Layout, RoomSlotRange } from "./layout";
import type { SlowReadOption } from "./run";
import { BOUNDARY_MODES, CONNECT_MODES, DEFAULT_CONNECT_RATE } from "./connect-schedule";
import type { BoundaryMode, ConnectMode } from "./connect-schedule";
import { DEFAULT_WINDOW_MS, SEND_MODES } from "./send-schedule";
import type { SendMode } from "./send-schedule";

/** Printed for `--help` and after an unknown argument. */
export const USAGE = `Usage: node dist/cli.js [options]

Runs the scenario's phases against its server and writes a JSON + HTML report.

  --scenario <path>            Scenario JSON (default: scenarios/hero-defense/default.json)
  --workers <n>                Worker processes (default: CPU count)
  --layout <rooms|per-connection>
  --connect <ramp|burst>       Connect mode (default: ramp)
  --connect-rate <n>           Ramp rate over all workers, connections/s (default: 1000)
  --boundary <clean|abrupt>    Phase boundary closes (default: clean)
  --allow-partial-ramp         Warn instead of failing when the ramp outlasts a phase
  --allow-join-failures        Join failures do not fail a phase
  --run-id <id>                Land id prefix (letters, digits, '-', '_')
  --send <spread|lockstep>     Send mode (default: spread)
  --input-latency <on|off>     Time move events until a state update shows them (default: off)
  --window-ms <n>              Per-window sample length, ms
  --warmup-seconds <n>         Warm-up of every phase, overriding the scenario
  --move-to-rate <n>           MoveTo events per player per second; 0 removes them
  --event-seed <n>             Seed of the event payload generators
  --room-slots <spec>          Hold only these room slots, e.g. 0-149:0 or 0-149:1-4,150-299:0-4
                               (rooms layout; with the same --run-id, two instances share rooms)
  --start-at <epoch ms>        Start the first phase at this time, after the workers are up
  --stale-after <s>            Abandon a joined connection with no server frame for this long
                               (e.g. 10 or 10s; suspended while --slow-read pauses reading)
  --slow-read <start>:<dur>    Every connection stops reading its socket for <dur> s, starting
                               <start> s after the first phase starts, and keeps sending
  --samples-dir <dir>          Write raw per-event samples, one w<worker>.ndjson.gz per worker
  --reconnect on-server-close  Reopen a joined connection the server or --stale-after closed:
                               1 s later, then every 1 s after a failed attempt (5 s each)
  --reconnect-until <s>        No reconnect attempt starts later than this, s after the first
                               phase starts (default: until the run ends)
  --system-metrics <path>      System metrics JSONL to include in the report
  --transport-profile <path>   Server transport profile JSONL to include in the report
  --output-dir <dir>           Report directory (default: results)
  --output-name <name>         Report base name (default: ws-loadtest-<timestamp>)
  -h, --help                   Print this help and exit`;

export interface CliArgs {
    /** `--help` / `-h`: print the usage and start no run. */
    help: boolean;
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
    /** `--input-latency`: time MoveTo/MoveViewer events until visible (default off: it costs load-client CPU). */
    inputLatency: boolean;
    /** Per-window sample length in ms. */
    windowMs: number;
    /** Warm-up for every phase, overriding the scenario and the default. */
    warmupSeconds?: number;
    /** `MoveTo` events per player per second (moving players); 0 turns them off. Unset: the scenario's events. */
    moveToRate?: number;
    /** Seed of the event payload generators, overriding the scenario's. */
    eventSeed?: number;
    /** `--room-slots`: only these room slots (rooms layout). */
    roomSlots?: RoomSlotRange[];
    /** `--start-at`: the first phase's start, ms since epoch. */
    startAt?: number;
    /** `--stale-after`, seconds. */
    staleAfterSeconds?: number;
    /** `--slow-read`, seconds. */
    slowRead?: SlowReadOption;
    /** `--samples-dir`. */
    samplesDir?: string;
    /** `--reconnect on-server-close`, with `--reconnect-until`. */
    reconnect?: { untilSeconds?: number };
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
    let inputLatency = false;
    let windowMs = DEFAULT_WINDOW_MS;
    let warmupSeconds: number | undefined;
    let moveToRate: number | undefined;
    let eventSeed: number | undefined;
    let roomSlots: RoomSlotRange[] | undefined;
    let startAt: number | undefined;
    let staleAfterSeconds: number | undefined;
    let slowRead: SlowReadOption | undefined;
    let samplesDir: string | undefined;
    let reconnectOn = false;
    let reconnectUntil: number | undefined;
    let help = false;

    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        if (arg === "--help" || arg === "-h") {
            help = true;
        } else if (arg === "--scenario") {
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
        } else if (arg === "--input-latency") {
            const value = args[i + 1];
            if (value !== "on" && value !== "off") {
                throw new Error(`--input-latency must be on or off (got ${value})`);
            }
            inputLatency = value === "on";
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
        } else if (arg === "--room-slots") {
            roomSlots = parseRoomSlots(args[i + 1] ?? "");
            i += 1;
        } else if (arg === "--start-at") {
            const value = Number(args[i + 1]);
            if (!Number.isInteger(value) || value <= 0) {
                throw new Error(`--start-at must be a time in ms since epoch (got ${args[i + 1]})`);
            }
            startAt = value;
            i += 1;
        } else if (arg === "--stale-after") {
            const text = args[i + 1] ?? "";
            const value = Number(text.endsWith("s") ? text.slice(0, -1) : text);
            if (text === "" || !Number.isFinite(value) || value <= 0) {
                throw new Error(`--stale-after must be a positive number of seconds, e.g. 10 or 10s (got ${args[i + 1]})`);
            }
            staleAfterSeconds = value;
            i += 1;
        } else if (arg === "--slow-read") {
            const match = /^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$/.exec(args[i + 1] ?? "");
            if (!match || Number(match[2]) <= 0) {
                throw new Error(`--slow-read must be <start>:<duration> in seconds, duration above 0 (got ${args[i + 1]})`);
            }
            slowRead = { startSeconds: Number(match[1]), durationSeconds: Number(match[2]) };
            i += 1;
        } else if (arg === "--samples-dir") {
            const value = args[i + 1];
            if (!value || value.startsWith("--")) {
                throw new Error(`--samples-dir needs a directory (got ${value})`);
            }
            samplesDir = value;
            i += 1;
        } else if (arg === "--reconnect") {
            if (args[i + 1] !== "on-server-close") {
                throw new Error(`--reconnect must be on-server-close (got ${args[i + 1]})`);
            }
            reconnectOn = true;
            i += 1;
        } else if (arg === "--reconnect-until") {
            const value = Number(args[i + 1]);
            if (!Number.isFinite(value) || value <= 0) {
                throw new Error(`--reconnect-until must be a positive number of seconds (got ${args[i + 1]})`);
            }
            reconnectUntil = value;
            i += 1;
        } else {
            // An unknown flag or a stray value must not fall through to a default-scenario run.
            throw new Error(`Unknown argument: ${arg}\n\n${USAGE}`);
        }
    }

    if (reconnectUntil !== undefined && !reconnectOn) {
        throw new Error("--reconnect-until needs --reconnect on-server-close");
    }
    const reconnect = reconnectOn ? { untilSeconds: reconnectUntil } : undefined;
    return {
        help,
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
        inputLatency,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed,
        roomSlots,
        startAt,
        staleAfterSeconds,
        slowRead,
        samplesDir,
        reconnect
    };
}

export async function main(argv: string[] = process.argv): Promise<void> {
    const {
        help,
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
        inputLatency,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed,
        roomSlots,
        startAt,
        staleAfterSeconds,
        slowRead,
        samplesDir,
        reconnect
    } = parseArgs(argv);
    if (help) {
        console.log(USAGE);
        return;
    }
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
        inputLatency,
        windowMs,
        warmupSeconds,
        moveToRate,
        eventSeed,
        roomSlots,
        startAt,
        staleAfterSeconds,
        slowRead,
        samplesDir,
        reconnect
    });
    const metricsPath = systemMetricsPath ? path.resolve(process.cwd(), systemMetricsPath) : undefined;
    const systemMetrics = metricsPath && fs.existsSync(metricsPath) ? readSystemMetrics(metricsPath) : { system: [] };
    const profilePath = transportProfilePath ? path.resolve(process.cwd(), transportProfilePath) : undefined;
    // The server sync counters cover each phase's measured window, the span of the client
    // metrics; wait for the profile window that closes the last one to be flushed.
    const spans = measuredSpans(result.phases);
    const lastEnd = spans.reduce((max, span) => Math.max(max, span.endAt), 0);
    const profile = await readProfileAfter(profilePath, lastEnd);
    const report = buildReport(
        result,
        systemMetrics,
        serverSyncByPhase(profile, spans),
        serverCpuByPhase(systemMetrics, spans),
        serverSendByPhase(profile, spans)
    );
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
