import fs from "node:fs";
import path from "node:path";
import { fork } from "node:child_process";
import type { PhaseName, Scenario, PhaseConfig } from "./types";
import { parseScenario } from "./scenario";
import { buildPhases } from "./orchestrator";

import type { CloseRecord } from "./worker";
import type { WorkerPhaseReport } from "./worker-runner";
import { planPhaseConnections, summarizeLayout } from "./layout";
import type { Layout, LayoutSummary } from "./layout";
import { DEFAULT_CONNECT_RATE } from "./connect-schedule";
import type { ConnectMode } from "./connect-schedule";

export interface WorkerReport {
    rttMs: number[];
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    disconnectCount: number;
    actionsSent: number;
}

/** How the phase's connections came about and ended. */
export interface PhaseConnections {
    opened: number;
    /** Kept open from the previous phase. */
    reused: number;
    /** Closed with a close frame at the start of this phase (the previous phase's surplus). */
    closedAtStart: number;
    /** Largest per-worker connect delay, ms after the phase start. */
    connectRampMs: number;
    closes: CloseSummary;
}

export interface CloseSummary {
    clientInitiated: number;
    serverInitiated: number;
    /** Client-initiated closes whose handshake timed out and were terminated. */
    forced: number;
    byCode: Record<string, number>;
    /** The first `CLOSE_RECORD_LIMIT` close records, by time. */
    records: CloseRecord[];
}

export interface PhaseResult {
    name: PhaseName;
    config: PhaseConfig;
    layout: LayoutSummary;
    connections: PhaseConnections;
    report: WorkerReport;
}

/** The resolved run configuration, written into every report so a result describes itself. */
export interface RunConfig {
    layout: Layout;
    connectMode: ConnectMode;
    /** Total new connections per second over all workers (ramp mode). */
    connectRatePerSecond: number;
    workers: number;
    phases: Array<{
        name: PhaseName;
        rooms: number;
        playersPerRoom: number;
        connections: number;
        lands: number;
        durationSeconds: number;
        actionsPerSecond: number;
    }>;
}

export interface RunResult {
    scenarioName: string;
    /** Server StateSync interval in ms (e.g. 100). Used in report for client-jitter hint. */
    syncIntervalMs?: number;
    runConfig: RunConfig;
    phases: PhaseResult[];
    /** Closes at the end of the run (all client-initiated unless the server closed first). */
    shutdownCloses: CloseSummary;
}

export interface RunOptions {
    workers: number;
    layout?: Layout;
    connectMode?: ConnectMode;
    connectRatePerSecond?: number;
}

export const CLOSE_RECORD_LIMIT = 200;

export function loadScenario(filePath: string): Scenario {
    const raw = fs.readFileSync(filePath, "utf-8");
    const json = JSON.parse(raw);
    return parseScenario(json);
}

export function summarizeCloses(records: CloseRecord[]): CloseSummary {
    const byCode: Record<string, number> = {};
    let clientInitiated = 0;
    let serverInitiated = 0;
    let forced = 0;
    for (const record of records) {
        if (record.initiator === "client") {
            clientInitiated += 1;
        } else {
            serverInitiated += 1;
        }
        if (record.forced) {
            forced += 1;
        }
        const code = record.code === undefined ? "none" : String(record.code);
        byCode[code] = (byCode[code] ?? 0) + 1;
    }
    const sorted = [...records].sort((a, b) => a.t - b.t).slice(0, CLOSE_RECORD_LIMIT);
    return { clientInitiated, serverInitiated, forced, byCode, records: sorted };
}

/**
 * Runs the scenario's phases on one set of long-lived workers. Connections whose key is in the
 * next phase stay open; the others are closed with a close frame before that phase opens new
 * ones, and every connection is closed cleanly at the end.
 */
export async function runScenario(filePath: string, options: RunOptions | number): Promise<RunResult> {
    const opts: RunOptions = typeof options === "number" ? { workers: options } : options;
    const workers = Math.max(1, Math.floor(opts.workers));
    const layout = opts.layout ?? "rooms";
    const connectMode = opts.connectMode ?? "ramp";
    const connectRatePerSecond = opts.connectRatePerSecond ?? DEFAULT_CONNECT_RATE;

    const scenario = loadScenario(filePath);
    const phases = buildPhases(scenario);
    const plans = phases.map((phase) => planPhaseConnections(phase.name, phase.config, workers, layout));
    const runConfig: RunConfig = {
        layout,
        connectMode,
        connectRatePerSecond,
        workers,
        phases: phases.map((phase, i) => {
            const summary = summarizeLayout(plans[i], layout);
            return {
                name: phase.name,
                rooms: phase.config.rooms,
                playersPerRoom: phase.config.playersPerRoom,
                connections: summary.connections,
                lands: summary.lands,
                durationSeconds: phase.config.durationSeconds,
                actionsPerSecond: phase.config.actionsPerSecond
            };
        })
    };

    const pool = startWorkers(workers);
    const results: PhaseResult[] = [];
    let shutdownRecords: CloseRecord[] = [];
    try {
        for (let p = 0; p < phases.length; p += 1) {
            const phase = phases[p];
            const plan = plans[p];
            const activeWorkers = plan.filter((specs) => specs.length > 0).length;
            const timeoutMs = (phase.config.durationSeconds + 60) * 1000;
            const reports = await Promise.all(
                pool.map((worker, i) =>
                    worker.request<WorkerPhaseReport>(
                        {
                            type: "phase",
                            config: {
                                serverUrl: scenario.serverUrl,
                                landType: "hero-defense",
                                phaseName: phase.name,
                                actions: scenario.actions,
                                connections: plan[i],
                                connectMode,
                                connectRatePerSecond,
                                activeWorkers,
                                actionsPerSecond: phase.config.actionsPerSecond,
                                durationSeconds: phase.config.durationSeconds,
                                joinPayloadTemplate: phase.config.joinPayloadTemplate
                            }
                        },
                        "report",
                        timeoutMs
                    )
                )
            );
            const closes: CloseRecord[] = [];
            for (const r of reports) {
                for (const record of r.closes) {
                    closes.push(record);
                }
            }
            results.push({
                name: phase.name,
                config: phase.config,
                layout: summarizeLayout(plan, layout),
                connections: {
                    opened: reports.reduce((sum, r) => sum + r.connectionsOpened, 0),
                    reused: reports.reduce((sum, r) => sum + r.connectionsReused, 0),
                    closedAtStart: reports.reduce((sum, r) => sum + r.connectionsClosed, 0),
                    connectRampMs: reports.reduce((max, r) => Math.max(max, r.connectRampMs), 0),
                    closes: summarizeCloses(closes)
                },
                report: aggregateReports(reports)
            });
        }
        const shutdowns = await Promise.all(
            pool.map((worker) => worker.request<CloseRecord[]>({ type: "shutdown" }, "shutdownReport", 30_000, "closes"))
        );
        shutdownRecords = shutdowns.flat();
        await Promise.all(pool.map((worker) => worker.exited(10_000)));
    } finally {
        pool.forEach((worker) => worker.kill());
    }

    return {
        scenarioName: scenario.name,
        syncIntervalMs: scenario.syncIntervalMs,
        runConfig,
        phases: results,
        shutdownCloses: summarizeCloses(shutdownRecords)
    };
}

