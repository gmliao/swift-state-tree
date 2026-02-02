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

/** Default server sync interval (Hero Defense StateSync 100ms = 10 Hz). */
const DEFAULT_SYNC_INTERVAL_MS = 100;
/** Margin for client-observed update interval (event-loop jitter). updateP95 = syncIntervalMs + this. */
const UPDATE_P95_MARGIN_MS = 20;
const DEFAULT_UPDATE_P99_MS = 250;

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
}

function coerceNumber(value: unknown, fallback: number): number {
    return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function coerceBoolean(value: unknown, fallback: boolean): boolean {
    return typeof value === "boolean" ? value : fallback;
}

function parsePhase(name: PhaseName, rawPhase: unknown, syncIntervalMs: number): PhaseConfig {
    const defaults = DEFAULT_PHASES[name];
    const phase = isRecord(rawPhase) ? rawPhase : {};

    const derivedUpdateP95 = syncIntervalMs + UPDATE_P95_MARGIN_MS;
    const derivedUpdateP99 = DEFAULT_UPDATE_P99_MS;

    let thresholds: PhaseConfig["thresholds"];
    if (isRecord(phase.thresholds)) {
        const t = phase.thresholds as Record<string, unknown>;
        thresholds = {
            errorRate: coerceNumber(t.errorRate, 0.001),
            disconnectRate: coerceNumber(t.disconnectRate, 0.001),
            rttP95: coerceNumber(t.rttP95, 100),
            rttP99: coerceNumber(t.rttP99, 250),
            updateP95: coerceNumber(t.updateP95, derivedUpdateP95),
            updateP99: coerceNumber(t.updateP99, derivedUpdateP99)
        };
    } else {
        thresholds = {
            errorRate: 0.001,
            disconnectRate: 0.001,
            rttP95: 100,
            rttP99: 250,
            updateP95: derivedUpdateP95,
            updateP99: derivedUpdateP99
        };
    }

    return {
        durationSeconds: coerceNumber(phase.durationSeconds, defaults.durationSeconds),
        rooms: coerceNumber(phase.rooms, defaults.rooms),
        playersPerRoom: coerceNumber(phase.playersPerRoom, defaults.playersPerRoom),
        actionsPerSecond: coerceNumber(phase.actionsPerSecond, defaults.actionsPerSecond),
        verify: coerceBoolean(phase.verify, defaults.verify),
        joinPayloadTemplate: isRecord(phase.joinPayloadTemplate) ? phase.joinPayloadTemplate : undefined,
        thresholds
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

    const syncIntervalMs = coerceNumber(raw.syncIntervalMs, DEFAULT_SYNC_INTERVAL_MS);
    const phasesRaw = isRecord(raw.phases) ? raw.phases : {};

    const phases: Record<PhaseName, PhaseConfig> = {
        preflight: parsePhase("preflight", phasesRaw.preflight, syncIntervalMs),
        steady: parsePhase("steady", phasesRaw.steady, syncIntervalMs),
        postflight: parsePhase("postflight", phasesRaw.postflight, syncIntervalMs)
    };

    return {
        name: typeof raw.name === "string" ? raw.name : "hero-defense-loadtest",
        serverUrl: typeof raw.serverUrl === "string" ? raw.serverUrl : DEFAULT_SERVER_URL,
        syncIntervalMs,
        phases,
        actions: parseActions(raw.actions)
    };
}

export { DEFAULT_SERVER_URL };
