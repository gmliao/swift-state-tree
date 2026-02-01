import fs from "node:fs";
import path from "node:path";
import { fork } from "node:child_process";
import type { PhaseName, Scenario, ActionConfig, PhaseConfig } from "./types";
import { parseScenario } from "./scenario";
import { buildPhases, computeAssignments } from "./orchestrator";

export interface WorkerReport {
    rttMs: number[];
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    disconnectCount: number;
    actionsSent: number;
}

export interface PhaseResult {
    name: PhaseName;
    config: PhaseConfig;
    report: WorkerReport;
}

export interface RunResult {
    scenarioName: string;
    phases: PhaseResult[];
}

export function loadScenario(filePath: string): Scenario {
    const raw = fs.readFileSync(filePath, "utf-8");
    const json = JSON.parse(raw);
    return parseScenario(json);
}

export async function runScenario(filePath: string, workers: number): Promise<RunResult> {
    const scenario = loadScenario(filePath);
    const phases = buildPhases(scenario);
    const results: PhaseResult[] = [];

    for (const phase of phases) {
        const totalConnections = phase.config.rooms * phase.config.playersPerRoom;
        const assignments = computeAssignments(totalConnections, workers);
        const reports = await runPhaseWorkers(
            scenario.serverUrl,
            scenario.actions,
            phase.name,
            phase.config.durationSeconds,
            phase.config.actionsPerSecond,
            phase.config.joinPayloadTemplate,
            assignments
        );
        const aggregated = aggregateReports(reports);
        results.push({ name: phase.name, config: phase.config, report: aggregated });
    }

    return { scenarioName: scenario.name, phases: results };
}

async function runPhaseWorkers(
    serverUrl: string,
    actions: ActionConfig[],
    phaseName: PhaseName,
    durationSeconds: number,
    actionsPerSecond: number,
    joinPayloadTemplate: Record<string, unknown> | undefined,
    assignments: number[]
): Promise<WorkerReport[]> {
    const workerScript = resolveWorkerScript();
    const reports: Promise<WorkerReport>[] = [];

    for (let i = 0; i < assignments.length; i += 1) {
        const connectionCount = assignments[i];
        if (connectionCount === 0) {
            continue;
        }
        const child = fork(workerScript.scriptPath, [], {
            execArgv: workerScript.execArgv,
            stdio: ["inherit", "inherit", "inherit", "ipc"]
        });
        const reportPromise = new Promise<WorkerReport>((resolve, reject) => {
            const timeout = setTimeout(() => {
                child.kill("SIGKILL");
                reject(new Error(`Worker ${child.pid} timeout`));
            }, (durationSeconds + 10) * 1000);

            child.on("message", (message: any) => {
                if (message?.type === "report") {
                    clearTimeout(timeout);
                    resolve(message.report as WorkerReport);
                    child.kill();
                }
            });
            child.on("error", (error) => {
                clearTimeout(timeout);
                reject(error);
            });
        });

        child.send({
            type: "start",
            config: {
                serverUrl,
                landType: "hero-defense",
                phaseName,
                actions,
                connectionCount,
                actionsPerSecond,
                durationSeconds,
                joinPayloadTemplate,
                workerIndex: i
            }
        });

        reports.push(reportPromise);
    }

    return Promise.all(reports);
}

function aggregateReports(reports: WorkerReport[]): WorkerReport {
    const aggregated: WorkerReport = {
        rttMs: [],
        stateUpdateIntervalsMs: [],
        errorCount: 0,
        disconnectCount: 0,
        actionsSent: 0
    };

    for (const report of reports) {
        aggregated.rttMs.push(...report.rttMs);
        aggregated.stateUpdateIntervalsMs.push(...report.stateUpdateIntervalsMs);
        aggregated.errorCount += report.errorCount;
        aggregated.disconnectCount += report.disconnectCount;
        aggregated.actionsSent += report.actionsSent;
    }

    return aggregated;
}

function resolveWorkerScript(): { scriptPath: string; execArgv: string[] } {
    const jsPath = path.join(__dirname, "worker-runner.js");
    if (fs.existsSync(jsPath)) {
        return { scriptPath: jsPath, execArgv: [] };
    }

    const tsPath = path.join(__dirname, "worker-runner.ts");
    const register = require.resolve("tsx/register");
    return { scriptPath: tsPath, execArgv: ["-r", register] };
}