interface WorkerHandle {
    request<T>(message: unknown, replyType: string, timeoutMs: number, field?: string): Promise<T>;
    exited(timeoutMs: number): Promise<void>;
    kill(): void;
}

function startWorkers(count: number): WorkerHandle[] {
    const workerScript = resolveWorkerScript();
    const handles: WorkerHandle[] = [];
    for (let i = 0; i < count; i += 1) {
        const child = fork(workerScript.scriptPath, [], {
            execArgv: workerScript.execArgv,
            stdio: ["inherit", "inherit", "inherit", "ipc"]
        });
        let exited = false;
        const exitPromise = new Promise<void>((resolve) => child.on("exit", () => {
            exited = true;
            resolve();
        }));
        handles.push({
            request<T>(message: unknown, replyType: string, timeoutMs: number, field = "report"): Promise<T> {
                return new Promise<T>((resolve, reject) => {
                    const timeout = setTimeout(() => {
                        cleanup();
                        child.kill("SIGKILL");
                        reject(new Error(`Worker ${child.pid} timeout waiting for ${replyType}`));
                    }, timeoutMs);
                    const onMessage = (reply: any) => {
                        if (reply?.type === replyType) {
                            cleanup();
                            resolve(reply[field] as T);
                        } else if (reply?.type === "error") {
                            cleanup();
                            reject(new Error(`Worker ${child.pid}: ${reply.error}`));
                        }
                    };
                    const onExit = () => {
                        cleanup();
                        reject(new Error(`Worker ${child.pid} exited before ${replyType}`));
                    };
                    const cleanup = () => {
                        clearTimeout(timeout);
                        child.off("message", onMessage);
                        child.off("exit", onExit);
                    };
                    child.on("message", onMessage);
                    child.on("exit", onExit);
                    child.send(message as any);
                });
            },
            exited(timeoutMs: number): Promise<void> {
                return Promise.race([
                    exitPromise,
                    new Promise<void>((resolve) => setTimeout(resolve, timeoutMs).unref())
                ]);
            },
            kill(): void {
                if (!exited) {
                    child.kill();
                }
            }
        });
    }
    return handles;
}

function aggregateReports(reports: WorkerPhaseReport[]): WorkerReport {
    // IMPORTANT:
    // Do NOT use `array.push(...bigArray)` here.
    // With large loads, each worker can produce very large sample arrays; spreading them
    // can overflow the JS call stack / argument limit ("Maximum call stack size exceeded").
    let totalRtt = 0;
    let totalUpd = 0;
    let errorCount = 0;
    let disconnectCount = 0;
    let actionsSent = 0;

    for (const r of reports) {
        totalRtt += r.rttMs.length;
        totalUpd += r.stateUpdateIntervalsMs.length;
        errorCount += r.errorCount;
        disconnectCount += r.disconnectCount;
        actionsSent += r.actionsSent;
    }

    const rttMs: number[] = new Array(totalRtt);
    const stateUpdateIntervalsMs: number[] = new Array(totalUpd);
    let rttIndex = 0;
    let updIndex = 0;

    for (const r of reports) {
        for (let i = 0; i < r.rttMs.length; i += 1) {
            rttMs[rttIndex++] = r.rttMs[i];
        }
        for (let i = 0; i < r.stateUpdateIntervalsMs.length; i += 1) {
            stateUpdateIntervalsMs[updIndex++] = r.stateUpdateIntervalsMs[i];
        }
    }

    return {
        rttMs,
        stateUpdateIntervalsMs,
        errorCount,
        disconnectCount,
        actionsSent
    };
}

function resolveWorkerScript(): { scriptPath: string; execArgv: string[] } {
    const jsPath = path.join(__dirname, "worker-runner.js");
    if (fs.existsSync(jsPath)) {
        return { scriptPath: jsPath, execArgv: [] };
    }

    const tsPath = path.join(__dirname, "worker-runner.ts");
    // tsx 4 exports its CommonJS hook as "tsx/cjs" ("tsx/register" was removed).
    const register = require.resolve("tsx/cjs");
    return { scriptPath: tsPath, execArgv: ["-r", register] };
}
