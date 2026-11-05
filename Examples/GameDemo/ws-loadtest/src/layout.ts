import type { PhaseConfig, PhaseName } from "./types";
import { computeAssignments } from "./orchestrator";

/**
 * How a phase's connections map onto lands.
 * - `rooms`: `rooms` lands with `playersPerRoom` connections each. Whole rooms go to one worker
 *   (round-robin by room index, so a room stays on the same worker in every phase).
 * - `per-connection`: the legacy layout; every connection joins its own land
 *   (`${phase}-${worker}-${i}`), connections split evenly over workers.
 * Every land id starts with the run id (`<runId>-...`).
 */
export type Layout = "rooms" | "per-connection";

export const LAYOUTS: readonly Layout[] = ["rooms", "per-connection"];

/** One connection a worker should hold during a phase. */
export interface ConnectionSpec {
    /**
     * Stable identity across phases. A connection whose key appears in the next phase is kept
     * open and reused; any other is closed with a close frame.
     */
    key: string;
    landInstanceId: string;
    playerId: string;
}

export interface LayoutSummary {
    layout: Layout;
    connections: number;
    lands: number;
    /** Connections per land, min and max (equal unless the layout is uneven). */
    playersPerLand: { min: number; max: number };
    /** Connections per worker, in worker order. */
    connectionsPerWorker: number[];
}

/**
 * A short id for one run, prefixed to every land id so back-to-back runs on one server never
 * join each other's live or draining lands.
 */
export function makeRunId(now: number = Date.now(), random: number = Math.random()): string {
    const time = (now % 36 ** 5).toString(36).padStart(5, "0");
    const salt = Math.floor(random * 36 ** 2).toString(36).padStart(2, "0");
    return `r${time}${salt}`;
}

/** The connections each worker holds in this phase, indexed by worker. */
export function planPhaseConnections(
    phaseName: PhaseName,
    config: Pick<PhaseConfig, "rooms" | "playersPerRoom">,
    workers: number,
    layout: Layout,
    runId: string
): ConnectionSpec[][] {
    if (workers <= 0) {
        return [];
    }
    const plan: ConnectionSpec[][] = Array.from({ length: workers }, () => []);
    const rooms = Math.max(0, Math.floor(config.rooms));
    const playersPerRoom = Math.max(0, Math.floor(config.playersPerRoom));

    if (layout === "per-connection") {
        // Identical to the tool before room layouts: contiguous split of all connections,
        // one land per connection, ids scoped to the phase.
        const assignments = computeAssignments(rooms * playersPerRoom, workers);
        assignments.forEach((count, worker) => {
            for (let i = 0; i < count; i += 1) {
                const id = `${runId}-${phaseName}-${worker}-${i}`;
                plan[worker].push({ key: id, landInstanceId: id, playerId: `${worker}-${i}` });
            }
        });
        return plan;
    }

    // Land ids carry playersPerRoom and not the phase, so phases with the same room size share
    // lands and connections; a phase with another size gets different lands.
    for (let room = 0; room < rooms; room += 1) {
        const worker = room % workers;
        const landInstanceId = `${runId}-room-p${playersPerRoom}-${room}`;
        for (let slot = 0; slot < playersPerRoom; slot += 1) {
            plan[worker].push({
                key: `${landInstanceId}-s${slot}`,
                landInstanceId,
                playerId: `p${playersPerRoom}-r${room}-s${slot}`
            });
        }
    }
    return plan;
}

export function summarizeLayout(plan: ConnectionSpec[][], layout: Layout): LayoutSummary {
    const perLand = new Map<string, number>();
    let connections = 0;
    for (const worker of plan) {
        for (const spec of worker) {
            connections += 1;
            perLand.set(spec.landInstanceId, (perLand.get(spec.landInstanceId) ?? 0) + 1);
        }
    }
    const counts = [...perLand.values()];
    return {
        layout,
        connections,
        lands: perLand.size,
        playersPerLand: {
            min: counts.length > 0 ? Math.min(...counts) : 0,
            max: counts.length > 0 ? Math.max(...counts) : 0
        },
        connectionsPerWorker: plan.map((worker) => worker.length)
    };
}
