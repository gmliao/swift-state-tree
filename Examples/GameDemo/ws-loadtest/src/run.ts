import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fork } from "node:child_process";
import type { PhaseName, Scenario, PhaseConfig } from "./types";
import { parseScenario } from "./scenario";
import { buildPhases } from "./orchestrator";

import type { CloseRecord, JoinFailure, PermessageDeflateCounts, SyncFrameGrouping } from "./worker";
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
import { effectiveEvents } from "./client-events";
import type { EventConfig } from "./client-events";
import { measureClientCpu, startCpuSampler, type CpuSample } from "./client-cpu";
import { summarizeLoopDelay, type ClientLoopDelay } from "./loop-delay";
import type { ClientCpu } from "./client-cpu";
import { timerAt } from "./timer-at";

/** The phase's measured window `[origin + warm-up, phase end)`: thresholds apply to these. */
export interface WorkerReport {
    rttMs: number[];
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    /** Frames no client could decode before leaving, in the measured window (#191). */
    decodeErrorCount: number;
    /** Server-initiated closes in the measured window. */
    disconnectCount: number;
    actionsSent: number;
}

export interface DecodeErrorBreakdown {
    beforeWindow: number;
    inWindow: number;
    afterWindow: number;
    /** After the client began to close: reported, never failed (SDK disconnect race, #190). */
    afterLeave: number;
}

/** Splits the phase's decode errors around the measured window `[from, to)`. */
export function decodeErrorBreakdown(reports: WorkerPhaseReport[], from: number, to: number): DecodeErrorBreakdown {
    const at = reports.flatMap((r) => r.decodeErrorAt ?? []);
    return {
        beforeWindow: at.filter((t) => t < from).length,
        inWindow: at.filter((t) => t >= from && t < to).length,
        afterWindow: at.filter((t) => t >= to).length,
        afterLeave: reports.reduce((sum, r) => sum + (r.decodeErrorsAfterLeave ?? 0), 0)
    };
}

/** Counts over the whole phase, transition included (the previous phase's surplus closes). */
export interface PhaseTotals {
    errorCount: number;
    /**
     * Frames no client could decode before it began to close, over the whole phase (ramp and
     * transition included). Any fails the phase (#191).
     */
    decodeErrorCount: number;
    /** Where those fell: before, inside and after the measured window. */
    decodeErrors?: DecodeErrorBreakdown;
    /** The first such error, if any. */
    firstDecodeError?: string;
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
    /**
     * When the counters were actually read (ms since epoch): `phaseStartAt` and `endAt` bound
     * `phase`, `measuredStartAt` and `endAt` bound `measured`. `measuredStartAt` is absent when
     * the warm-up covers the whole phase. The reads can lag the intended window edges slightly.
     */
    readAt: { phaseStartAt: number; measuredStartAt?: number; endAt: number };
}

