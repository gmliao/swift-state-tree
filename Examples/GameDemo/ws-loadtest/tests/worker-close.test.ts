import { describe, it, expect } from "vitest";
import { WorkerClient } from "../src/worker";
import type { WebSocketLike } from "../src/worker";

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    closeCalls: Array<[number | undefined, string | undefined]> = [];
    terminated = false;
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(): void {}
    close(code?: number, reason?: string): void {
        this.closeCalls.push([code, reason]);
    }
    terminate(): void {
        this.terminated = true;
    }
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
}

function makeClient(socket: FakeSocket): WorkerClient {
    const client = new WorkerClient(
        { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
        { createSocket: () => socket, now: () => 42 }
    );
    client.connect();
    socket.emit("open");
    return client;
}

describe("WorkerClient close", () => {
    it("sends a close frame and records a client-initiated close when the handshake ends", async () => {
        const socket = new FakeSocket();
        const client = makeClient(socket);
        const done = client.close("phase change");
        expect(socket.closeCalls).toEqual([[1000, "phase change"]]);
        expect(client.isUsable()).toBe(false);
        socket.emit("close", 1000, Buffer.from("phase change"));
        await done;
        const { closes, disconnectCount } = client.getSession().metrics;
        expect(closes).toEqual([
            { t: 42, key: "k1", landInstanceId: "room-1", initiator: "client", code: 1000, reason: "phase change", joined: false }
        ]);
        expect(disconnectCount).toBe(0);
    });

    it("terminates and marks the close forced when the handshake times out", async () => {
        const socket = new FakeSocket();
        const client = makeClient(socket);
        await client.close("shutdown", 20);
        expect(socket.terminated).toBe(true);
        const [record] = client.getSession().metrics.closes;
        expect(record).toMatchObject({ initiator: "client", forced: true });
        // A late close event after the timeout is ignored.
        socket.emit("close", 1006);
        expect(client.getSession().metrics.closes).toHaveLength(1);
    });

    it("counts a close it didn't ask for as a server-initiated disconnect", () => {
        const socket = new FakeSocket();
        const client = makeClient(socket);
        socket.emit("close", 1006, Buffer.from(""));
        const { closes, disconnectCount } = client.getSession().metrics;
        expect(closes[0]).toMatchObject({ initiator: "server", code: 1006 });
        expect(disconnectCount).toBe(1);
        expect(client.isUsable()).toBe(false);
    });
});
