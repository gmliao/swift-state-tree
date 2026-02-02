export type PhaseName = "preflight" | "steady" | "postflight";

export interface Thresholds {
    errorRate: number;
    disconnectRate: number;
    rttP95: number;
    rttP99: number;
    updateP95: number;
    updateP99: number;
}

export interface PhaseConfig {
    durationSeconds: number;
    rooms: number;
    playersPerRoom: number;
    actionsPerSecond: number;
    verify: boolean;
    joinPayloadTemplate?: Record<string, unknown>;
    thresholds?: Thresholds;
}

export interface ActionConfig {
    name: string;
    weight: number;
    payloadTemplate?: Record<string, unknown>;
}

export interface Scenario {
    name: string;
    serverUrl: string;
    /** Server StateSync interval in ms (e.g. 100 for 10 Hz). Used to derive default updateP95/updateP99 = interval + margin. */
    syncIntervalMs?: number;
    phases: Record<PhaseName, PhaseConfig>;
    actions: ActionConfig[];
}
