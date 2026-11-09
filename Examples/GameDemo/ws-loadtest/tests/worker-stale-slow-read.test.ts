import { describe, it, expect, vi, afterEach } from "vitest";
import { WorkerClient } from "../src/worker";
import type { SlowReadWindow, WebSocketLike } from "../src/worker";
import { summarizeCloses } from "../src/run";

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    terminated = false;
    /** Bytes the TCP socket has read (`bytesReceived`), set by a test. */
    bytes = 0;
    sent: (string | Uint8Array)[] = [];
    paused: number[] = [];
    resumed: number[] = [];
    closeCalls: number[] = [];
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }
    bytesReceived(): number {
        return this.bytes;
    }
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

    it("a slow reader that reconnects inside the window pauses again at once, and its record is its own", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const sockets: FakeSocket[] = [];
        const window = { startAt: 1_000_000, endAt: 1_100_000 };
        const client = new WorkerClient(
            { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
            {
                createSocket: () => {
                    const socket = new FakeSocket();
                    sockets.push(socket);
                    return socket;
                },
                now: () => Date.now(),
                slowRead: window,
                reconnect: { untilAt: 1_200_000 }
            }
        );
        client.connect();
        sockets[0].emit("open");
        sockets[0].emit("message", JOINED);
        vi.advanceTimersByTime(0);
        expect(sockets[0].paused).toEqual([1_000_000]);

        vi.advanceTimersByTime(20_000);
        sockets[0].emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(2);
        sockets[1].emit("open");
        sockets[1].emit("message", JOINED);
        vi.advanceTimersByTime(0);
        expect(sockets[1].paused).toEqual([1_021_000]);
        expect(client.isReadPaused()).toBe(true);
        vi.advanceTimersByTime(79_000);
        expect(sockets[1].resumed).toEqual([window.endAt]);

        sockets[1].emit("close", 4008, Buffer.from("backlog"));
        const [first, second] = client.getSession().metrics.closes;
        expect(first).toMatchObject({ slowReader: true, readPausedAt: 1_000_000 });
        expect(first.readResumedAt).toBeUndefined();
        expect(second).toMatchObject({ slowReader: true, readPausedAt: 1_021_000, readResumedAt: window.endAt });
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

describe("raw samples (--samples-dir)", () => {
    it("writes joins, every action's outcome, updates, move events and closes for one connection", async () => {
        const fs = await import("node:fs");
        const os = await import("node:os");
        const path = await import("node:path");
        const { SampleSink, readSamples } = await import("../src/samples-sink");
        const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "ws-samples-")), "w0.ndjson.gz");
        const sink = new SampleSink(file);
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const client = new WorkerClient(
            { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p1", actions: [] },
            { createSocket: () => socket, now: () => Date.now(), samples: sink.write }
        );
        client.connect();
        socket.emit("open");
        socket.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true, playerID: "guest-7" } } }));
        const session = client.getSession();
        session.recordSend("a1", 1_000_000, 1_000_002);
        session.recordSend("a2", 1_000_010);
        vi.advanceTimersByTime(30);
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "a1" }, Date.now());
        session.handleDecodedMessage({ type: "stateUpdate" }, 1_000_040, 120);
        session.handleDecodedMessage({ type: "stateUpdate" }, 1_000_140, 90);
        session.inputLatency.recordSent({ x: 1, y: 2 }, 1_000_050);
        session.inputLatency.observe({ players: { p1: { position: { v: { x: 1, y: 2 } } } } }, 1_000_150);
        session.inputLatency.recordSent({ x: 3, y: 4 }, 1_000_160);
        socket.emit("close", 1006);
        session.takePending();
        vi.useRealTimers();
        await sink.close();

        const records = readSamples(file);
        expect(records.map((r) => r.r)).toEqual(["join", "rtt", "update", "update", "input", "input", "close", "rtt"]);
        expect(records[0]).toMatchObject({ k: "k1", land: "room-1", player: "p1", serverPlayer: "guest-7", t: 1_000_000 });
        expect(records[1]).toEqual({ r: "rtt", k: "k1", intendedAt: 1_000_000, sentAt: 1_000_002, respondedAt: 1_000_030, outcome: "applied" });
        expect(records[2]).toEqual({ r: "update", k: "k1", t: 1_000_040, gapMs: null, bytes: 120 });
        expect(records[3]).toEqual({ r: "update", k: "k1", t: 1_000_140, gapMs: 100, bytes: 90 });
        expect(records[4]).toEqual({ r: "input", k: "k1", sentAt: 1_000_050, seenAt: 1_000_150 });
        // The server closed it, so the move event pending then is closedBeforeSeen.
        expect(records[5]).toEqual({ r: "input", k: "k1", sentAt: 1_000_160, seenAt: null, end: "closedBeforeSeen" });
        expect(records[6]).toMatchObject({ r: "close", player: "p1", initiator: "server", code: 1006, key: "k1" });
        // The unanswered action, taken at the phase end after its connection closed.
        expect(records[7]).toEqual({
            r: "rtt", k: "k1", intendedAt: 1_000_010, sentAt: 1_000_010, respondedAt: null, end: "closed", closedAt: 1_000_030
        });
        expect(sink.count).toBe(8);
    });
});

