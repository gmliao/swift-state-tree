import { describe, expect, it } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MAX_SOCKET_PATH_BYTES, controlRequest, startControlServer } from "../src/control";

describe("control socket", () => {
    it("relays stop-sending and lands to every worker, with the land filters", async () => {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ctl-"));
        const socket = path.join(dir, "c.sock");
        const seen: unknown[] = [];
        const worker = (land: string) => ({
            control: async (command: any) => {
                seen.push(command);
                return command.name === "stopSending"
                    ? { stopped: true }
                    : { connections: [{ key: land, land, player: "0", open: true, reconnected: false, decodeErrors: 0 }] };
            }
        });
        const server = await startControlServer(socket, [worker("r0"), worker("r1")]);
        try {
            expect(await controlRequest(socket, "POST", "/stop-sending")).toEqual({ stoppedWorkers: 2 });
            const lands = await controlRequest<{ connections: Array<{ land: string }> }>(socket, "GET", "/lands?land=r1&states=r1");
            expect(lands.connections.map((c) => c.land)).toEqual(["r0", "r1"]);
            expect(seen.at(-1)).toEqual({ name: "lands", only: ["r1"], withStates: ["r1"] });
            await expect(controlRequest(socket, "GET", "/nope")).rejects.toThrow(/HTTP 404/);
        } finally {
            await server.close();
        }
    });

    it("refuses a socket path longer than every platform takes", async () => {
        const long = path.join(os.tmpdir(), "x".repeat(MAX_SOCKET_PATH_BYTES));
        await expect(startControlServer(long, [])).rejects.toThrow(/at most 103/);
    });
});
