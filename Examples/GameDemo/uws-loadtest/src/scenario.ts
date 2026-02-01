import type { Scenario, PhaseConfig, PhaseName, ActionConfig } from "./types";

const DEFAULT_SERVER_URL = "ws://localhost:8080/game/hero-defense";

const DEFAULT_PHASES: Record<PhaseName, Omit<PhaseConfig, "thresholds" | "joinPayloadTemplate">> = {
    preflight: {
        durationSeconds: 10,
        rooms: 50,
        playersPerRoom: 2,
        actionsPerSecond: 1,
        verify: true
    },
    steady: {
        durationSeconds: 60,
        rooms: 500,
        playersPerRoom: 5,
        actionsPerSecond: 1,
        verify: false
    },
    postflight: {
        durationSeconds: 10,
        rooms: 50,
        playersPerRoom: 2,
        actionsPerSecond: 1,
        verify: true
    }
};

const DEFAULT_ACTIONS: ActionConfig[] = [
    { name: "PlayAction", weight: 1, payloadTemplate: {} }
];

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function coerceNumber(value: unknown, fallback: number): number {
    return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function coerceBoolean(value: unknown, fallback: boolean): boolean {
    return typeof value === "boolean" ? value : fallback;
}

function parsePhase(name: PhaseName, rawPhase: unknown): PhaseConfig {
    const defaults = DEFAULT_PHASES[name];
    const phase = isRecord(rawPhase) ? rawPhase : {};

    return {
        durationSeconds: coerceNumber(phase.durationSeconds, defaults.durationSeconds),
        rooms: coerceNumber(phase.rooms, defaults.rooms),
        playersPerRoom: coerceNumber(phase.playersPerRoom, defaults.playersPerRoom),
        actionsPerSecond: coerceNumber(phase.actionsPerSecond, defaults.actionsPerSecond),
        verify: coerceBoolean(phase.verify, defaults.verify),
        joinPayloadTemplate: isRecord(phase.joinPayloadTemplate) ? phase.joinPayloadTemplate : undefined,
        thresholds: isRecord(phase.thresholds) ? (phase.thresholds as any) : undefined
    };
}

function parseActions(raw: unknown): ActionConfig[] {
    if (!Array.isArray(raw)) {
        return DEFAULT_ACTIONS;
    }
    const actions = raw
        .map((entry) => (isRecord(entry) ? entry : null))
        .filter((entry): entry is Record<string, unknown> => entry !== null)
        .map((entry) => ({
            name: typeof entry.name === "string" ? entry.name : "PlayAction",
            weight: coerceNumber(entry.weight, 1),
            payloadTemplate: isRecord(entry.payloadTemplate) ? entry.payloadTemplate : undefined
        }));

    return actions.length > 0 ? actions : DEFAULT_ACTIONS;
}

export function parseScenario(raw: unknown): Scenario {
    if (!isRecord(raw)) {
        throw new Error("Scenario must be an object");
    }

    const phasesRaw = isRecord(raw.phases) ? raw.phases : {};

    const phases: Record<PhaseName, PhaseConfig> = {
        preflight: parsePhase("preflight", phasesRaw.preflight),
        steady: parsePhase("steady", phasesRaw.steady),
        postflight: parsePhase("postflight", phasesRaw.postflight)
    };

    return {
        name: typeof raw.name === "string" ? raw.name : "hero-defense-loadtest",
        serverUrl: typeof raw.serverUrl === "string" ? raw.serverUrl : DEFAULT_SERVER_URL,
        phases,
        actions: parseActions(raw.actions)
    };
}

export { DEFAULT_SERVER_URL };
