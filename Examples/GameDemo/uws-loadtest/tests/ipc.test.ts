import { describe, it, expect, vi } from "vitest";
import { sendMessageWithAck } from "../src/ipc";

describe("sendMessageWithAck", () => {
    it("resolves when callback is invoked", async () => {
        const sendFn = vi.fn((message: unknown, callback?: (error?: Error | null) => void) => {
            callback?.(null);
            return true;
        });

        await expect(sendMessageWithAck(sendFn, { ok: true }, 50)).resolves.toBeUndefined();
        expect(sendFn).toHaveBeenCalledTimes(1);
    });
});
