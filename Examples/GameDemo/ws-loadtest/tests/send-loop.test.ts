import { describe, it, expect, vi, afterEach } from "vitest";
import { SendSchedule, runSendLoop, type SendTarget } from "../src/send-schedule";
import { WorkerClient } from "../src/worker";
import type { WebSocketLike } from "../src/worker";

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(): void {}
    close(): void {}
    terminate(): void {}
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
}

/** A connection the test joins and closes by hand. */
class FakeTarget implements SendTarget {
    usable = false;
    private listeners = new Set<(at: number) => void>();
    isUsable(): boolean {
        return this.usable;
    }
    onJoined(callback: (at: number) => void): () => void {
        this.listeners.add(callback);
        if (this.usable) callback(Date.now());
        return () => this.listeners.delete(callback);
    }
    join(): void {
        this.usable = true;
        this.listeners.forEach((callback) => callback(Date.now()));
    }
}

const JOINED = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
const T0 = 1_000_000;
const PERIOD_MS = 100;
// Off the advance boundaries, so a window holds exactly its slots.
const OFFSET_MS = 50;

afterEach(() => {
    vi.useRealTimers();
});

describe("runSendLoop", () => {
    it("resumes at the configured rate after a reconnect's join, without sending the outage's slots", () => {
        vi.useFakeTimers({ now: T0 });
        const sockets: FakeSocket[] = [];
        const client = new WorkerClient(
            { key: "room-0-s1", serverUrl: "ws://x", landType: "t", landInstanceId: "room-0", playerId: "p1", actions: [] },
            {
                createSocket: () => {
                    const socket = new FakeSocket();
                    sockets.push(socket);
                    return socket;
                },
                now: () => Date.now(),
                reconnect: { untilAt: T0 + 600_000 }
            }
        );
        const last = () => sockets[sockets.length - 1];
        const sent: number[] = [];
        const stop = runSendLoop(client, new SendSchedule(T0, PERIOD_MS, OFFSET_MS), T0, T0 + 60_000, (at) => sent.push(at));

        client.connect();
        last().emit("open");
        last().emit("message", JOINED);
        vi.advanceTimersByTime(10_000);
        expect(sent).toHaveLength(100);

        last().emit("close", 1006);
        vi.advanceTimersByTime(1_000);
        expect(sockets).toHaveLength(2);
        last().emit("open");
        vi.advanceTimersByTime(30);
        last().emit("message", JOINED);
        expect(client.isUsable()).toBe(true);
        const rejoinedAt = Date.now();
        expect(sent).toHaveLength(100);

        vi.advanceTimersByTime(5_000);
        const resumed = sent.slice(100);
        expect(resumed).toHaveLength(50);
        expect(resumed[0]).toBeGreaterThanOrEqual(rejoinedAt);
        stop();
    });

    it("keeps exactly one timer when a join repeats, none while closed, and stops on stop()", () => {
        vi.useFakeTimers({ now: T0 });
        const target = new FakeTarget();
        const sent: number[] = [];
        const stop = runSendLoop(target, new SendSchedule(T0, PERIOD_MS, OFFSET_MS), T0, T0 + 60_000, (at) => sent.push(at));
        expect(vi.getTimerCount()).toBe(0);

        target.join();
        target.join();
        expect(vi.getTimerCount()).toBe(1);
        vi.advanceTimersByTime(1_000);
        expect(sent).toHaveLength(10);
        expect(vi.getTimerCount()).toBe(1);

        // Closed: the pending timer fires, sends nothing and doesn't re-arm.
        target.usable = false;
        vi.advanceTimersByTime(1_000);
        expect(sent).toHaveLength(10);
        expect(vi.getTimerCount()).toBe(0);

        target.join();
        expect(vi.getTimerCount()).toBe(1);
        vi.advanceTimersByTime(1_000);
        expect(sent).toHaveLength(20);

        stop();
        expect(vi.getTimerCount()).toBe(0);
        target.join();
        expect(vi.getTimerCount()).toBe(0);
    });
});
