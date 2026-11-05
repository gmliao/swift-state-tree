import fs from "node:fs";
import path from "node:path";
import { fork } from "node:child_process";
import type { PhaseName, Scenario, PhaseConfig } from "./types";
import { parseScenario } from "./scenario";
import { buildPhases } from "./orchestrator";

import type { CloseRecord } from "./worker";
import type { WorkerPhaseReport, WorkerPrepared } from "./worker-runner";
import { RESPONSE_TIMEOUT_MS } from "./worker";
import { makeRunId, planPhaseConnections, summarizeLayout } from "./layout";
import type { ConnectionSpec, Layout, LayoutSummary } from "./layout";
import { DEFAULT_CONNECT_RATE, connectingWorkers, rampDurationMs } from "./connect-schedule";
import type { BoundaryMode, ConnectMode } from "./connect-schedule";
import { DEFAULT_WINDOW_MS, defaultWarmupMs } from "./send-schedule";
import type { SendMode } from "./send-schedule";
import { concatAll, countInRange, coveredMs, distribution, selectByTime, windowSamples } from "./samples";
import type { Distribution, WindowSample } from "./samples";
import { counterDelta, readListenCounters } from "./net-stats";
import type { ListenCounters } from "./net-stats";

/** The phase's measured window `[origin + warm-up, phase end)`: thresholds apply to these. */
export interface WorkerReport {
    rttMs: number[];
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    /** Server-initiated closes in the measured window. */
    disconnectCount: number;
    actionsSent: number;
}

/** Counts over the whole phase, transition included (the previous phase's surplus closes). */
export interface PhaseTotals {
    errorCount: number;
    disconnectCount: number;
    actionsSent: number;
}

/** Requests without a response. The RTT distributions leave these out; this is their count. */
export interface UnansweredRequests {
    /** Sent and still unanswered at the phase end (includes requests sent just before it). */
    pendingAtEnd: number;
    /** Of `pendingAtEnd`, unanswered for longer than `timeoutMs`. */
    timedOutAtEnd: number;
    /** Answered, but after more than `timeoutMs` (their RTT is in the distribution). */
    lateResponses: number;
}

/**
 * `ListenOverflows`/`ListenDrops` increase (Linux `/proc/net/netstat`; absent elsewhere). The
 * counters are host-wide, or network-namespace-wide in a container: they describe the server's
 * listen queue only when nothing else on the host accepts connections.
 */
export interface ListenQueueDeltas {
    scope: "host-or-netns";
    /** From the phase transition start to the phase end. */
    phase?: ListenCounters;
    /** The measured window only: read at origin + warm-up and at the phase end. */
    measured?: ListenCounters;
}

