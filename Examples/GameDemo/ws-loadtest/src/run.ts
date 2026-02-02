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
    /** Server StateSync interval in ms (e.g. 100). Used in report for client-jitter hint. */
    syncIntervalMs?: number;
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

    return {
        scenarioName: scenario.name,
        syncIntervalMs: scenario.syncIntervalMs,
        phases: results
    };
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
    const register = require.resolve("tsx/register");
    return { scriptPath: tsPath, execArgv: ["-r", register] };
}
