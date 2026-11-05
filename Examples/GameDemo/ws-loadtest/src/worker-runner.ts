import { WorkerClient, WorkerSession, selectAction } from "./worker";
import type { CloseRecord } from "./worker";
import { sendMessageWithAck } from "./ipc";
import { renderTemplateObject } from "./payload";
import { connectDelaysMs } from "./connect-schedule";
import type { ConnectMode } from "./connect-schedule";
import type { ConnectionSpec } from "./layout";
import type { ActionConfig } from "./types";

/** One phase for this worker. The worker lives for the whole run and keeps its connections. */
export interface PhaseStartConfig {
    serverUrl: string;
    landType: string;
    phaseName: string;
    actions: ActionConfig[];
    /** The connections to hold in this phase; kept ones are reused, the rest are opened. */
    connections: ConnectionSpec[];
    connectMode: ConnectMode;
    connectRatePerSecond: number;
    /** Workers opening connections in this phase; the ramp rate is shared between them. */
    activeWorkers: number;
    actionsPerSecond: number;
    durationSeconds: number;
    joinPayloadTemplate?: Record<string, unknown>;
}

export interface WorkerPhaseReport {
    rttMs: number[];
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    disconnectCount: number;
    actionsSent: number;
    /** Every close seen during the phase, including the ones closing the previous phase's surplus. */
    closes: CloseRecord[];
    connectionsOpened: number;
    connectionsReused: number;
    connectionsClosed: number;
    /** Delay of the last new connection, ms after the phase start. */
    connectRampMs: number;
}

type InboundMessage = { type: "phase"; config: PhaseStartConfig } | { type: "shutdown" };

const clients = new Map<string, WorkerClient>();
let actionCounter = 0;
let queue: Promise<void> = Promise.resolve();

process.on("message", (message: InboundMessage) => {
    // Commands run one after another: a shutdown waits for the running phase.
    queue = queue
        .then(() => handle(message))
        .catch((error) => {
            process.send?.({ type: "error", error: String(error) });
        });
});

async function handle(message: InboundMessage): Promise<void> {
    if (message?.type === "phase") {
        const report = await runPhase(message.config);
        await send({ type: "report", report });
    } else if (message?.type === "shutdown") {
        const closes = await closeClients([...clients.values()], "shutdown");
        clients.clear();
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

/** Closes `toClose` with close frames, waits for every handshake, returns their close records. */
async function closeClients(toClose: WorkerClient[], reason: string): Promise<CloseRecord[]> {
    await Promise.all(toClose.map((client) => client.close(reason)));
    const records: CloseRecord[] = [];
    for (const client of toClose) {
        records.push(...client.getSession().metrics.closes);
    }
    return records;
}

async function runPhase(config: PhaseStartConfig): Promise<WorkerPhaseReport> {
    const wanted = new Set(config.connections.map((spec) => spec.key));

    // Close what this phase doesn't use (and anything already closed) before opening new ones.
    const surplus = [...clients.values()].filter((client) => !wanted.has(client.getKey()) || !client.isUsable());
    for (const client of surplus) {
        clients.delete(client.getKey());
    }
    const transitionCloses = await closeClients(surplus, "phase change");

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
        });
        clients.set(spec.key, client);
        phaseClients.push(client);
        newClients.push(client);
    }

    const delays = connectDelaysMs(
        newClients.map((client) => client.getKey()),
        config.connectMode,
        config.connectRatePerSecond,
        config.activeWorkers
    );
    const connectTimers: NodeJS.Timeout[] = [];
    newClients.forEach((client, i) => {
        if (delays[i] <= 0) {
            client.connect();
        } else {
            connectTimers.push(setTimeout(() => client.connect(), delays[i]));
        }
    });

    const timer =
        config.actionsPerSecond > 0
            ? setInterval(() => {
                  for (const client of phaseClients) {
                      if (!client.isJoined() || !client.isUsable()) {
                          continue;
                      }
                      const action = selectAction(config.actions, actionCounter++);
                      const payload = renderTemplateObject(action.payloadTemplate ?? {}, {
                          playerId: client.getPlayerId()
                      });
                      client.sendAction(`action-${process.pid}-${actionCounter}`, action.name, payload);
                  }
              }, Math.max(1, Math.floor(1000 / config.actionsPerSecond)))
            : undefined;

    await new Promise((resolve) => setTimeout(resolve, config.durationSeconds * 1000));
    if (timer) {
        clearInterval(timer);
    }
    connectTimers.forEach((t) => clearTimeout(t));

    const report = aggregateSessions(phaseClients.map((client) => client.getSession()));
    // What was reported belongs to this phase; anything after it (late responses, closes at the
    // next transition) goes to the next report.
    phaseClients.forEach((client) => client.getSession().resetMetrics());
    return {
        ...report,
        closes: [...transitionCloses, ...report.closes],
        connectionsOpened: newClients.length,
        connectionsReused: reused,
        connectionsClosed: surplus.length,
        connectRampMs: delays.length > 0 ? Math.round(delays[delays.length - 1]) : 0
    };
}

function aggregateSessions(sessions: WorkerSession[]) {
    // Do NOT use push(...arr) - with large loads, spreading can overflow the JS call stack.
    let totalRtt = 0;
    let totalUpd = 0;
    let errorCount = 0;
    let disconnectCount = 0;
    let actionsSent = 0;

    for (const session of sessions) {
        totalRtt += session.metrics.rttMs.length;
        totalUpd += session.metrics.stateUpdateIntervalsMs.length;
        errorCount += session.metrics.errorCount;
        disconnectCount += session.metrics.disconnectCount;
        actionsSent += session.metrics.actionsSent;
    }

    const rttMs: number[] = new Array(totalRtt);
    const stateUpdateIntervalsMs: number[] = new Array(totalUpd);
    const closes: CloseRecord[] = [];
    let rttIndex = 0;
    let updIndex = 0;

    for (const session of sessions) {
        for (let i = 0; i < session.metrics.rttMs.length; i += 1) {
            rttMs[rttIndex++] = session.metrics.rttMs[i];
        }
        for (let i = 0; i < session.metrics.stateUpdateIntervalsMs.length; i += 1) {
            stateUpdateIntervalsMs[updIndex++] = session.metrics.stateUpdateIntervalsMs[i];
        }
        for (const record of session.metrics.closes) {
            closes.push(record);
        }
    }

    return {
        rttMs,
        stateUpdateIntervalsMs,
        errorCount,
        disconnectCount,
        actionsSent,
        closes
    };
}
