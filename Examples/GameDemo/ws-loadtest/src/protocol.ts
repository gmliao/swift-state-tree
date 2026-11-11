import { decode as msgpackDecode, encode as msgpackEncode } from "@msgpack/msgpack";

export const MessageKindOpcode = {
    action: 101,
    actionResponse: 102,
    event: 103,
    join: 104,
    joinResponse: 105,
    error: 106,
    stateUpdateWithEvents: 107,
    syncAck: 108
} as const;

export const StateUpdateOpcode = {
    noChange: 0,
    firstSync: 1,
    diff: 2,
    /** A full view on a live connection (#332): decoded as a firstSync. */
    resync: 3
} as const;

/** `StateUpdate.type` values in the jsonObject encoding (`{ type, patches? }`, no `kind`). */
const JSON_OBJECT_STATE_UPDATE_TYPES = new Set(["noChange", "firstSync", "diff", "resync"]);

/**
 * Normalizes a decoded frame. Opcode arrays (opcodeJsonArray, messagepack) become
 * `{ kind, ... }` or `{ type: "stateUpdate" | "stateUpdateWithEvents", ... }`. jsonObject
 * state updates become `{ type: "stateUpdate", updateType, patches }`. Transport messages
 * (`{ kind, payload }`) are returned as they are.
 */
export function classifyDecoded(decoded: any): any {
    if (Array.isArray(decoded) && decoded.length > 0 && typeof decoded[0] === "number") {
        const opcode = decoded[0];
        if (opcode === MessageKindOpcode.actionResponse) {
            return { kind: "actionResponse", requestID: decoded[1], response: decoded[2] };
        }
        if (opcode === MessageKindOpcode.joinResponse) {
            return {
                kind: "joinResponse",
                requestID: decoded[1],
                success: decoded[2] === 1,
                landType: decoded[3],
                landInstanceId: decoded[4],
                playerSlot: decoded[5],
                encoding: decoded[6],
                reason: decoded[7],
                stateUpdateFeatures: decoded[8]
            };
        }
        if (opcode === MessageKindOpcode.error) {
            return { kind: "error", code: decoded[1], message: decoded[2], details: decoded[3] };
        }
        if (opcode === MessageKindOpcode.stateUpdateWithEvents) {
            return { type: "stateUpdateWithEvents", stateUpdate: decoded[1], events: decoded[2] };
        }
        if (
            opcode === StateUpdateOpcode.noChange ||
            opcode === StateUpdateOpcode.firstSync ||
            opcode === StateUpdateOpcode.diff ||
            opcode === StateUpdateOpcode.resync
        ) {
            return { type: "stateUpdate", opcode };
        }
    }

    if (decoded && typeof decoded === "object" && "kind" in decoded) {
        return decoded;
    }

    if (
        decoded &&
        typeof decoded === "object" &&
        !Array.isArray(decoded) &&
        JSON_OBJECT_STATE_UPDATE_TYPES.has(decoded.type)
    ) {
        return { type: "stateUpdate", updateType: decoded.type, patches: decoded.patches };
    }

    return decoded;
}

/**
 * The sync sequence of a state frame (#332), with `syncSequence` negotiated: `[op, seq, …]`,
 * opcode 107's state array the same, or a JSON object's `seq`. Undefined for any other frame.
 */
export function syncSeqOf(raw: any): number | undefined {
    if (Array.isArray(raw) && typeof raw[0] === "number") {
        const state = raw[0] === MessageKindOpcode.stateUpdateWithEvents ? raw[1] : raw;
        if (Array.isArray(state) && state[0] >= StateUpdateOpcode.noChange && state[0] <= StateUpdateOpcode.resync) {
            return typeof state[1] === "number" ? state[1] : undefined;
        }
        return undefined;
    }
    if (raw && typeof raw === "object" && JSON_OBJECT_STATE_UPDATE_TYPES.has(raw.type) && typeof raw.seq === "number") {
        return raw.seq;
    }
    return undefined;
}

/** A sync ack, `[108, seq]`, in the connection's message encoding. */
export function encodeSyncAck(seq: number, messagepack: boolean): string | Uint8Array {
    return messagepack ? msgpackEncode([MessageKindOpcode.syncAck, seq]) : `[${MessageKindOpcode.syncAck},${seq}]`;
}

export function decodeMessage(data: string | ArrayBuffer | Uint8Array): any {
    return classifyDecoded(decodeRaw(data));
}

/** A frame as decoded from JSON or MessagePack, before `classifyDecoded`. */
export function decodeRaw(data: string | ArrayBuffer | Uint8Array): any {
    if (typeof data === "string") {
        return JSON.parse(data);
    }
    const buffer = data instanceof Uint8Array ? data : new Uint8Array(data);
    try {
        return msgpackDecode(buffer);
    } catch {
        const text = new TextDecoder().decode(buffer);
        return JSON.parse(text);
    }
}

