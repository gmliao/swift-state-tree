import { describe, it, expect } from "vitest";
import { encode } from "@msgpack/msgpack";
import { decodeMessage } from "../src/protocol";

describe("protocol decoding", () => {
    it("decodes messagepack transport messages", () => {
        const buf = encode({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
        const msg = decodeMessage(buf);
        expect((msg as any).kind).toBe("joinResponse");
    });

    it("decodes opcode array actionResponse", () => {
        const payload = [102, "req-1", { ok: true }];
        const buf = encode(payload);
        const msg = decodeMessage(buf);
        expect((msg as any).kind).toBe("actionResponse");
        expect((msg as any).requestID).toBe("req-1");
    });

    it("decodes an opcode joinResponse's state-update features (index 8)", () => {
        const msg = decodeMessage(encode([105, "join-1", 1, "hero-defense", "room-1", 0, "messagepack", null, ["pathIndex", "fieldMerge"]]));
        expect((msg as any).kind).toBe("joinResponse");
        expect((msg as any).stateUpdateFeatures).toEqual(["pathIndex", "fieldMerge"]);
    });

    it("decodes JSON when binary frame contains text", () => {
        const json = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
        const buf = new TextEncoder().encode(json);
        const msg = decodeMessage(buf);
        expect((msg as any).kind).toBe("joinResponse");
    });
});

/** One state update per encoding (TRANSPORT_ENCODING json, opcodeJsonArray, messagepack). */
describe("state update classification per encoding (#138)", () => {
    const patches = [{ op: "replace", path: "/score", value: 1 }];

    it("jsonObject: { type, patches } text frames are state updates", () => {
        for (const type of ["noChange", "firstSync", "diff"]) {
            const body = type === "noChange" ? { type } : { type, patches };
            const msg = decodeMessage(JSON.stringify(body));
            expect(msg.type).toBe("stateUpdate");
            expect(msg.updateType).toBe(type);
        }
    });

    it("opcodeJsonArray: opcode-array text frames are state updates", () => {
        for (const opcode of [0, 1, 2]) {
            expect(decodeMessage(JSON.stringify([opcode, patches])).type).toBe("stateUpdate");
        }
        expect(decodeMessage(JSON.stringify([107, [2, patches], []])).type).toBe("stateUpdateWithEvents");
    });

    it("messagepack: opcode-array binary frames are state updates", () => {
        expect(decodeMessage(encode([2, patches])).type).toBe("stateUpdate");
        expect(decodeMessage(encode([107, [2, patches], []])).type).toBe("stateUpdateWithEvents");
    });

    it("jsonObject transport messages the worker relies on keep their kind", () => {
        const frames = {
            actionResponse: { kind: "actionResponse", payload: { actionResponse: { requestID: "r1", response: {} } } },
            error: { kind: "error", payload: { error: { code: "X", message: "m", details: { requestID: "r1" } } } },
            joinResponse: { kind: "joinResponse", payload: { joinResponse: { requestID: "join-1", success: true } } },
            event: { kind: "event", payload: { event: { type: "x" } } }
        };
        for (const [kind, body] of Object.entries(frames)) {
            const msg = decodeMessage(JSON.stringify(body));
            expect(msg.kind).toBe(kind);
            expect(msg.type).toBeUndefined();
        }
    });

    it("an object with a type that isn't a StateUpdate type isn't a state update", () => {
        expect(decodeMessage(JSON.stringify({ type: "other" })).type).toBe("other");
    });
});

describe("sync sequence (#332)", () => {
    it("reads the sequence of opcode, 107 and JSON object state frames, and nothing else", async () => {
        const { syncSeqOf, encodeSyncAck, DynamicKeyTracker } = await import("../src/protocol");
        expect(syncSeqOf([2, 7, [1, 0, 1, 3]])).toBe(7);
        expect(syncSeqOf([107, [3, 8], []])).toBe(8);
        expect(syncSeqOf({ type: "resync", seq: 9, patches: [] })).toBe(9);
        expect(syncSeqOf([103, 1, 2])).toBeUndefined();
        expect(syncSeqOf({ kind: "event" })).toBeUndefined();
        expect(encodeSyncAck(5, false)).toBe("[108,5]");
        expect(Array.from(encodeSyncAck(5, true) as Uint8Array)).toEqual([0x92, 0x6c, 0x05]);
        expect((decodeMessage(JSON.stringify([3, 4])) as any).opcode).toBe(3);
        // A resync clears the per-player key map, as a firstSync does.
        const tracker = new DynamicKeyTracker();
        tracker.observe([2, 1, [10, [0, "a"], 1, 1]]);
        tracker.observe([3, 2, [10, 0, 1, 1]]);
        expect(tracker.errors).toBe(1);
    });
});
