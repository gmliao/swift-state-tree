import { describe, it, expect, vi, afterEach } from "vitest";
import { WorkerClient, processSocketCounts } from "../src/worker";
import type { ReconnectOption, WebSocketLike } from "../src/worker";
import type { SampleRecord } from "../src/samples-sink";

// #490: every socket writes one `socket` record with its TCP local port, so the analysis can pair
// each server session (its `sessionOpened` peer port) with the client socket it was, including
// a reconnect attempt the tool gave up on before the server's answer arrived.

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    terminated = false;
    sent: Array<string | Uint8Array> = [];
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }
    close(): void {
        this.emit("close", 1000);
    }
    terminate(): void {
        this.terminated = true;
    }
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
}

const JOINED = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
const REFUSED = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: false, reason: "full" } } });
const T0 = 1_000_000;

/** A client whose sockets connect over TCP at once on ports 58842, 58843, ... unless `noTcp` names the socket's index. */
function makeClient(reconnect: ReconnectOption | undefined, noTcp: Set<number> = new Set()) {
    const sockets: FakeSocket[] = [];
    const records: SampleRecord[] = [];
    const client = new WorkerClient(
        { key: "room-0-s1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-0", playerId: "p5-r0-s1", actions: [] },
        {
            createSocket: (_url, onTcpConnect) => {
                const socket = new FakeSocket();
                if (!noTcp.has(sockets.length)) onTcpConnect?.(58842 + sockets.length, "10.201.0.2");
                sockets.push(socket);
                return socket;
            },
            now: () => Date.now(),
            reconnect,
            samples: (r) => records.push(r)
        }
    );
    const last = () => sockets[sockets.length - 1];
    const socketRecords = () => records.filter((r) => r.r === "socket");
    return { client, sockets, last, records, socketRecords };
}

afterEach(() => {
    vi.useRealTimers();
});

describe("socket records (#490)", () => {
    it("an attempt abandoned before the WebSocket opened: attemptTimeout with its port, no open, no join", () => {
        // r1's never-joined shape: the server's 101 never arrived, the tool terminated the
        // attempt at its 5 s timeout, and the server later closed the session by its pong timeout.
        vi.useFakeTimers({ now: T0 });
        const { client, sockets, last, socketRecords } = makeClient({ untilAt: T0 + 600_000 });
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        vi.advanceTimersByTime(10_000);
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(2);
        vi.advanceTimersByTime(5_000);
        expect(sockets[1].terminated).toBe(true);
        // Its late close event is ignored: still one record for that socket.
        sockets[1].emit("close", 1006);
        expect(socketRecords()).toEqual([
            { r: "socket", k: "room-0-s1", localPort: 58842, localAddress: "10.201.0.2", connectedAt: T0, openedAt: T0, joinedAt: T0, endedAt: T0 + 10_000, end: "closed" },
            { r: "socket", k: "room-0-s1", localPort: 58843, localAddress: "10.201.0.2", connectedAt: T0 + 11_000, endedAt: T0 + 16_000, end: "attemptTimeout" }
        ]);
    });

    it("an attempt that opened but got no JoinResponse: attemptTimeout with openedAt", () => {
        // r1's joined-4011 shape: the server joined it, but its JoinResponse never arrived.
        vi.useFakeTimers({ now: T0 });
        const { client, last, socketRecords } = makeClient({ untilAt: T0 + 600_000 });
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        vi.advanceTimersByTime(400);
        last().emit("open");
        vi.advanceTimersByTime(4_600);
        expect(socketRecords()[1]).toEqual({
            r: "socket", k: "room-0-s1", localPort: 58843, localAddress: "10.201.0.2", connectedAt: T0 + 1_000, openedAt: T0 + 1_400, endedAt: T0 + 6_000, end: "attemptTimeout"
        });
    });

    it("an attempt closed before it joined: attemptClosed; a refused one: attemptRejected", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, last, socketRecords } = makeClient({ untilAt: T0 + 600_000 });
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        last().emit("close", 4008);
        vi.advanceTimersByTime(1_000);
        last().emit("open");
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        last().emit("open");
        last().emit("message", REFUSED);
        expect(socketRecords().map((r) => (r as any).end)).toEqual(["closed", "attemptClosed", "attemptRejected"]);
    });

    it("a first join refused, then closed by the tool: joinRejected; never answered: joinTimeout", () => {
        vi.useFakeTimers({ now: T0 });
        const refused = makeClient(undefined);
        refused.client.connect();
        refused.last().emit("open");
        refused.last().emit("message", REFUSED);
        void refused.client.close("phase end");
        expect(refused.socketRecords().map((r) => (r as any).end)).toEqual(["joinRejected"]);

        const unanswered = makeClient(undefined);
        unanswered.client.connect();
        unanswered.last().emit("open");
        unanswered.client.noteJoinUnansweredAtPhaseEnd();
        void unanswered.client.close("phase end");
        expect(unanswered.socketRecords().map((r) => (r as any).end)).toEqual(["joinTimeout"]);
    });

    it("the tool's close of a connection still joining: phaseEnd", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, last, socketRecords } = makeClient(undefined);
        client.connect();
        last().emit("open");
        void client.close("transition");
        expect(socketRecords().map((r) => (r as any).end)).toEqual(["phaseEnd"]);
    });

    it("a socket whose TCP connection never completed: a record without localPort", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, last, socketRecords } = makeClient({ untilAt: T0 + 600_000 }, new Set([1]));
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        last().emit("close", 1006);
        vi.advanceTimersByTime(6_000);
        expect(socketRecords()[1]).toEqual({ r: "socket", k: "room-0-s1", endedAt: T0 + 6_000, end: "attemptTimeout" });
    });

    it("the tool's close during a reconnect attempt writes that socket's one record: phaseEnd", () => {
        // cancelReconnect drops the attempt's socket without a close record; it still gets its
        // socket record, so created - recorded stays 0 (Review S1).
        vi.useFakeTimers({ now: T0 });
        const before = processSocketCounts();
        const { client, sockets, last, socketRecords } = makeClient({ untilAt: T0 + 600_000 });
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        last().emit("open");
        expect(sockets).toHaveLength(2);
        void client.close("shutdown");
        expect(sockets[1].terminated).toBe(true);
        expect(socketRecords().map((r) => (r as any).end)).toEqual(["closed", "phaseEnd"]);
        const after = processSocketCounts();
        expect(after.created - before.created).toBe(2);
        expect(after.recorded - before.recorded).toBe(2);
    });

    it("every socket created writes exactly one record", () => {
        vi.useFakeTimers({ now: T0 });
        const before = processSocketCounts();
        const { client, sockets, last, socketRecords } = makeClient({ untilAt: T0 + 30_000 });
        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        last().emit("open");
        last().emit("close", 1006); // attemptClosed
        vi.advanceTimersByTime(1_000);
        vi.advanceTimersByTime(5_000); // attemptTimeout
        vi.advanceTimersByTime(1_000);
        last().emit("open");
        last().emit("message", JOINED);
        void client.close("shutdown");
        const after = processSocketCounts();
        expect(after.created - before.created).toBe(sockets.length);
        expect(after.recorded - before.recorded).toBe(sockets.length);
        expect(socketRecords()).toHaveLength(sockets.length);
        expect(new Set(socketRecords().map((r) => (r as any).localPort)).size).toBe(sockets.length);
    });
});
