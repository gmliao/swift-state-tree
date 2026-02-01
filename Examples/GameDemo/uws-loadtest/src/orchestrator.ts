import type { PhaseConfig, PhaseName, Scenario } from "./types";
import { parseScenario } from "./scenario";

export interface Phase {
    name: PhaseName;
    config: PhaseConfig;
}

export function buildPhases(rawScenario: unknown): Phase[] {
    const scenario = parseScenario(rawScenario) as Scenario;
    const order: PhaseName[] = ["preflight", "steady", "postflight"];
    return order.map((name) => ({ name, config: scenario.phases[name] }));
}

export function computeAssignments(totalConnections: number, workerCount: number): number[] {
    if (workerCount <= 0) {
        return [];
    }
    const base = Math.floor(totalConnections / workerCount);
    const remainder = totalConnections % workerCount;
    const assignments: number[] = [];
    for (let i = 0; i < workerCount; i += 1) {
        assignments.push(base + (i < remainder ? 1 : 0));
    }
    return assignments;
}
