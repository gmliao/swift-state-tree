import { WorkerClient, WorkerSession, selectAction } from "./worker";
import { sendMessageWithAck } from "./ipc";
import { renderTemplateObject } from "./payload";
import type { ActionConfig } from "./types";

interface StartConfig {
    serverUrl: string;
    landType: string;
    phaseName: string;
    actions: ActionConfig[];
    connectionCount: number;
    actionsPerSecond: number;
    durationSeconds: number;
    joinPayloadTemplate?: Record<string, unknown>;
    workerIndex: number;
}

interface StartMessage {
    type: "start";
    config: StartConfig;
}

process.on("message", (message: StartMessage) => {
    if (message?.type === "start") {
        runWorker(message.config).catch((error) => {
            process.send?.({ type: "error", error: String(error) });
        });
    }
});

async function runWorker(config: StartConfig): Promise<void> {
    const clients: WorkerClient[] = [];
    const sessions: WorkerSession[] = [];

    for (let i = 0; i < config.connectionCount; i += 1) {
        const playerId = `${config.workerIndex}-${i}`;
        const landInstanceId = `${config.phaseName}-${config.workerIndex}-${i}`;
        const joinMetadata = config.joinPayloadTemplate
            ? renderTemplateObject(config.joinPayloadTemplate, { playerId })
            : undefined;
        const client = new WorkerClient({
            serverUrl: config.serverUrl,
            landType: config.landType,
            landInstanceId,
            playerId,
            actions: config.actions,
            joinMetadata
        });
        client.connect();
        clients.push(client);
        sessions.push(client.getSession());
    }

    const intervalMs = config.actionsPerSecond > 0 ? Math.max(1, Math.floor(1000 / config.actionsPerSecond)) : 1000;
    let actionCounter = 0;

    const timer = setInterval(() => {
        for (const client of clients) {
            if (!client.isJoined()) {
                continue;
            }
            const action = selectAction(config.actions, actionCounter++);
            const payload = renderTemplateObject(action.payloadTemplate ?? {}, {
                playerId: client.getPlayerId()
            });
            client.sendAction(`action-${process.pid}-${actionCounter}`, action.name, payload);
        }
    }, intervalMs);

    setTimeout(async () => {
        clearInterval(timer);
        const report = aggregateSessions(sessions);
        const send = (message: unknown, callback?: (error?: Error | null) => void) => {
            if (!process.send) {
                return false;
            }
            return process.send(message, undefined, undefined, callback);
        };
        if (!process.send) {
            process.exit(1);
            return;
        }
        try {
            await sendMessageWithAck(send, { type: "report", report });
            process.exit(0);
        } catch {
            process.exit(1);
        }
    }, config.durationSeconds * 1000);
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
    let rttIndex = 0;
    let updIndex = 0;

    for (const session of sessions) {
        for (let i = 0; i < session.metrics.rttMs.length; i += 1) {
            rttMs[rttIndex++] = session.metrics.rttMs[i];
        }
        for (let i = 0; i < session.metrics.stateUpdateIntervalsMs.length; i += 1) {
            stateUpdateIntervalsMs[updIndex++] = session.metrics.stateUpdateIntervalsMs[i];
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
