import { WorkerClient, WorkerSession, isDisconnect, selectAction, type PermessageDeflateCounts } from "./worker";
import type { CloseRecord, JoinFailure, ReconnectOption, ReconnectRecord, SlowReadWindow, SyncFrameGrouping } from "./worker";
import type { InputLatencyMetrics } from "./input-latency";
import type { ConvergenceConnection } from "./worker";
import { loadSdkCore } from "./reconstruction";
import { sendMessageWithAck } from "./ipc";
import { SampleSink } from "./samples-sink";
import { renderTemplateObject } from "./payload";
import { connectDelaysMs } from "./connect-schedule";
import type { BoundaryMode, ConnectMode } from "./connect-schedule";
import { SendSchedule, sendOffsetMs } from "./send-schedule";
import { eventRandom, loadFixedPointTypes, payloadGenerators } from "./client-events";
import type { EventConfig, FixedPointTypes, PayloadGenerator, Random } from "./client-events";
import type { SendMode } from "./send-schedule";
import type { ConnectionSpec } from "./layout";
import type { ActionConfig } from "./types";
import { concatAll } from "./samples";
import { CPU_SAMPLE_INTERVAL_MS, startCpuSampler, type CpuSample } from "./client-cpu";
import { LoopUtilizationSpans } from "./loop-utilization";
import { untilWallClock } from "./timer-at";
import { startLoopDelayMonitor, type LoopDelay } from "./loop-delay";
import { sumActionOutcomes, type ActionOutcomeCounts } from "./action-outcomes";

/** One phase for this worker. The worker lives for the whole run and keeps its connections. */
export interface PhaseStartConfig {
    serverUrl: string;
    landType: string;
    phaseName: string;
    actions: ActionConfig[];
    /** Client events each player sends, each on its own spread schedule. */
    events: EventConfig[];
    eventSeed: number;
    /** The connections to hold in this phase; kept ones are reused, the rest are opened. */
    connections: ConnectionSpec[];
    connectMode: ConnectMode;
    connectRatePerSecond: number;
    boundaryMode: BoundaryMode;
    /** Workers opening new connections in this phase (`connectingWorkers`); they share the ramp rate. */
    activeWorkers: number;
    actionsPerSecond: number;
    durationSeconds: number;
    joinPayloadTemplate?: Record<string, unknown>;
    sendMode: SendMode;
    /** Time move events until visible (`WorkerOptions.trackInputLatency`); absent means false. */
    inputLatency?: boolean;
    /** `--stale-after` in ms (`WorkerOptions.staleAfterMs`); absent: no stale check. */
    staleAfterMs?: number;
    /** `--slow-read` as absolute times (`WorkerOptions.slowRead`); absent: always read. */
    slowRead?: SlowReadWindow;
    /** `--samples-dir`: this worker's raw samples file (`samples-sink.ts`); absent: none. */
    samplesFile?: string;
    /** `--reconnect on-server-close` (`WorkerOptions.reconnect`); absent: no reconnects. */
    reconnect?: ReconnectOption;
    /** `--reconstruct`: the server's schema (`/schema`) for each connection's state view. */
    reconstructSchema?: unknown;
}