describe("slow reader: silence by bytes on the socket (--slow-read)", () => {
    it("a slow reader receiving bytes it hasn't handled yet isn't stale; one whose bytes stop is", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        // The window ended before the join: no pause, the stale check runs on the slow reader.
        const client = joinedClient(socket, { staleAfterMs: 10_000, slowRead: { startAt: 0, endAt: 1 } });
        expect(client.checkStale()).toBe(false);
        // Bytes keep arriving, no frame is handled (a backlog still being drained).
        for (let i = 1; i <= 3; i++) {
            vi.advanceTimersByTime(9_000);
            socket.bytes += 4_096;
            expect(client.checkStale()).toBe(false);
        }
        // The bytes stop: stale after the threshold, from the last change seen.
        vi.advanceTimersByTime(9_999);
        expect(client.checkStale()).toBe(false);
        vi.advanceTimersByTime(1);
        expect(client.checkStale()).toBe(true);
        expect(client.getSession().metrics.closes[0]).toMatchObject({ cause: "stale", slowReader: true });
    });

    it("without --slow-read, bytes on the socket don't count: only handled frames do", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const client = joinedClient(socket, { staleAfterMs: 10_000 });
        expect(client.checkStale()).toBe(false);
        vi.advanceTimersByTime(9_000);
        socket.bytes += 4_096;
        expect(client.checkStale()).toBe(false);
        vi.advanceTimersByTime(1_000);
        socket.bytes += 4_096;
        expect(client.checkStale()).toBe(true);
    });
});

describe("per-connection resyncs and acks (#332)", () => {
    const joinedWithSequence = JSON.stringify({
        kind: "joinResponse",
        payload: { joinResponse: { success: true, encoding: "json", stateUpdateFeatures: ["syncSequence"] } }
    });
    const acks = (socket: FakeSocket) => socket.sent.filter((d) => typeof d === "string" && d.startsWith("[108,"));

    it("a slow reader's close names its resyncs, its acks, and the acks it sent while paused; a resync line per resync", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const lines: any[] = [];
        const window = { startAt: 1_010_000, endAt: 1_030_000 };
        const client = new WorkerClient(
            { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
            {
                createSocket: () => socket,
                now: () => Date.now(),
                slowRead: window,
                samples: (line: any) => lines.push(line)
            }
        );
        client.connect();
        socket.emit("open");
        socket.emit("message", joinedWithSequence);
        socket.emit("message", JSON.stringify([1, 5]));
        vi.advanceTimersByTime(10_000);
        const beforePause = acks(socket).length;
        expect(beforePause).toBeGreaterThan(0);
        // Paused: the unchanged sequence goes out every second.
        expect(client.isReadPaused()).toBe(true);
        vi.advanceTimersByTime(5_000);
        // A resync read after the pause ends (its frame waited in the socket).
        vi.advanceTimersByTime(15_000);
        socket.emit("message", JSON.stringify([3, 9]));
        socket.emit("close", 4010, Buffer.from("slow consumer"));
        const close = client.getSession().metrics.closes[0];
        expect(close.resyncs).toBe(1);
        expect(close.acksSent).toBe(acks(socket).length);
        expect(close.acksSentWhilePaused).toBe(20);
        expect(close.acksSentWhilePaused).toBeLessThan(close.acksSent!);
        expect(lines.filter((l) => l.r === "resync")).toEqual([{ r: "resync", k: "k1", t: 1_030_000, player: "p" }]);
    });

    it("tags full views on update samples (firstSync, resync), not diffs; the close names the last acked and received seq", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const lines: any[] = [];
        const client = new WorkerClient(
            { key: "k1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-1", playerId: "p", actions: [] },
            { createSocket: () => socket, now: () => Date.now(), samples: (line: any) => lines.push(line) }
        );
        client.connect();
        socket.emit("open");
        socket.emit("message", joinedWithSequence);
        socket.emit("message", JSON.stringify([1, 5]));
        vi.advanceTimersByTime(100);
        socket.emit("message", JSON.stringify([2, 6]));
        vi.advanceTimersByTime(100);
        socket.emit("message", JSON.stringify([3, 9]));
        vi.advanceTimersByTime(100);
        socket.emit("message", JSON.stringify([2, 10]));
        socket.emit("close", 1000);
        expect(lines.filter((l) => l.r === "update").map((l) => l.full)).toEqual(["firstSync", undefined, "resync", undefined]);
        const close = client.getSession().metrics.closes[0];
        // The resync was acked at once (9); 10 arrived after the last ack.
        expect(close).toMatchObject({ lastAckedSeq: 9, lastReceivedSeq: 10 });
    });

    it("a connection without syncSequence carries no resync or ack fields", () => {
        vi.useFakeTimers({ now: 1_000_000 });
        const socket = new FakeSocket();
        const client = joinedClient(socket, {});
        socket.emit("close", 1000);
        const close = client.getSession().metrics.closes[0];
        expect(close.resyncs).toBeUndefined();
        expect(close.acksSent).toBeUndefined();
        expect(close.acksSentWhilePaused).toBeUndefined();
    });
});