/** How the phase's connections came about and ended. */
export interface PhaseConnections {
    /** Connections the phase is configured for (rooms × playersPerRoom). */
    target: number;
    /** New connections the ramp started before the phase ended (of `opened`). */
    started: number;
    /** Phase connections joined when the phase ended. */
    joinedAtEnd: number;
    /**
     * Joins that failed in this phase (rejected, answered with an error, or closed before
     * joining), over the whole phase and in the measured window. Not counted in `errorCount`.
     */
    joinFailures: { phase: number; measured: number; byReason: Record<string, number> };
    /** The first `CLOSE_RECORD_LIMIT` join failures, by time. */
    joinFailureRecords: JoinFailure[];
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
    /**
     * Connections opened in this phase, by whether permessage-deflate was negotiated. `ws`
     * offers it by default; when it is negotiated, update bytes are measured after inflation.
     */
    permessageDeflate?: PermessageDeflateCounts;
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
    /**
     * Client events sent in the measured window, by name: the target is the event's rate × the
     * average joined connections (as for actions).
     */
    events: Record<string, {
        ratePerPlayerPerSecond: number;
        targetPerSecond: number;
        sentInWindow: number;
        achievedPerSecond: number;
        perPlayerPerSecond: number;
    }>;
    /**
     * State updates received in the measured window: updates (syncs) per second and update size in
     * bytes. `syncFrameGrouping` covers the whole phase, not only the window.
     */
    stateUpdates: {
        inWindow: number;
        perSecond: number;
        perPlayerPerSecond: number;
        bytesMean: number;
        bytes: Distribution;
        syncFrameGrouping: SyncFrameGrouping;
    };
    /**
     * Joined, open connections. `average`: time-weighted over the measured window (connections
     * that joined or dropped mid-window count partly), reported only. `atEnd`: at the phase end.
     * `atMeasuredStart`: at origin + warm-up, when the warm-up is longer than the connect ramp
     * (the default); otherwise `null`, with the reason in `atMeasuredStartNote`.
     */
    joined: { average: number; atEnd: number; atMeasuredStart: number | null; atMeasuredStartNote?: string };
    /**
     * The load client's own CPU in the measured window (each worker's `process.cpuUsage()`), to
     * tell a busy load client apart from server latency in RTT.
     */
    clientCpu: ClientCpu;
    /** The workers' event-loop delay in the measured window. */
    clientLoopDelay: ClientLoopDelay;
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
    /** `--allow-join-failures`: join failures and a joined count below target don't fail a phase. */
    allowJoinFailures: boolean;
    /** `--allow-partial-ramp`: a joined count below target doesn't fail a phase (join failures still do). */
    allowPartialRamp: boolean;
    /** Client events every player sends (the scenario's, with `--move-to-rate` applied). */
    events: EventConfig[];
    /** Seed of the event payload generators (`--event-seed`, else the scenario's). */
    eventSeed: number;
    /** The load client's Node (`process.version`). */
    nodeVersion: string;
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
    /** permessage-deflate over every connection the run opened (see `PhaseConnections`). */
    permessageDeflate: PermessageDeflateCounts;
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
    /** Join failures and a joined count below target don't fail a phase. */
    allowJoinFailures?: boolean;
    /** Land id prefix; a new one per run by default. */
    runId?: string;
    sendMode?: SendMode;
    windowMs?: number;
    /** Warm-up for every phase, overriding the scenario's and the default. */
    warmupSeconds?: number;
    /** `MoveTo` events per player per second; 0 turns them off. Unset: the scenario's events. */
    moveToRate?: number;
    /** Seed of the event payload generators, overriding the scenario's. */
    eventSeed?: number;
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
    const events = effectiveEvents(scenario.events, opts.moveToRate);
    const eventSeed = opts.eventSeed ?? scenario.eventSeed;
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
        allowJoinFailures: opts.allowJoinFailures ?? false,
        allowPartialRamp: opts.allowPartialRamp ?? false,
        events,
        eventSeed,
        nodeVersion: process.version,
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
            const phaseStartReadAt = Date.now();
            await Promise.all(
                pool.map((worker, i) =>
                    worker.request<WorkerPrepared>(
                        {
                            type: "prepare",
                            config: {
                                serverUrl: scenario.serverUrl,
                                landType: scenario.landType,
                                phaseName: phase.name,
                                actions: scenario.actions,
                                events,
                                eventSeed,
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
            let measuredStartReadAt: number | undefined;
            const measureStartTimer = timerAt(measureFrom, () => {
                countersAtMeasureStart = readListenCounters();
                measuredStartReadAt = Date.now();
            });
            if (warmupsMs[p] >= durationMs) {
                measureStartTimer.cancel();
            }
            // The orchestrator's own CPU, from before the origin to after the last report.
            const stopOrchestratorCpu = startCpuSampler();
            const reports = await Promise.all(
                pool.map((worker) =>
                    worker.request<WorkerPhaseReport>({ type: "start", originAt, measureFrom }, "report", timeoutMs)
                )
            );
            const orchestratorCpu = stopOrchestratorCpu();
            measureStartTimer.cancel();
            const countersAtEnd = readListenCounters();
            const endReadAt = Date.now();
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
                    ...summarizeJoinFailures(reports, measureFrom, measureTo),
                    opened: reports.reduce((sum, r) => sum + r.connectionsOpened, 0),
                    reused: reports.reduce((sum, r) => sum + r.connectionsReused, 0),
                    closedAtStart: reports.reduce((sum, r) => sum + r.connectionsClosed, 0),
                    connectRampMs: reports.reduce((max, r) => Math.max(max, r.connectRampMs), 0),
                    transitionMs,
                    closes: summarizeCloses(closes),
                    permessageDeflate: sumDeflate(reports.map((r) => r.permessageDeflate))
                },
                listenQueue: {
                    scope: "host-or-netns",
                    phase: counterDelta(countersBefore, countersAtEnd),
                    measured: counterDelta(countersAtMeasureStart, countersAtEnd),
                    readAt: { phaseStartAt: phaseStartReadAt, measuredStartAt: measuredStartReadAt, endAt: endReadAt }
                },
                measurement: measurePhase(
                    reports,
                    originAt,
                    durationMs,
                    warmupsMs[p],
                    windowMs,
                    phase.config.actionsPerSecond,
                    rampsMs[p],
                    events,
                    orchestratorCpu
                ),
                report: aggregateReports(reports, measureFrom, measureTo),
                phaseTotals: {
                    errorCount: reports.reduce((sum, r) => sum + r.errorCount, 0),
                    decodeErrorCount: reports.reduce((sum, r) => sum + (r.decodeErrorAt?.length ?? 0), 0),
                    decodeErrors: decodeErrorBreakdown(reports, measureFrom, measureTo),
                    firstDecodeError: reports.find((r) => r.firstDecodeError !== undefined)?.firstDecodeError,
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
        permessageDeflate: sumDeflate(results.map((r) => r.connections.permessageDeflate)),
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
        decodeErrorCount: reports.reduce((sum, r) => sum + countInRange(r.decodeErrorAt ?? [], measureFrom, measureTo), 0),
        disconnectCount: reports.reduce(
            (sum, r) =>
                sum + countInRange(r.closes.filter((c) => c.initiator === "server").map((c) => c.t), measureFrom, measureTo),
            0
        ),
        actionsSent: reports.reduce((sum, r) => sum + countInRange(r.sentAt, measureFrom, measureTo), 0)
    };
}

function perSecond(count: number, from: number, to: number): number {
    return to > from ? count / ((to - from) / 1000) : 0;
}

function round2(value: number): number {
    return Math.round(value * 100) / 100;
}

/** Client events sent in `[from, to)`, by event name. */
export function measureEvents(
    reports: Array<Pick<WorkerPhaseReport, "eventSentAt">>,
    events: EventConfig[],
    from: number,
    to: number,
    averageActive: number
): PhaseMeasurement["events"] {
    const result: PhaseMeasurement["events"] = {};
    for (const event of events) {
        const sentInWindow = reports.reduce((sum, r) => sum + countInRange(r.eventSentAt?.[event.name] ?? [], from, to), 0);
        const achieved = perSecond(sentInWindow, from, to);
        result[event.name] = {
            ratePerPlayerPerSecond: event.ratePerSecond,
            targetPerSecond: round2(averageActive * event.ratePerSecond),
            sentInWindow,
            achievedPerSecond: round2(achieved),
            perPlayerPerSecond: averageActive > 0 ? round2(achieved / averageActive) : 0
        };
    }
    return result;
}

/**
 * State updates received in `[from, to)` (by `updateAt`, as the update intervals): rate and
 * payload size. A report whose sizes are not parallel to `updateAt` adds to the rate only.
 */
export function measureStateUpdates(
    reports: Array<Pick<WorkerPhaseReport, "updateAt" | "updateBytes"> & { syncFrameGrouping?: SyncFrameGrouping }>,
    from: number,
    to: number,
    averageActive: number
): PhaseMeasurement["stateUpdates"] {
    let inWindow = 0;
    const bytes: number[] = [];
    for (const r of reports) {
        const at = r.updateAt ?? [];
        const sizes = r.updateBytes ?? [];
        const sized = sizes.length === at.length;
        for (let i = 0; i < at.length; i += 1) {
            if (at[i] >= from && at[i] < to) {
                inWindow += 1;
                if (sized) bytes.push(sizes[i]);
            }
        }
    }
    const rate = perSecond(inWindow, from, to);
    return {
        inWindow,
        perSecond: round2(rate),
        perPlayerPerSecond: averageActive > 0 ? round2(rate / averageActive) : 0,
        bytesMean: bytes.length > 0 ? round2(bytes.reduce((sum, b) => sum + b, 0) / bytes.length) : 0,
        bytes: distribution(bytes),
        syncFrameGrouping: {
            grouped: reports.reduce((sum, r) => sum + (r.syncFrameGrouping?.grouped ?? 0), 0),
            ungroupedAfterBroadcast: reports.reduce((sum, r) => sum + (r.syncFrameGrouping?.ungroupedAfterBroadcast ?? 0), 0)
        }
    };
}

function sumDeflate(counts: Array<PermessageDeflateCounts | undefined>): PermessageDeflateCounts {
    return {
        negotiated: counts.reduce((sum, c) => sum + (c?.negotiated ?? 0), 0),
        notNegotiated: counts.reduce((sum, c) => sum + (c?.notNegotiated ?? 0), 0)
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

/** Join failures of a phase: counts over the phase and the measured window, by reason, records. */
export function summarizeJoinFailures(
    reports: Array<Pick<WorkerPhaseReport, "joinFailures">>,
    measureFrom: number,
    measureTo: number
): Pick<PhaseConnections, "joinFailures" | "joinFailureRecords"> {
    const all = reports.flatMap((r) => r.joinFailures ?? []).sort((a, b) => a.t - b.t);
    const byReason: Record<string, number> = {};
    for (const failure of all) {
        byReason[failure.reason] = (byReason[failure.reason] ?? 0) + 1;
    }
    return {
        joinFailures: {
            phase: all.length,
            measured: all.filter((f) => f.t >= measureFrom && f.t < measureTo).length,
            byReason
        },
        joinFailureRecords: all.slice(0, CLOSE_RECORD_LIMIT)
    };
}

/**
 * Connections joined and open at the measured-window start. Only meaningful when the warm-up is
 * longer than the connect ramp: a shorter one (e.g. `--warmup-seconds 0`, or a burst connect
 * with no warm-up) starts the window while connections are still joining.
 */
function joinedAtMeasuredStart(
    reports: Array<Pick<WorkerPhaseReport, "activeIntervals">>,
    measureFrom: number,
    measureTo: number,
    warmupMs: number,
    rampMs: number
): { atMeasuredStart: number | null; atMeasuredStartNote?: string } {
    if (measureTo <= measureFrom) {
        return { atMeasuredStart: null, atMeasuredStartNote: "n/a (no measured window)" };
    }
    if (warmupMs <= rampMs) {
        return { atMeasuredStart: null, atMeasuredStartNote: "n/a (warm-up <= ramp)" };
    }
    let count = 0;
    for (const r of reports) {
        for (const [from, to] of r.activeIntervals) {
            if (from <= measureFrom && to > measureFrom) count += 1;
        }
    }
    return { atMeasuredStart: count };
}

/** The phase's measurement window, send rate and per-window samples. */
export function measurePhase(
    reports: WorkerPhaseReport[],
    originAt: number,
    durationMs: number,
    warmupMs: number,
    windowMs: number,
    actionsPerSecond: number,
    rampMs: number = 0,
    events: EventConfig[] = [],
    orchestratorCpu: CpuSample[] = []
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
        windows: windowSamples(samples, originAt, durationMs, windowMs, warmupMs),
        events: measureEvents(reports, events, measureFrom, measureTo, averageActive),
        stateUpdates: measureStateUpdates(reports, measureFrom, measureTo, averageActive),
        joined: {
            average: Math.round(averageActive * 100) / 100,
            atEnd: reports.reduce((sum, r) => sum + r.joinedAtEnd, 0),
            ...joinedAtMeasuredStart(reports, measureFrom, measureTo, warmupMs, rampMs)
        },
        clientCpu: measureClientCpu(
            reports.map((r) => r.cpuSamples),
            measureFrom,
            measureTo,
            os.cpus().length,
            orchestratorCpu
        ),
        clientLoopDelay: summarizeLoopDelay(reports.map((r) => r.loopDelay))
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