export interface WorkerPhaseReport {
    rttMs: number[];
    rttAt: number[];
    stateUpdateIntervalsMs: number[];
    updateAt: number[];
    sendLagMs: number[];
    sentAt: number[];
    errorCount: number;
    /** Answered actions by outcome (`WorkerMetrics.actionOutcomes`); optional in older reports. */
    actionOutcomes?: ActionOutcomeCounts;
    /** `WorkerMetrics.appliedRttMs`; optional in older reports. */
    appliedRttMs?: number[];
    /** Frames no client could decode before leaving, by arrival time (`WorkerMetrics.decodeErrorAt`). */
    decodeErrorAt: number[];
    /** Decode errors after a client began to close (`WorkerMetrics.decodeErrorsAfterLeave`). */
    decodeErrorsAfterLeave: number;
    /** The first such error in this worker, if any. */
    firstDecodeError?: string;
    disconnectCount: number;
    actionsSent: number;
    /** Send time of each client event, by event name. */
    eventSentAt: Record<string, number[]>;
    /** Payload size of each state update, parallel to `updateAt` per connection (`WorkerMetrics`). */
    updateBytes: number[];
    /** Connections opened in this phase, by whether permessage-deflate was negotiated. */
    permessageDeflate: PermessageDeflateCounts;
    /** Plain state frames after a 107 frame, grouped into its sync or not (`SyncFrameGrouping`). */
    syncFrameGrouping: SyncFrameGrouping;
    /** Move events' input-to-visible samples, concatenated over connections (`InputLatencyMetrics`). */
    inputLatency: InputLatencyMetrics;
    /** This worker process's CPU time through the phase (`client-cpu`). */
    cpuSamples: CpuSample[];
    /** This worker's event-loop delay in the measured window (`loop-delay`); null without a window. */
    loopDelay: LoopDelay | null;
    /** Every close seen during the phase, including the ones closing the previous phase's surplus. */
    closes: CloseRecord[];
    /** Reconnects that ended in this phase (`--reconnect`). */
    reconnects: ReconnectRecord[];
    /** New connections planned for this phase. */
    connectionsOpened: number;
    /** New connections the ramp actually started before the phase ended. */
    connectionsStarted: number;
    /** Phase connections joined when the phase ended. */
    joinedAtEnd: number;
    connectionsReused: number;
    connectionsClosed: number;
    /** Delay of the last new connection, ms after the phase origin. */
    connectRampMs: number;
    /** When each error was counted, parallel to the error increments. */
    errorAt: number[];
    /** RTT origins of requests still unanswered at the phase end (forgotten afterwards). */
    pendingAtEnd: number[];
    /** RTT origins of responses that took longer than `RESPONSE_TIMEOUT_MS` (worker.ts). */
    lateResponseOrigins: number[];
    /** Per phase connection, `[from, to)` while it was joined and open, clipped to the phase. */
    activeIntervals: Array<[number, number]>;
    /** Joins of this phase's connections that failed, reported in the phase they happened in. */
    joinFailures: JoinFailure[];
    /** Socket open to JoinResponse, ms, of each connection that joined in this phase. */
    joinLatenciesMs: number[];
    /**
     * Joins in this phase by the state-update features their JoinResponse named
     * (`joinFeaturesKey`: e.g. "fieldMerge,pathIndex", or "none"); optional in older reports.
     */
    joinFeatures?: Record<string, number>;
}

/** Reply to `prepare`: the previous phase's surplus is closed and this phase's clients exist. */
export interface WorkerPrepared {
    surplusClosed: number;
}

/**
 * A phase runs in two steps so that no worker's origin is taken before every worker finished the
 * transition: `prepare` closes the previous phase's surplus and creates the new clients, and
 * `start` (sent after every worker answered `prepare`) opens connections and sends from the
 * common origin.
 */
type InboundMessage =
    | { type: "control"; id: number; command: ControlCommand }
    | { type: "prepare"; config: PhaseStartConfig }
    | { type: "start"; originAt: number; measureFrom: number }
    | { type: "shutdown"; boundaryMode: BoundaryMode };

interface PreparedPhase {
    config: PhaseStartConfig;
    phaseClients: WorkerClient[];
    newClients: WorkerClient[];
    reused: number;
    surplus: number;
    transitionCloses: CloseRecord[];
}

let prepared: PreparedPhase | undefined;

/**
 * A convergence control command (`control.ts`), answered at once, outside the command queue,
 * since a phase is running: `stopSending` ends the running phase's action and event sends (the
 * connections stay open); `lands` reports each land's connections (only the lands named in
 * `only`, when given), with their normalised states for the lands in `withStates`.
 */
export type ControlCommand = { name: "stopSending" } | { name: "lands"; only?: string[]; withStates?: string[] };

export interface ControlReply {
    stopped?: boolean;
    connections?: ConvergenceConnection[];
}

/** The running phase's send stops, called by `stopSending` (and again, harmlessly, at its end). */
let runningSendStops: Array<() => void> = [];
let sendingStopped = false;

function control(command: ControlCommand): ControlReply {
    if (command.name === "stopSending") {
        sendingStopped = true;
        runningSendStops.forEach((stop) => stop());
        return { stopped: true };
    }
    const withStates = new Set(command.withStates ?? []);
    const only = command.only && command.only.length > 0 ? new Set(command.only) : undefined;
    return {
        connections: [...clients.values()]
            .filter((client) => !only || only.has(client.getLandInstanceId()))
            .map((client) => client.convergenceReport(withStates.has(client.getLandInstanceId())))
    };
}

const clients = new Map<string, WorkerClient>();
let actionCounter = 0;
let queue: Promise<void> = Promise.resolve();

