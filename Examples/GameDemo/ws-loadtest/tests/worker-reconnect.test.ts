import { describe, it, expect, vi, afterEach } from "vitest";
import { WorkerClient } from "../src/worker";
import type { ReconnectOption, WebSocketLike } from "../src/worker";

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
    close(): void {}
    terminate(): void {
        this.terminated = true;
    }
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
}

const JOINED = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
const FIRST_SYNC = JSON.stringify({ type: "firstSync", patches: [] });
const DIFF = JSON.stringify({ type: "diff", patches: [] });
const T0 = 1_000_000;

function makeClient(reconnect: ReconnectOption | undefined, extra: { staleAfterMs?: number } = {}) {
    const sockets: FakeSocket[] = [];
    const client = new WorkerClient(
        { key: "room-0-s1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-0", playerId: "p5-r0-s1", actions: [] },
        {
            createSocket: () => {
                const socket = new FakeSocket();
                sockets.push(socket);
                return socket;
            },
            now: () => Date.now(),
            reconnect,
            ...extra
        }
    );
    const last = () => sockets[sockets.length - 1];
    const join = () => {
        last().emit("open");
        last().emit("message", JOINED);
    };
    client.connect();
    join();
    return { client, sockets, last, join };
}

afterEach(() => {
    vi.useRealTimers();
});

