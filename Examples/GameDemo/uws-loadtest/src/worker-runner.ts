import { WorkerClient, WorkerSession, selectAction } from "./worker";
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
        const landInstanceId = `${config.phaseName}-${config.workerIndex}-${i}`;
        const joinMetadata = config.joinPayloadTemplate
            ? renderTemplateObject(config.joinPayloadTemplate, { playerId: `${config.workerIndex}-${i}` })
            : undefined;
        const client = new WorkerClient({
            serverUrl: config.serverUrl,
            landType: config.landType,
            landInstanceId,
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
                playerId: String(actionCounter)
            });
            client.sendAction(`action-${process.pid}-${actionCounter}`, action.name, payload);
        }
    }, intervalMs);

    setTimeout(() => {
        clearInterval(timer);
        const report = aggregateSessions(sessions);
        process.send?.({ type: "report", report });
        for (const client of clients) {
            client.getSession();
        }
        process.exit(0);
    }, config.durationSeconds * 1000);
}

function aggregateSessions(sessions: WorkerSession[]) {
    const report = {
        rttMs: [] as number[],
        stateUpdateIntervalsMs: [] as number[],
        errorCount: 0,
        disconnectCount: 0,
        actionsSent: 0
    };

    for (const session of sessions) {
        report.rttMs.push(...session.metrics.rttMs);
        report.stateUpdateIntervalsMs.push(...session.metrics.stateUpdateIntervalsMs);
        report.errorCount += session.metrics.errorCount;
        report.disconnectCount += session.metrics.disconnectCount;
        report.actionsSent += session.metrics.actionsSent;
    }

    return report;
}