process.on("message", (message: InboundMessage) => {
    if (message?.type === "control") {
        let reply: unknown;
        try {
            reply = { type: "controlReply", id: message.id, result: control(message.command) };
        } catch (error) {
            reply = { type: "controlReply", id: message.id, error: String(error) };
        }
        process.send?.(reply);
        return;
    }
    // Commands run one after another: a shutdown waits for the running phase.
    queue = queue
        .then(() => handle(message))
        .catch((error) => {
            process.send?.({ type: "error", error: String(error) });
        });
});

/** How often every client's stale check runs: the detection lags `--stale-after` by at most this. */
const STALE_CHECK_INTERVAL_MS = 250;
let staleTimer: ReturnType<typeof setInterval> | undefined;
/** Opened by the first phase that names a samples file, closed (flushed) at shutdown. */
let samplesSink: SampleSink | undefined;

/** One interval per worker, not a timer per connection reset on every frame. */
function startStaleChecks(): void {
    if (staleTimer) {
        return;
    }
    staleTimer = setInterval(() => {
        const now = Date.now();
        for (const client of clients.values()) {
            client.checkStale(now);
        }
    }, STALE_CHECK_INTERVAL_MS);
    staleTimer.unref?.();
}

async function handle(message: InboundMessage): Promise<void> {
    if (message?.type === "prepare") {
        if (message.config.staleAfterMs !== undefined) {
            startStaleChecks();
        }
        if (message.config.samplesFile !== undefined && !samplesSink) {
            samplesSink = new SampleSink(message.config.samplesFile);
        }
        prepared = await preparePhase(message.config);
        const reply: WorkerPrepared = { surplusClosed: prepared.surplus };
        await send({ type: "prepared", report: reply });
    } else if (message?.type === "start") {
        if (!prepared) {
            throw new Error("start without prepare");
        }
        const phase = prepared;
        prepared = undefined;
        const report = await runPhase(phase, message.originAt, message.measureFrom);
        await send({ type: "report", report });
    } else if (message?.type === "shutdown") {
        const closes = await closeClients([...clients.values()], "shutdown", message.boundaryMode);
        clients.clear();
        // Pending requests of the last phase were written at its end; the closes just now.
        await samplesSink?.close();
        await send({ type: "shutdownReport", closes });
        process.exit(0);
    }
}

function send(message: unknown): Promise<void> {
    if (!process.send) {
        process.exit(1);
    }
    return sendMessageWithAck(
        (msg, callback) => process.send!(msg, undefined, undefined, callback),
        message
    );
}

/**
 * Closes `toClose` (close frames and handshakes, or dropped sockets with `abrupt`) and returns
 * their close records, including any server close they saw since the last report.
 */
async function closeClients(toClose: WorkerClient[], reason: string, mode: BoundaryMode): Promise<CloseRecord[]> {
    await Promise.all(toClose.map((client) => (mode === "abrupt" ? client.drop(reason) : client.close(reason))));
    const records: CloseRecord[] = [];
    for (const client of toClose) {
        records.push(...client.getSession().metrics.closes);
    }
    return records;
}

async function preparePhase(config: PhaseStartConfig): Promise<PreparedPhase> {
    // Load the event generators (the SDK) now, so the phase start doesn't wait for it.
    await loadGenerators(config.events);
    const reconstruction =
        config.reconstructSchema !== undefined ? { sdk: await loadSdkCore(), schema: config.reconstructSchema } : undefined;
    const wanted = new Set(config.connections.map((spec) => spec.key));

    // Close what this phase doesn't use (and anything already closed) before opening new ones.
    const surplus = [...clients.values()].filter((client) => !wanted.has(client.getKey()) || !client.isUsable());
    for (const client of surplus) {
        clients.delete(client.getKey());
    }
    const transitionCloses = await closeClients(surplus, "phase change", config.boundaryMode);

    const phaseClients: WorkerClient[] = [];
    const newClients: WorkerClient[] = [];
    let reused = 0;
    for (const spec of config.connections) {
        const existing = clients.get(spec.key);
        if (existing) {
            phaseClients.push(existing);
            reused += 1;
            continue;
        }
        const joinMetadata = config.joinPayloadTemplate
            ? renderTemplateObject(config.joinPayloadTemplate, { playerId: spec.playerId })
            : undefined;
        const client = new WorkerClient({
            key: spec.key,
            serverUrl: config.serverUrl,
            landType: config.landType,
            landInstanceId: spec.landInstanceId,
            playerId: spec.playerId,
            actions: config.actions,
            joinMetadata
        }, {
            trackInputLatency: config.inputLatency ?? false,
            staleAfterMs: config.staleAfterMs,
            slowRead: config.slowRead,
            samples: samplesSink?.write,
            reconnect: config.reconnect,
            reconstruction
        });
        clients.set(spec.key, client);
        phaseClients.push(client);
        newClients.push(client);
    }
    return { config, phaseClients, newClients, reused, surplus: surplus.length, transitionCloses };
}

