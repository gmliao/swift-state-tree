import { describe, it, expect, vi, afterEach } from "vitest";
import { WorkerClient } from "../src/worker";
import type { SlowReadWindow, WebSocketLike } from "../src/worker";
import { summarizeCloses } from "../src/run";

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    terminated = false;
    paused: number[] = [];
    resumed: number[] = [];
    closeCalls: number[] = [];
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(): void {}
    close(code?: number): void {
        this.closeCalls.push(code ?? 0);
    }
    terminate(): void {
        this.terminated = true;
    }
    pause(): void {
        this.paused.push(Date.now());
    }
    resume(): void {
        this.resumed.push(Date.now());
    }
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
    frame(): void {
        this.emit("message", JSON.stringify({ kind: "actionResponse", payload: { actionResponse: { requestID: "x" } } }));
    }
}

const JOINED = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });

function joinedClient(socket: FakeSocket, options: { staleAfterMs?: number; slowRead?: SlowReadWindow }): WorkerClient {
    const client = new WorkerClient(
        { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
        { createSocket: () => socket, now: () => Date.now(), ...options }
    );
    client.connect();
    socket.emit("open");
    socket.emit("message", JOINED);
    return client;
}

afterEach(() => {
    vi.useRealTimers();
});

describe("stale check (--stale-after)", () => {
    it("abandons a joined connection silent for the threshold, as a client-initiated disconnect", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const client = joinedClient(socket, { staleAfterMs: 10_000 });
        vi.advanceTimersByTime(9_000);
        socket.frame();
        vi.advanceTimersByTime(9_999);
        expect(client.checkStale()).toBe(false);
        vi.advanceTimersByTime(1);
        expect(client.checkStale()).toBe(true);
        expect(socket.terminated).toBe(true);
        expect(client.isUsable()).toBe(false);

        const { closes, disconnectCount } = client.getSession().metrics;
        expect(closes).toHaveLength(1);
        expect(closes[0]).toMatchObject({ initiator: "client", cause: "stale", silentForMs: 10_000, reason: "stale", joined: true });
        expect(disconnectCount).toBe(1);
        // The socket's late close event doesn't add a second record.
        socket.emit("close", 1006);
        expect(client.getSession().metrics.closes).toHaveLength(1);
        expect(summarizeCloses(closes)).toMatchObject({ clientInitiated: 1, serverInitiated: 0, stale: 1 });
    });

    it("is off without --stale-after, and doesn't run before the join", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const off = joinedClient(new FakeSocket(), {});
        vi.advanceTimersByTime(60_000);
        expect(off.checkStale()).toBe(false);

        const socket = new FakeSocket();
        const pending = new WorkerClient(
            { serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
            { createSocket: () => socket, now: () => Date.now(), staleAfterMs: 1_000, joinTimeoutMs: 60_000 }
        );
        pending.connect();
        socket.emit("open");
        vi.advanceTimersByTime(5_000);
        expect(pending.checkStale()).toBe(false);
    });
});

describe("slow reader (--slow-read)", () => {
    it("pauses reading for the window, suspends the stale check, and restarts its timer on resume", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const window = { startAt: 1_002_000, endAt: 1_032_000 };
        const client = joinedClient(socket, { staleAfterMs: 10_000, slowRead: window });

        vi.advanceTimersByTime(1_999);
        expect(socket.paused).toEqual([]);
        vi.advanceTimersByTime(1);
        expect(socket.paused).toEqual([window.startAt]);
        expect(client.isReadPaused()).toBe(true);

        // 30 s without a frame, three times the threshold: no stale close while paused.
        vi.advanceTimersByTime(29_999);
        expect(client.checkStale()).toBe(false);
        vi.advanceTimersByTime(1);
        expect(socket.resumed).toEqual([window.endAt]);
        expect(client.isReadPaused()).toBe(false);

        // The timer restarted at the resume, not at the last frame before the pause.
        vi.advanceTimersByTime(9_999);
        expect(client.checkStale()).toBe(false);
        socket.emit("close", 4008, Buffer.from("backlog"));
        const [record] = client.getSession().metrics.closes;
        expect(record).toMatchObject({
            initiator: "server",
            code: 4008,
            slowReader: true,
            readPausedAt: window.startAt,
            readResumedAt: window.endAt
        });
        expect(record.cause).toBeUndefined();
    });

    it("a connection joining inside the window pauses at once; one joining after it never pauses", () => {
        vi.useFakeTimers({ now: 1_010_000 });
        const late = new FakeSocket();
        joinedClient(late, { slowRead: { startAt: 1_000_000, endAt: 1_020_000 } });
        vi.advanceTimersByTime(0);
        expect(late.paused).toEqual([1_010_000]);
        vi.advanceTimersByTime(10_000);
        expect(late.resumed).toEqual([1_020_000]);

        const after = new FakeSocket();
        joinedClient(after, { slowRead: { startAt: 1_000_000, endAt: 1_005_000 } });
        vi.advanceTimersByTime(30_000);
        expect(after.paused).toEqual([]);
    });

    it("resumes reading before a client close, so the close handshake can finish", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const client = joinedClient(socket, { slowRead: { startAt: 1_000_000, endAt: 1_100_000 } });
        vi.advanceTimersByTime(1_000);
        expect(client.isReadPaused()).toBe(true);
        void client.close("shutdown");
        expect(socket.resumed).toEqual([1_001_000]);
        expect(socket.closeCalls).toEqual([1000]);
        socket.emit("close", 1000);
        expect(client.getSession().metrics.closes[0]).toMatchObject({
            initiator: "client",
            slowReader: true,
            readPausedAt: 1_000_000,
            readResumedAt: 1_001_000
        });
    });
});
