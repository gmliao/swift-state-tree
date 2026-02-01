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
});