describe("reconnect (--reconnect on-server-close)", () => {
    it("after a server close, waits 1 s, joins the same land with the same key, and times the recovery", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, sockets, last, join } = makeClient({ untilAt: T0 + 600_000 });
        vi.advanceTimersByTime(10_000);
        last().emit("close", 1006);
        expect(client.isUsable()).toBe(false);
        expect(client.isReconnecting()).toBe(true);

        vi.advanceTimersByTime(999);
        expect(sockets).toHaveLength(1);
        vi.advanceTimersByTime(1);
        expect(sockets).toHaveLength(2);
        vi.advanceTimersByTime(30);
        last().emit("open");
        expect(String(last().sent[0])).toContain('"landInstanceId":"room-0"');
        vi.advanceTimersByTime(20);
        last().emit("message", JOINED);
        expect(client.isUsable()).toBe(true);
        expect(client.getKey()).toBe("room-0-s1");
        vi.advanceTimersByTime(40);
        last().emit("message", FIRST_SYNC);

        const { closes, reconnects, disconnectCount } = client.getSession().metrics;
        expect(closes).toHaveLength(1);
        expect(disconnectCount).toBe(1);
        expect(reconnects).toEqual([
            {
                key: "room-0-s1", landInstanceId: "room-0", playerId: "p5-r0-s1",
                cause: "server", closeCode: 1006, closedAt: T0 + 10_000, attempts: 1, outcome: "recovered",
                attemptStartedAt: T0 + 11_000, openedAt: T0 + 11_030, joinedAt: T0 + 11_050, firstSyncAt: T0 + 11_090,
                firstSyncBytes: FIRST_SYNC.length, downtimeMs: 1_090, connectMs: 30, joinToFirstSyncMs: 40
            }
        ]);
        expect(client.isReconnecting()).toBe(false);
        // Joined twice: the outage is not an active span.
        expect(client.activeIntervals(T0, T0 + 20_000)).toEqual([[T0, T0 + 10_000], [T0 + 11_050, T0 + 20_000]]);
        // A later frame isn't a second firstSync.
        last().emit("message", FIRST_SYNC);
        expect(client.getSession().metrics.reconnects).toHaveLength(1);
    });

    it("retries serially after failed attempts, without close records, and gives up at untilAt", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, sockets, last } = makeClient({ untilAt: T0 + 9_500 });
        last().emit("close", 4008);
        vi.advanceTimersByTime(1_000);
        // Attempt 1: refused before the join.
        last().emit("open");
        last().emit("close", 1006);
        expect(sockets).toHaveLength(2);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(3);
        // Attempt 2: never answers; abandoned after 5 s, then the next 1 s later.
        last().emit("open");
        vi.advanceTimersByTime(4_999);
        expect(sockets[2].terminated).toBe(false);
        vi.advanceTimersByTime(1);
        expect(sockets[2].terminated).toBe(true);
        // Its late close event is ignored.
        sockets[2].emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(4);
        // Attempt 3 fails at T0 + 8000; the next would start at T0 + 9000, still before untilAt.
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(5);
        // Attempt 4 fails at T0 + 9000; T0 + 10000 is past untilAt: give up.
        last().emit("close", 1006);
        vi.advanceTimersByTime(10_000);
        expect(sockets).toHaveLength(5);

        const { closes, reconnects, disconnectCount } = client.getSession().metrics;
        expect(closes).toHaveLength(1);
        expect(disconnectCount).toBe(1);
        expect(reconnects).toHaveLength(1);
        expect(reconnects[0]).toMatchObject({ cause: "server", closeCode: 4008, attempts: 4, outcome: "gaveUp" });
        expect(reconnects[0].attemptStartedAt).toBeUndefined();
        expect(client.takeJoinFailure()).toBeUndefined();
        expect(client.isReconnecting()).toBe(false);
    });

    it("a stale close reconnects too, with cause stale", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, sockets, join, last } = makeClient({ untilAt: T0 + 600_000 }, { staleAfterMs: 10_000 });
        vi.advanceTimersByTime(10_000);
        expect(client.checkStale()).toBe(true);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(2);
        join();
        // The abandoned socket's late events arrive now: they're the old connection's, ignored.
        sockets[0].emit("message", FIRST_SYNC);
        sockets[0].emit("close", 1006);
        expect(client.isUsable()).toBe(true);
        expect(client.getSession().metrics.closes).toHaveLength(1);
        expect(client.getSession().metrics.reconnects).toEqual([]);
        // The new connection's stale timer starts at its join.
        vi.advanceTimersByTime(9_999);
        expect(client.checkStale()).toBe(false);
        last().emit("message", FIRST_SYNC);
        expect(client.getSession().metrics.reconnects[0]).toMatchObject({ cause: "stale", outcome: "recovered" });
    });

    it("a joined reconnect closed before its firstSync is joinedNoFirstSync, and starts another", () => {
        vi.useFakeTimers({ now: T0 });
        const { client, sockets, join, last } = makeClient({ untilAt: T0 + 600_000 });
        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        join();
        last().emit("message", DIFF);
        last().emit("close", 1006);
        const [first] = client.getSession().metrics.reconnects;
        expect(first).toMatchObject({ outcome: "joinedNoFirstSync", attempts: 1, connectMs: 0 });
        expect(first.downtimeMs).toBeUndefined();
        expect(client.isReconnecting()).toBe(true);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(3);
        expect(client.getSession().metrics.closes).toHaveLength(2);
    });

    it("the tool's close cancels a reconnect, waiting or mid-attempt", async () => {
        vi.useFakeTimers({ now: T0 });
        const waiting = makeClient({ untilAt: T0 + 600_000 });
        waiting.last().emit("close", 1006);
        await waiting.client.close("phase change");
        vi.advanceTimersByTime(5_000);
        expect(waiting.sockets).toHaveLength(1);
        expect(waiting.client.getSession().metrics.reconnects).toMatchObject([{ outcome: "cancelled", attempts: 0 }]);

        const midAttempt = makeClient({ untilAt: T0 + 600_000 });
        midAttempt.last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        midAttempt.last().emit("open");
        await midAttempt.client.close("shutdown");
        expect(midAttempt.sockets[1].terminated).toBe(true);
        vi.advanceTimersByTime(10_000);
        expect(midAttempt.sockets).toHaveLength(2);
        const metrics = midAttempt.client.getSession().metrics;
        expect(metrics.reconnects).toMatchObject([{ outcome: "cancelled", attempts: 1 }]);
        expect(metrics.closes).toHaveLength(1);
    });

    it("doesn't reconnect without the option, after a client close, or a connection that never joined", () => {
        vi.useFakeTimers({ now: T0 });
        const off = makeClient(undefined);
        off.last().emit("close", 1006);
        vi.advanceTimersByTime(10_000);
        expect(off.sockets).toHaveLength(1);

        const sockets: FakeSocket[] = [];
        const neverJoined = new WorkerClient(
            { serverUrl: "ws://x", landType: "t", landInstanceId: "room-0", playerId: "p", actions: [] },
            { createSocket: () => { const s = new FakeSocket(); sockets.push(s); return s; }, reconnect: { untilAt: T0 + 600_000 } }
        );
        neverJoined.connect();
        sockets[0].emit("open");
        sockets[0].emit("close", 1006);
        vi.advanceTimersByTime(10_000);
        expect(sockets).toHaveLength(1);
        expect(neverJoined.takeJoinFailure()?.reason).toBe("closed");
    });
});