async function runPhase(phase: PreparedPhase, originAt: number, measureFrom: number): Promise<WorkerPhaseReport> {
    const { config, phaseClients, newClients, reused, transitionCloses } = phase;
    samplesSink?.write({ r: "phase", name: config.phaseName, originAt, endAt: originAt + config.durationSeconds * 1000 });
    // Started before the origin and stopped after the phase end, so it covers the measured window.
    // The loop-utilization spans ride on its tick (no timer of their own), only with samples.
    const sink = samplesSink;
    const loopSpans = sink ? new LoopUtilizationSpans((span) => sink.write({ r: "loop", ...span })) : undefined;
    loopSpans?.start(Date.now());
    const stopCpuSampler = startCpuSampler(CPU_SAMPLE_INTERVAL_MS, Date.now, undefined, loopSpans && ((t) => loopSpans.tick(t)));
    // The measured window only: from its start to the phase end.
    const stopLoopDelay = startLoopDelayMonitor(measureFrom);
    // Connect delays count from the origin, like the send schedules.
    const delays = connectDelaysMs(
        newClients.map((client) => client.getKey()),
        config.connectMode,
        config.connectRatePerSecond,
        config.activeWorkers
    );
    const connectTimers: NodeJS.Timeout[] = [];
    newClients.forEach((client, i) => {
        connectTimers.push(setTimeout(() => client.connect(), Math.max(0, originAt + delays[i] - Date.now())));
    });

    const endAt = originAt + config.durationSeconds * 1000;
    // A phase after `stopSending` sends nothing either.
    const sends = config.actionsPerSecond > 0 && !sendingStopped;
    const stopSending = sends ? startSending(config, phaseClients, originAt, endAt) : () => {};
    const generators = await loadGenerators(config.events);
    const stopEvents = sendingStopped
        ? []
        : config.events.map((event) => startEventSending(config, event, generators, phaseClients, originAt, endAt));
    runningSendStops = [stopSending, ...stopEvents];

    // Not before the phase end: an early timer would end the phase (and its CPU samples) before
    // the measured window does.
    await untilWallClock(endAt);
    const cpuSamples = stopCpuSampler();
    loopSpans?.stop(Date.now());
    const loopDelay = stopLoopDelay();
    stopSending();
    stopEvents.forEach((stop) => stop());
    runningSendStops = [];
    connectTimers.forEach((t) => clearTimeout(t));
    phaseClients.forEach((client) => client.clearJoinedCallbacks());
    phaseClients.forEach((client) => client.noteJoinUnansweredAtPhaseEnd());

    const report = aggregateSessions(phaseClients.map((client) => client.getSession()));
    const pendingAtEnd = concatAll(phaseClients.map((client) => client.getSession().takePending()));
    const activeIntervals: Array<[number, number]> = [];
    for (const client of phaseClients) {
        activeIntervals.push(...client.activeIntervals(originAt, endAt));
    }
    // What was reported belongs to this phase; anything after it (closes at the next
    // transition) goes to the next report. Unanswered requests were taken above, so a late
    // response is not counted in the next phase.
    phaseClients.forEach((client) => client.getSession().resetMetrics());
    return {
        ...report,
        // A server close on a surplus connection between phases is still a disconnect.
        disconnectCount: report.disconnectCount + transitionCloses.filter(isDisconnect).length,
        closes: [...transitionCloses, ...report.closes],
        connectionsOpened: newClients.length,
        connectionsStarted: newClients.filter((client) => client.isStarted()).length,
        joinedAtEnd: phaseClients.filter((client) => client.isJoined() && client.isUsable()).length,
        connectionsReused: reused,
        connectionsClosed: phase.surplus,
        connectRampMs: delays.length > 0 ? Math.round(delays[delays.length - 1]) : 0,
        pendingAtEnd,
        activeIntervals,
        cpuSamples,
        loopDelay,
        joinLatenciesMs: phaseClients.flatMap((client) => {
            const latency = client.takeJoinLatency();
            return latency === undefined ? [] : [latency];
        }),
        joinFailures: phaseClients.flatMap((client) => {
            const failure = client.takeJoinFailure();
            return failure ? [failure] : [];
        }),
        joinFeatures: phaseClients.reduce<Record<string, number>>((counts, client) => {
            const key = client.takeJoinFeatures();
            if (key !== undefined) counts[key] = (counts[key] ?? 0) + 1;
            return counts;
        }, {})
    };
}