/** How the phase's connections came about and ended. */
export interface PhaseConnections {
    /** Connections the phase is configured for (rooms × playersPerRoom). */
    target: number;
    /** New connections the ramp started before the phase ended (of `opened`). */
    started: number;
    /** Phase connections joined when the phase ended. */
    joinedAtEnd: number;
    /** New connections planned for this phase. */
    opened: number;
    /** Kept open from the previous phase. */
    reused: number;
    /** Closed with a close frame at the start of this phase (the previous phase's surplus). */
    closedAtStart: number;
    /** Largest per-worker connect delay, ms after the phase origin. */
    connectRampMs: number;
    /**
     * Time from the start of the transition (closing the previous phase's surplus) until every
     * worker was ready, ms. The phase origin is taken after it.
     */
    transitionMs: number;
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

/** How the phase was measured: the steady-state window, the send rate and per-window samples. */
export interface PhaseMeasurement {
    /** Phase origin, ms since epoch: send schedules and windows count from it. */
    originAt: number;
    /** Samples before `originAt + warmupMs` are excluded from the phase's RTT and update metrics. */
    warmupMs: number;
    windowMs: number;
    /** Length of the measured window (phase duration minus warm-up). */
    measuredMs: number;
    excludedSamples: { rtt: number; update: number };
    /** Requests without a response, over the whole phase and for those sent in the measured window. */
    unanswered: { timeoutMs: number; phase: UnansweredRequests; measured: UnansweredRequests };
    sendRate: {
        /**
         * actionsPerSecond × the average number of joined, open connections over the measured
         * window (time-weighted, so connections that joined or dropped mid-window count partly).
         */
        targetPerSecond: number;
        /** Actions actually sent per second in the measured window. */
        achievedPerSecond: number;
        sentInWindow: number;
        /** Actual minus intended send time (0 in lockstep mode). */
        lagMs: Distribution;
        /** Sends more than one period late (a client-side stall). */
        lateSends: number;
    };
    windows: WindowSample[];
}

export interface PhaseResult {
    name: PhaseName;
    config: PhaseConfig;
    layout: LayoutSummary;
    connections: PhaseConnections;
    measurement: PhaseMeasurement;
    listenQueue: ListenQueueDeltas;
    /** The measured window only: RTT and update samples, errors, disconnects and sends. */
    report: WorkerReport;
    /** Whole-phase counts, including the warm-up and the transition. */
    phaseTotals: PhaseTotals;
}

/** The resolved run configuration, written into every report so a result describes itself. */
export interface RunConfig {
    /** Prefix of every land id in this run. */
    runId: string;
    layout: Layout;
    boundaryMode: BoundaryMode;
    sendMode: SendMode;
    windowMs: number;
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
        /** Time the connect ramp needs for this phase's new connections. */
        rampMs: number;
        /** Resolved warm-up excluded from the phase's metrics. */
        warmupMs: number;
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
    /** `ListenOverflows`/`ListenDrops` increase over the whole run (host- or netns-wide, see `ListenQueueDeltas`). */
    listenQueue: { scope: "host-or-netns"; run?: ListenCounters };
}

export interface RunOptions {
    workers: number;
    layout?: Layout;
    connectMode?: ConnectMode;
    connectRatePerSecond?: number;
    boundaryMode?: BoundaryMode;
    /** Run even when a phase's ramp is longer than the phase (a warning instead of an error). */
    allowPartialRamp?: boolean;
    /** Land id prefix; a new one per run by default. */
    runId?: string;
    sendMode?: SendMode;
    windowMs?: number;
    /** Warm-up for every phase, overriding the scenario's and the default. */
    warmupSeconds?: number;
    /** Where warnings go (default: stderr). */
    warn?: (message: string) => void;
}

/** New connections per worker in each phase: planned keys that the previous phase didn't hold. */
export function newConnectionsPerWorker(plans: ConnectionSpec[][][]): number[][] {
    return plans.map((plan, p) =>
        plan.map((specs, w) => {
            const previous = new Set((p > 0 ? plans[p - 1][w] : []).map((spec) => spec.key));
            return specs.filter((spec) => !previous.has(spec.key)).length;
        })
    );
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
    const boundaryMode = opts.boundaryMode ?? "clean";
    const runId = opts.runId ?? makeRunId();
    const sendMode = opts.sendMode ?? "spread";
    const windowMs = opts.windowMs ?? DEFAULT_WINDOW_MS;
    const warn = opts.warn ?? ((message: string) => console.warn(message));

    const scenario = loadScenario(filePath);
    const phases = buildPhases(scenario);
    const plans = phases.map((phase) => planPhaseConnections(phase.name, phase.config, workers, layout, runId));
    const newPerWorker = newConnectionsPerWorker(plans);
    const rampsMs = newPerWorker.map((perWorker) =>
        rampDurationMs(perWorker, connectMode, connectRatePerSecond)
    );
    const tooShort = phases
        .map((phase, i) => ({ phase, rampMs: rampsMs[i] }))
        .filter(({ phase, rampMs }) => rampMs > phase.config.durationSeconds * 1000);
    if (tooShort.length > 0) {
        const detail = tooShort
            .map(({ phase, rampMs }) => `${phase.name}: ramp ${(rampMs / 1000).toFixed(1)} s > phase ${phase.config.durationSeconds} s`)
            .join("; ");
        const message = `The connect ramp at ${connectRatePerSecond}/s is longer than the phase (${detail}), so the phase would run with fewer connections than configured. Raise --connect-rate, lengthen the phase, or pass --allow-partial-ramp.`;
        if (!opts.allowPartialRamp) {
            throw new Error(message);
        }
        warn(`warning: ${message}`);
    }
    const warmupsMs = phases.map((phase, i) => {
        const durationMs = phase.config.durationSeconds * 1000;
        const seconds = opts.warmupSeconds ?? phase.config.warmupSeconds;
        return seconds !== undefined ? Math.min(Math.max(0, seconds) * 1000, durationMs) : defaultWarmupMs(rampsMs[i], durationMs);
    });
    const runConfig: RunConfig = {
        runId,
        layout,
        boundaryMode,
        sendMode,
        windowMs,
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
                rampMs: Math.round(rampsMs[i]),
                warmupMs: Math.round(warmupsMs[i]),
                durationSeconds: phase.config.durationSeconds,
                actionsPerSecond: phase.config.actionsPerSecond
            };
        })
    };

    const runCountersBefore = readListenCounters();
    const pool = startWorkers(workers);
    const results: PhaseResult[] = [];
    let shutdownRecords: CloseRecord[] = [];
    try {
        for (let p = 0; p < phases.length; p += 1) {
            const phase = phases[p];
            const plan = plans[p];
            const activeWorkers = connectingWorkers(newPerWorker[p]);
            const durationMs = phase.config.durationSeconds * 1000;
            const timeoutMs = (phase.config.durationSeconds + 60) * 1000;

            // Step 1: every worker closes the previous phase's surplus and creates its clients.
            const transitionStart = Date.now();
            const countersBefore = readListenCounters();
            await Promise.all(
                pool.map((worker, i) =>
                    worker.request<WorkerPrepared>(
                        {
                            type: "prepare",
                            config: {
                                serverUrl: scenario.serverUrl,
                                landType: "hero-defense",
                                phaseName: phase.name,
                                actions: scenario.actions,
                                connections: plan[i],
                                connectMode,
                                connectRatePerSecond,
                                boundaryMode,
                                activeWorkers,
                                actionsPerSecond: phase.config.actionsPerSecond,
                                durationSeconds: phase.config.durationSeconds,
                                joinPayloadTemplate: phase.config.joinPayloadTemplate,
                                sendMode
                            }
                        },
                        "prepared",
                        60_000
                    )
                )
            );
            const transitionMs = Date.now() - transitionStart;

            // Step 2: one origin for all workers, taken after the transition; connects and sends
            // count from it. A short lead so every worker has the command before the origin.
            const originAt = Date.now() + 200;
            const measureFrom = originAt + warmupsMs[p];
            const measureTo = originAt + durationMs;
            let countersAtMeasureStart: ListenCounters | undefined;
            const measureStartTimer = setTimeout(() => {
                countersAtMeasureStart = readListenCounters();
            }, Math.max(0, measureFrom - Date.now()));
            if (warmupsMs[p] >= durationMs) {
                clearTimeout(measureStartTimer);
            }
            const reports = await Promise.all(
                pool.map((worker) => worker.request<WorkerPhaseReport>({ type: "start", originAt }, "report", timeoutMs))
            );
            clearTimeout(measureStartTimer);
            const countersAtEnd = readListenCounters();
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
                    target: phase.config.rooms * phase.config.playersPerRoom,
                    started: reports.reduce((sum, r) => sum + r.connectionsStarted, 0),
                    joinedAtEnd: reports.reduce((sum, r) => sum + r.joinedAtEnd, 0),
                    opened: reports.reduce((sum, r) => sum + r.connectionsOpened, 0),
                    reused: reports.reduce((sum, r) => sum + r.connectionsReused, 0),
                    closedAtStart: reports.reduce((sum, r) => sum + r.connectionsClosed, 0),
                    connectRampMs: reports.reduce((max, r) => Math.max(max, r.connectRampMs), 0),
                    transitionMs,
                    closes: summarizeCloses(closes)
                },
                listenQueue: {
                    scope: "host-or-netns",
                    phase: counterDelta(countersBefore, countersAtEnd),
                    measured: counterDelta(countersAtMeasureStart, countersAtEnd)
                },
                measurement: measurePhase(reports, originAt, durationMs, warmupsMs[p], windowMs, phase.config.actionsPerSecond),
                report: aggregateReports(reports, measureFrom, measureTo),
                phaseTotals: {
                    errorCount: reports.reduce((sum, r) => sum + r.errorCount, 0),
                    disconnectCount: reports.reduce((sum, r) => sum + r.disconnectCount, 0),
                    actionsSent: reports.reduce((sum, r) => sum + r.actionsSent, 0)
                }
            });
        }
        const shutdowns = await Promise.all(
            pool.map((worker) => worker.request<CloseRecord[]>({ type: "shutdown", boundaryMode }, "shutdownReport", 30_000, "closes"))
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
        shutdownCloses: summarizeCloses(shutdownRecords),
        listenQueue: { scope: "host-or-netns", run: counterDelta(runCountersBefore, readListenCounters()) }
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

/**
 * Merges the workers' phase reports into the measured window `[measureFrom, measureTo)`: RTT
 * and update samples by completion time, errors by when they arrived, server closes by close
 * time and actions by send time. Whole-phase counts are in `PhaseResult.phaseTotals`.
 */
export function aggregateReports(reports: WorkerPhaseReport[], measureFrom: number, measureTo: number): WorkerReport {
    return {
        rttMs: concatAll(reports.map((r) => selectByTime(r.rttMs, r.rttAt, measureFrom, measureTo))),
        stateUpdateIntervalsMs: concatAll(
            reports.map((r) => selectByTime(r.stateUpdateIntervalsMs, r.updateAt, measureFrom, measureTo))
        ),
        errorCount: reports.reduce((sum, r) => sum + countInRange(r.errorAt, measureFrom, measureTo), 0),
        disconnectCount: reports.reduce(
            (sum, r) =>
                sum + countInRange(r.closes.filter((c) => c.initiator === "server").map((c) => c.t), measureFrom, measureTo),
            0
        ),
        actionsSent: reports.reduce((sum, r) => sum + countInRange(r.sentAt, measureFrom, measureTo), 0)
    };
}

function unanswered(reports: WorkerPhaseReport[], endAt: number, from: number, to: number): UnansweredRequests {
    let pendingAtEnd = 0;
    let timedOutAtEnd = 0;
    let lateResponses = 0;
    for (const r of reports) {
        for (const origin of r.pendingAtEnd) {
            if (origin >= from && origin < to) {
                pendingAtEnd += 1;
                if (endAt - origin > RESPONSE_TIMEOUT_MS) timedOutAtEnd += 1;
            }
        }
        lateResponses += countInRange(r.lateResponseOrigins, from, to);
    }
    return { pendingAtEnd, timedOutAtEnd, lateResponses };
}

/** The phase's measurement window, send rate and per-window samples. */
export function measurePhase(
    reports: WorkerPhaseReport[],
    originAt: number,
    durationMs: number,
    warmupMs: number,
    windowMs: number,
    actionsPerSecond: number
): PhaseMeasurement {
    const measureFrom = originAt + warmupMs;
    const measureTo = originAt + durationMs;
    const measuredSeconds = Math.max(0, measureTo - measureFrom) / 1000;
    const samples = {
        rttMs: concatAll(reports.map((r) => r.rttMs)),
        rttAt: concatAll(reports.map((r) => r.rttAt)),
        stateUpdateIntervalsMs: concatAll(reports.map((r) => r.stateUpdateIntervalsMs)),
        updateAt: concatAll(reports.map((r) => r.updateAt)),
        sentAt: concatAll(reports.map((r) => r.sentAt))
    };
    const sendLagMs = concatAll(reports.map((r) => r.sendLagMs));
    const sentInWindow = samples.sentAt.filter((t) => t >= measureFrom && t < measureTo).length;
    const lagInWindow = selectByTime(sendLagMs, samples.sentAt, measureFrom, measureTo);
    const activeMs = reports.reduce((sum, r) => sum + coveredMs(r.activeIntervals, measureFrom, measureTo), 0);
    const averageActive = measureTo > measureFrom ? activeMs / (measureTo - measureFrom) : 0;
    const periodMs = actionsPerSecond > 0 ? 1000 / actionsPerSecond : 0;
    const excluded = {
        rtt: samples.rttMs.length - selectByTime(samples.rttMs, samples.rttAt, measureFrom, measureTo).length,
        update:
            samples.stateUpdateIntervalsMs.length -
            selectByTime(samples.stateUpdateIntervalsMs, samples.updateAt, measureFrom, measureTo).length
    };
    return {
        originAt,
        warmupMs,
        windowMs,
        measuredMs: Math.round(measuredSeconds * 1000),
        excludedSamples: excluded,
        unanswered: {
            timeoutMs: RESPONSE_TIMEOUT_MS,
            phase: unanswered(reports, measureTo, -Infinity, Infinity),
            measured: unanswered(reports, measureTo, measureFrom, measureTo)
        },
        sendRate: {
            targetPerSecond: Math.round(averageActive * actionsPerSecond * 10) / 10,
            achievedPerSecond: measuredSeconds > 0 ? sentInWindow / measuredSeconds : 0,
            sentInWindow,
            lagMs: distribution(lagInWindow),
            lateSends: periodMs > 0 ? lagInWindow.filter((lag) => lag > periodMs).length : 0
        },
        windows: windowSamples(samples, originAt, durationMs, windowMs, warmupMs)
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