/** Row entries' ops (`RowPatchOpcode` in the SDK): create 6, delete 7, column set 8, column clear 9. */
const ROW_ENTRY_OP_MIN = 6;
const ROW_ENTRY_OP_MAX = 9;

/** The SDK's strict close for a row entry (`INVALID_ROW_ENTRY_CLOSE_CODE`). */
export const INVALID_ROW_ENTRY_CLOSE_CODE = 4013;

/**
 * A close reason cut to 123 UTF-8 bytes at a character boundary, as the SDK's
 * `truncatedCloseReason` does: `ws` throws on a longer one. The SDK isn't loaded without
 * `--reconstruct`, so the worker has its own.
 */
export function truncatedCloseReason(reason: string): string {
    if (Buffer.byteLength(reason, "utf8") <= 123) return reason;
    let out = "";
    let bytes = 0;
    for (const character of reason) {
        const size = Buffer.byteLength(character, "utf8");
        if (bytes + size > 123) break;
        out += character;
        bytes += size;
    }
    return out;
}

/**
 * Follows one connection's dynamic key tables the way the TypeScript SDK decodes them, to count
 * frames a real client could not decode (#90, #191). Opcode 107 frames use the broadcast map,
 * plain opcode state updates the per-player map; a firstSync clears the map it is decoded with;
 * `[slot, key]` defines a slot, a bare slot must be defined. A frame fails at its first
 * undefined slot (definitions before it in the frame still apply, as in the SDK). Patches are
 * not applied: only the keys are tracked.
 *
 * Row entries (ops 6 to 9, `rowAddressing`) carry slots of row tables, not dynamic keys, and
 * their keys inline: they are counted, not resolved. Their strict rules need the land's patterns,
 * which only the SDK's decoder has (`--reconstruct`). The one rule checked here is the SDK's
 * first: a row entry without the feature negotiated.
 */
export class DynamicKeyTracker {
    private readonly broadcast = new Map<number, string>();
    private readonly perPlayer = new Map<number, string>();
    /** `rowAddressing` negotiated for the connection's join: row entries are expected. */
    rowAddressing = false;
    /** Row entries received on the connection. */
    rowEntries = 0;
    /** The rule a row entry broke, for which an SDK client closes with 4013; the first one. */
    rowViolation: string | undefined;
    /** Frames with a slot used before its definition. */
    errors = 0;
    /** The first error, for the report. */
    firstError: string | undefined;

    /** Checks one raw decoded frame (`decodeRaw`). */
    observe(raw: unknown): void {
        if (!Array.isArray(raw) || typeof raw[0] !== "number") {
            return;
        }
        const opcode = raw[0];
        if (opcode === MessageKindOpcode.stateUpdateWithEvents) {
            if (Array.isArray(raw[1])) this.observeStateArray(raw[1], this.broadcast);
        } else if (
            opcode === StateUpdateOpcode.noChange ||
            opcode === StateUpdateOpcode.firstSync ||
            opcode === StateUpdateOpcode.diff ||
            opcode === StateUpdateOpcode.resync
        ) {
            this.observeStateArray(raw, this.perPlayer);
        }
    }

    private observeStateArray(array: unknown[], keys: Map<number, string>): void {
        if (array[0] === StateUpdateOpcode.firstSync || array[0] === StateUpdateOpcode.resync) {
            keys.clear();
        }
        for (let i = 1; i < array.length; i += 1) {
            const entry = array[i];
            // Path-hash patches only: [pathHash, dynamicKey, op, value?].
            if (!Array.isArray(entry) || typeof entry[0] !== "number") continue;
            // The op before the second element, as the SDK reads it: in a row entry that is a slot.
            const op = entry[2];
            if (typeof op === "number" && op >= ROW_ENTRY_OP_MIN && op <= ROW_ENTRY_OP_MAX) {
                if (!this.rowAddressing) {
                    this.errors += 1;
                    this.rowViolation ??= `op ${op} without rowAddressing negotiated`;
                    this.firstError ??= this.rowViolation;
                    return;
                }
                this.rowEntries += 1;
                continue;
            }
            const missing = this.resolve(entry[1], keys);
            if (missing !== undefined) {
                this.errors += 1;
                this.firstError ??= `Dynamic key slot ${missing} used before definition`;
                return;
            }
        }
    }

    /** Applies the key's definitions; returns the first undefined slot, if any. */
    private resolve(raw: unknown, keys: Map<number, string>): number | undefined {
        if (typeof raw === "number") {
            return keys.has(raw) ? undefined : raw;
        }
        if (!Array.isArray(raw)) {
            return undefined;
        }
        if (raw.length === 2 && typeof raw[0] === "number" && typeof raw[1] === "string") {
            keys.set(raw[0], raw[1]);
            return undefined;
        }
        for (const key of raw) {
            const missing = this.resolve(key, keys);
            if (missing !== undefined) return missing;
        }
        return undefined;
    }
}

export function encodeMessageToMessagePack(payload: unknown): Uint8Array {
    return msgpackEncode(payload);
}