function sendOne(config: PhaseStartConfig, client: WorkerClient, intendedAt?: number): void {
    const action = selectAction(config.actions, actionCounter++);
    const payload = renderTemplateObject(action.payloadTemplate ?? {}, {
        playerId: client.getPlayerId()
    });
    client.sendAction(`action-${process.pid}-${actionCounter}`, action.name, payload, intendedAt);
}

function mergeEventSentAt(all: Array<Record<string, number[]>>): Record<string, number[]> {
    const merged: Record<string, number[]> = {};
    for (const byName of all) {
        for (const [name, times] of Object.entries(byName)) {
            (merged[name] ??= []).push(...times);
        }
    }
    return merged;
}

let fixedPointTypes: Promise<FixedPointTypes> | undefined;

/** The payload generators the events name; the SDK is loaded once, and only if one is named. */
async function loadGenerators(events: EventConfig[]): Promise<Record<string, PayloadGenerator>> {
    if (!events.some((event) => event.payloadGenerator !== undefined)) {
        return {};
    }
    fixedPointTypes ??= loadFixedPointTypes();
    const generators = payloadGenerators(await fixedPointTypes);
    for (const event of events) {
        if (event.payloadGenerator !== undefined && !(event.payloadGenerator in generators)) {
            throw new Error(`Unknown payloadGenerator ${event.payloadGenerator} for event ${event.name}`);
        }
    }
    return generators;
}

/** One PRNG per connection and event, kept across phases for a reused connection. */
const eventRandoms = new Map<string, Random>();

/**
 * Starts one event's sends: each client on its own spread schedule (offset keyed by event name
 * and connection), like actions in `spread` mode. Events get no response, so a late timer just
 * sends the slots it missed. Returns a function that stops them.
 */
function startEventSending(
    config: PhaseStartConfig,
    event: EventConfig,
    generators: Record<string, PayloadGenerator>,
    phaseClients: WorkerClient[],
    originAt: number,
    endAt: number
): () => void {
    const periodMs = 1000 / event.ratePerSecond;
    const generate = event.payloadGenerator !== undefined ? generators[event.payloadGenerator] : undefined;
    let stopped = false;
    const timers = new Set<NodeJS.Timeout>();
    for (const client of phaseClients) {
        const key = client.getKey();
        const randomKey = `${event.name}:${key}`;
        if (!eventRandoms.has(randomKey)) {
            eventRandoms.set(randomKey, eventRandom(config.eventSeed, event.name, key));
        }
        const random = eventRandoms.get(randomKey)!;
        const schedule = new SendSchedule(originAt, periodMs, sendOffsetMs(`${event.name}:${key}`, periodMs));
        const arm = () => {
            if (stopped || schedule.nextDueMs() >= endAt) {
                return;
            }
            const timer = setTimeout(() => {
                timers.delete(timer);
                if (stopped) {
                    return;
                }
                if (client.isUsable()) {
                    for (const _ of schedule.takeDue(Date.now(), endAt)) {
                        client.sendEvent(event.name, generate ? generate(random) : {});
                    }
                    arm();
                }
            }, Math.max(0, schedule.nextDueMs() - Date.now()));
            timers.add(timer);
        };
        client.onJoined((joinedAt) => {
            schedule.startAt(Math.max(joinedAt, originAt));
            arm();
        });
    }
    return () => {
        stopped = true;
        timers.forEach((timer) => clearTimeout(timer));
        timers.clear();
    };
}

