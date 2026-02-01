import { decode as msgpackDecode, encode as msgpackEncode } from "@msgpack/msgpack";

export const MessageKindOpcode = {
    action: 101,
    actionResponse: 102,
    event: 103,
    join: 104,
    joinResponse: 105,
    error: 106,
    stateUpdateWithEvents: 107
} as const;

export const StateUpdateOpcode = {
    noChange: 0,
    firstSync: 1,
    diff: 2
} as const;

function classifyDecoded(decoded: any): any {
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
                reason: decoded[7]
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
            opcode === StateUpdateOpcode.diff
        ) {
            return { type: "stateUpdate", opcode };
        }
    }

    if (decoded && typeof decoded === "object" && "kind" in decoded) {
        return decoded;
    }

    return decoded;
}

export function decodeMessage(data: string | ArrayBuffer | Uint8Array): any {
    if (typeof data === "string") {
        return classifyDecoded(JSON.parse(data));
    }
    const buffer = data instanceof Uint8Array ? data : new Uint8Array(data);
    return classifyDecoded(msgpackDecode(buffer));
}

export function encodeMessageToMessagePack(payload: unknown): Uint8Array {
    return msgpackEncode(payload);
}
