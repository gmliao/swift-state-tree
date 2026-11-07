import fs from "node:fs";
import path from "node:path";
import { EntityDeltaClient } from "./entity-delta";
import { ConnectionReconstruction, type SdkCore, type TransportEncodingConfig } from "./reconstruction";

/** The `format` of a capture from the entity-delta baseline, decoded by `EntityDeltaClient`. */
export const ENTITY_DELTA_FORMAT = "entity-delta";

/** What the gate needs from a client: frames in, a state out, decode errors counted. */
interface ClientView {
    feed(data: string | Uint8Array): void;
    state(): unknown;
    decodeErrors: number;
    firstError?: string;
}

/**
 * The reconstruction-equals-projection gate of the snapshot/delta baseline: reads the capture
 * `EncodingBenchmark --capture-views` writes (one NDJSON file per room: a header, then one line
 * per sync with the frames sent since the last one and each player's projection), rebuilds every
 * recipient's state from the frames addressed to it with the TypeScript SDK, as a client does,
 * and compares it with that player's projection after every sync (`compareStates`, the
 * convergence check's comparison). Any difference, or any frame the SDK can't decode, fails.
 */

interface CaptureHeader {
    landID: string;
    format: string;
    message: string;
    stateUpdate: string;
    syncStrategy: string;
    sessions: Record<string, string>;
    schema: unknown;
}

interface CaptureLine {
    sync: number;
    frames: Array<{ to: string; data: string }>;
    projections: Record<string, unknown>;
}

export interface RoomDifference {
    sync: number;
    session: string;
    player: string;
    differences: number;
    paths: Array<{ path: string; client: unknown; server: unknown }>;
}

export interface RoomReport {
    file: string;
    format: string;
    syncStrategy: string;
    sessions: number;
    syncs: number;
    frames: number;
    comparisons: number;
    decodeErrors: number;
    firstDecodeError?: string;
    differences: RoomDifference[];
}

export interface VerifyReport {
    runs: Record<string, RoomReport[]>;
    totals: { rooms: number; syncs: number; comparisons: number; differences: number; decodeErrors: number };
    passed: boolean;
}

/** The SDK's encoding for the Swift `TransportEncodingConfig` a capture names. */
export function sdkEncoding(message: string, stateUpdate: string): TransportEncodingConfig {
    if (message !== "json" && message !== "opcodeJsonArray" && message !== "messagepack") {
        throw new Error(`unknown message encoding ${message}`);
    }
    // The SDK has one opcode decoder for opcodeJsonArray, its legacy path-string form and
    // opcodeMessagePack (the same structure, MessagePack framing decided by the message encoding).
    const opcode = stateUpdate === "opcodeJsonArray" || stateUpdate === "opcodeJsonArrayLegacy" || stateUpdate === "opcodeMessagePack";
    if (!opcode && stateUpdate !== "jsonObject") throw new Error(`unknown state update encoding ${stateUpdate}`);
    return { message, stateUpdate: opcode ? "opcodeJsonArray" : "jsonObject", stateUpdateDecoding: "auto" };
}

/** Whether a frame sent to `target` reaches `session` (of `player`). */
export function reaches(target: string, session: string, player: string): boolean {
    if (target === "*") return true;
    if (target.startsWith("s:")) return target.slice(2) === session;
    if (target.startsWith("p:")) return target.slice(2) === player;
    if (target.startsWith("!")) return target.slice(1) !== session;
    throw new Error(`unknown frame target ${target}`);
}

/** The client a capture's format needs: the SDK's reconstruction, or the entity-delta decoder. */
function clientView(sdk: SdkCore, header: CaptureHeader, player: string): ClientView {
    if (header.format === ENTITY_DELTA_FORMAT) {
        const client = new EntityDeltaClient();
        return {
            feed: (data) => client.feed(typeof data === "string" ? Buffer.from(data, "utf8") : data),
            state: () => client.getState(),
            get decodeErrors() { return client.decodeErrors; },
            get firstError() { return client.firstError; }
        };
    }
    const reconstruction = new ConnectionReconstruction(sdk, header.schema, header.landID, { playerID: player, encoding: sdkEncoding(header.message, header.stateUpdate) });
    return {
        feed: (data) => reconstruction.feed(data),
        state: () => reconstruction.view.getState(),
        get decodeErrors() { return reconstruction.decodeErrors; },
        get firstError() { return reconstruction.firstError; }
    };
}

export function verifyRoom(sdk: SdkCore, file: string, maxPaths = 5): RoomReport {
    const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.length > 0);
    if (lines.length < 2) throw new Error(`${file}: a header and at least one sync are needed`);
    const header = JSON.parse(lines[0]) as CaptureHeader;
    const sessions = Object.entries(header.sessions);
    const views = new Map<string, ClientView>(sessions.map(([session, player]) => [session, clientView(sdk, header, player)]));
    const report: RoomReport = {
        file: path.basename(file), format: header.format, syncStrategy: header.syncStrategy,
        sessions: sessions.length, syncs: 0, frames: 0, comparisons: 0, decodeErrors: 0, differences: []
    };
    for (const raw of lines.slice(1)) {
        const line = JSON.parse(raw) as CaptureLine;
        report.syncs += 1;
        for (const frame of line.frames) {
            report.frames += 1;
            const bytes = Buffer.from(frame.data, "base64");
            // JSON frames are text on the wire; feed them as a client's socket hands them over.
            const data = header.message === "messagepack" || header.format === ENTITY_DELTA_FORMAT ? bytes : bytes.toString("utf8");
            for (const [session, player] of sessions) {
                if (reaches(frame.to, session, player)) views.get(session)!.feed(data);
            }
        }
        for (const [session, player] of sessions) {
            const projection = line.projections[player];
            if (projection === undefined) throw new Error(`${file}: sync ${line.sync} has no projection for ${player}`);
            const differences = sdk.compareStates(views.get(session)!.state(), projection);
            report.comparisons += 1;
            if (differences.length > 0) {
                report.differences.push({ sync: line.sync, session, player, differences: differences.length, paths: differences.slice(0, maxPaths) });
            }
        }
    }
    for (const view of views.values()) {
        report.decodeErrors += view.decodeErrors;
        report.firstDecodeError ??= view.firstError;
    }
    return report;
}

/** Every `<run>/room-<i>.ndjson` under `dir`. */
export function verifyCapture(sdk: SdkCore, dir: string): VerifyReport {
    const runs: Record<string, RoomReport[]> = {};
    for (const run of fs.readdirSync(dir).sort()) {
        const runDir = path.join(dir, run);
        if (!fs.statSync(runDir).isDirectory()) continue;
        const files = fs.readdirSync(runDir).filter((f) => /^room-\d+\.ndjson$/.test(f)).sort((a, b) => parseInt(a.slice(5)) - parseInt(b.slice(5)));
        runs[run] = files.map((f) => verifyRoom(sdk, path.join(runDir, f)));
    }
    const all = Object.values(runs).flat();
    const totals = {
        rooms: all.length,
        syncs: all.reduce((n, r) => n + r.syncs, 0),
        comparisons: all.reduce((n, r) => n + r.comparisons, 0),
        differences: all.reduce((n, r) => n + r.differences.length, 0),
        decodeErrors: all.reduce((n, r) => n + r.decodeErrors, 0)
    };
    // A capture with nothing in it proves nothing.
    return { runs, totals, passed: totals.rooms > 0 && totals.comparisons > 0 && totals.differences === 0 && totals.decodeErrors === 0 };
}
