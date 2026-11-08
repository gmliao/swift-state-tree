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

/**
 * The room slots one client instance holds (`--room-slots`), for runs where two instances share
 * rooms: both pass the same `--run-id`, so they generate the same land ids, and each holds its
 * own slots. Each entry is an inclusive room range and an inclusive slot range; together the
 * entries must not name a (room, slot) twice.
 */
export interface RoomSlotRange {
    rooms: [number, number];
    slots: [number, number];
}

/**
 * Parses `--room-slots`: comma-separated `<rooms>:<slots>` entries, each side a number or an
 * inclusive `a-b` range, e.g. `0-149:0` or `0-149:1-4,150-299:0-4`.
 */
export function parseRoomSlots(spec: string): RoomSlotRange[] {
    const range = (text: string, what: string): [number, number] => {
        const match = /^(\d+)(?:-(\d+))?$/.exec(text);
        if (!match) {
            throw new Error(`--room-slots: ${what} must be a number or a range a-b (got "${text}" in "${spec}")`);
        }
        const from = Number(match[1]);
        const to = match[2] !== undefined ? Number(match[2]) : from;
        if (to < from) {
            throw new Error(`--room-slots: ${what} range ${text} is reversed (in "${spec}")`);
        }
        return [from, to];
    };
    const entries = spec.split(",").map((entry) => {
        const parts = entry.split(":");
        if (parts.length !== 2) {
            throw new Error(`--room-slots: each entry is <rooms>:<slots> (got "${entry}" in "${spec}")`);
        }
        return { rooms: range(parts[0], "rooms"), slots: range(parts[1], "slots") };
    });
    const seen = new Set<string>();
    for (const entry of entries) {
        for (let room = entry.rooms[0]; room <= entry.rooms[1]; room += 1) {
            for (let slot = entry.slots[0]; slot <= entry.slots[1]; slot += 1) {
                const id = `${room}:${slot}`;
                if (seen.has(id)) {
                    throw new Error(`--room-slots: room ${room} slot ${slot} is named twice (in "${spec}")`);
                }
                seen.add(id);
            }
        }
    }
    return entries;
}

/**
 * Throws unless every entry fits the phase: rooms below `rooms` and slots below
 * `playersPerRoom`. Slots outside a phase's room size are refused, not skipped, so a run
 * never holds fewer connections than the plan says.
 */
export function checkRoomSlots(
    roomSlots: RoomSlotRange[],
    phaseName: PhaseName,
    config: Pick<PhaseConfig, "rooms" | "playersPerRoom">,
    flag = "--room-slots"
): void {
    for (const entry of roomSlots) {
        if (entry.rooms[1] >= config.rooms) {
            throw new Error(`${flag}: rooms ${entry.rooms[0]}-${entry.rooms[1]} exceed phase ${phaseName}'s ${config.rooms} rooms`);
        }
        if (entry.slots[1] >= config.playersPerRoom) {
            throw new Error(`${flag}: slots ${entry.slots[0]}-${entry.slots[1]} exceed phase ${phaseName}'s ${config.playersPerRoom} players per room`);
        }
    }
}

/** Whether `room`'s `slot` is in one of the entries. */
function inSlots(entries: RoomSlotRange[], room: number, slot: number): boolean {
    return entries.some(
        (entry) => room >= entry.rooms[0] && room <= entry.rooms[1] && slot >= entry.slots[0] && slot <= entry.slots[1]
    );
}

/** One connection a worker should hold during a phase. */
export interface ConnectionSpec {
    /**
     * Stable identity across phases. A connection whose key appears in the next phase is kept
     * open and reused; any other is closed with a close frame.
     */
    key: string;
    landInstanceId: string;
    playerId: string;
    /**
     * `--reconstruct-slots`: whether this connection rebuilds its client state (and is listed
     * on the control channel for the convergence check). Absent without the option: every
     * connection reconstructs when `--reconstruct` is on, as before the option existed.
     */
    reconstruct?: boolean;
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
    runId: string,
    roomSlots?: RoomSlotRange[],
    reconstructSlots?: RoomSlotRange[]
): ConnectionSpec[][] {
    if (workers <= 0) {
        return [];
    }
    const plan: ConnectionSpec[][] = Array.from({ length: workers }, () => []);
    const rooms = Math.max(0, Math.floor(config.rooms));
    const playersPerRoom = Math.max(0, Math.floor(config.playersPerRoom));

    if (roomSlots && layout !== "rooms") {
        throw new Error("--room-slots needs --layout rooms");
    }
    if (reconstructSlots && layout !== "rooms") {
        throw new Error("--reconstruct-slots needs --layout rooms");
    }
    if (roomSlots) {
        checkRoomSlots(roomSlots, phaseName, config);
    }
    if (reconstructSlots) {
        checkRoomSlots(reconstructSlots, phaseName, config, "--reconstruct-slots");
    }
    const holds = (room: number, slot: number): boolean => !roomSlots || inSlots(roomSlots, room, slot);

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
            if (!holds(room, slot)) {
                continue;
            }
            plan[worker].push({
                key: `${landInstanceId}-s${slot}`,
                landInstanceId,
                playerId: `p${playersPerRoom}-r${room}-s${slot}`,
                ...(reconstructSlots ? { reconstruct: inSlots(reconstructSlots, room, slot) } : {})
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