/** Starts the phase's sends; returns a function that stops them. */
function startSending(config: PhaseStartConfig, phaseClients: WorkerClient[], originAt: number, endAt: number): () => void {
    const periodMs = 1000 / config.actionsPerSecond;

    if (config.sendMode === "lockstep") {
        // Legacy: one timer sends for every joined client at once; RTT from the actual send.
        const timer = setInterval(() => {
            for (const client of phaseClients) {
                if (client.isJoined() && client.isUsable()) {
                    sendOne(config, client);
                }
            }
        }, Math.max(1, Math.floor(periodMs)));
        return () => clearInterval(timer);
    }

    // Spread: each client on its own schedule from the common origin. A late timer sends every
    // slot it missed, each measured from its intended time.
    let stopped = false;
    const timers = new Set<NodeJS.Timeout>();
    for (const client of phaseClients) {
        const schedule = new SendSchedule(originAt, periodMs, sendOffsetMs(client.getKey(), periodMs));
        const arm = () => {
            if (stopped || schedule.nextDueMs() >= endAt) {
                return;
            }
            const timer = setTimeout(() => {
                timers.delete(timer);
                if (stopped) {
                    return;
                }
                if (client.isUsable()) {
                    for (const intendedAt of schedule.takeDue(Date.now(), endAt)) {
                        sendOne(config, client, intendedAt);
                    }
                    arm();
                }
            }, Math.max(0, schedule.nextDueMs() - Date.now()));
            timers.add(timer);
        };
        client.onJoined((joinedAt) => {
            schedule.startAt(Math.max(joinedAt, originAt));
            arm();
        });
    }
    return () => {
        stopped = true;
        timers.forEach((timer) => clearTimeout(timer));
        timers.clear();
    };
}

function aggregateSessions(sessions: WorkerSession[]) {
    const metrics = sessions.map((session) => session.metrics);
    return {
        rttMs: concatAll(metrics.map((m) => m.rttMs)),
        rttAt: concatAll(metrics.map((m) => m.rttAt)),
        stateUpdateIntervalsMs: concatAll(metrics.map((m) => m.stateUpdateIntervalsMs)),
        updateAt: concatAll(metrics.map((m) => m.updateAt)),
        sendLagMs: concatAll(metrics.map((m) => m.sendLagMs)),
        sentAt: concatAll(metrics.map((m) => m.sentAt)),
        errorAt: concatAll(metrics.map((m) => m.errorAt)),
        lateResponseOrigins: concatAll(metrics.map((m) => m.lateResponseOrigins)),
        errorCount: metrics.reduce((sum, m) => sum + m.errorCount, 0),
        actionOutcomes: sumActionOutcomes(metrics.map((m) => m.actionOutcomes)),
        appliedRttMs: concatAll(metrics.map((m) => m.appliedRttMs)),
        decodeErrorAt: concatAll(metrics.map((m) => m.decodeErrorAt)),
        decodeErrorsAfterLeave: metrics.reduce((sum, m) => sum + m.decodeErrorsAfterLeave, 0),
        firstDecodeError: metrics.find((m) => m.firstDecodeError !== undefined)?.firstDecodeError,
        disconnectCount: metrics.reduce((sum, m) => sum + m.disconnectCount, 0),
        actionsSent: metrics.reduce((sum, m) => sum + m.actionsSent, 0),
        eventSentAt: mergeEventSentAt(metrics.map((m) => m.eventSentAt)),
        // Concatenated in the same connection order as `updateAt`, so they stay parallel when
        // every connection recorded sizes (the CLI always does).
        updateBytes: concatAll(metrics.map((m) => m.updateBytes)),
        permessageDeflate: {
            negotiated: metrics.reduce((sum, m) => sum + m.permessageDeflate.negotiated, 0),
            notNegotiated: metrics.reduce((sum, m) => sum + m.permessageDeflate.notNegotiated, 0)
        },
        syncFrameGrouping: {
            grouped: metrics.reduce((sum, m) => sum + m.syncFrameGrouping.grouped, 0),
            ungroupedAfterBroadcast: metrics.reduce((sum, m) => sum + m.syncFrameGrouping.ungroupedAfterBroadcast, 0)
        },
        inputLatency: {
            latencyMs: concatAll(metrics.map((m) => m.inputLatency.latencyMs)),
            latencySentAt: concatAll(metrics.map((m) => m.inputLatency.latencySentAt)),
            supersededSentAt: concatAll(metrics.map((m) => m.inputLatency.supersededSentAt)),
            timedOutSentAt: concatAll(metrics.map((m) => m.inputLatency.timedOutSentAt))
        },
        closes: concatAll(metrics.map((m) => m.closes)),
        reconnects: concatAll(metrics.map((m) => m.reconnects))
    };
}
