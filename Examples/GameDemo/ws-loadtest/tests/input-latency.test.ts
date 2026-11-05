import { describe, it, expect } from "vitest";
import { encode as msgpackEncode, decode as msgpackDecode } from "@msgpack/msgpack";
import {
    INPUT_LATENCY_MAX_PENDING,
    INPUT_LATENCY_TIMEOUT_MS,
    InputLatencyTracker,
    echoPointOf,
    forEachPoint,
    measureInputLatency
} from "../src/input-latency";

const pos = (x: number, y: number) => ({ v: { x, y } });

describe("echoPointOf", () => {
    it("takes the fixed-point point of a MoveTo or MoveViewer payload", () => {
        expect(echoPointOf({ target: pos(10_000, 20_000) })).toEqual({ x: 10_000, y: 20_000 });
        expect(echoPointOf({ position: pos(1, 2) })).toEqual({ x: 1, y: 2 });
    });

    it("ignores payloads without one, and non-integer coordinates", () => {
        expect(echoPointOf({})).toBeUndefined();
        expect(echoPointOf({ target: { v: { x: 1.5, y: 2 } } })).toBeUndefined();
        expect(echoPointOf({ target: { x: 1, y: 2 } })).toBeUndefined();
    });
});

describe("forEachPoint", () => {
    const collect = (raw: unknown) => {
        const out: string[] = [];
        forEachPoint(raw, (x, y) => out.push(`${x},${y}`));
        return out;
    };

    it("finds points in a messagepack 107 frame, nested in its state update", () => {
        // [107, [2, [pathHash, dynamicKey, op, value], ...], events], as the server sends it.
        const frame = msgpackDecode(msgpackEncode([107, [2, [234890857, [0, "p1"], 1, pos(36617, 70055)], [640249701, 1, 1, { degrees: -51195 }]], []]));
        expect(collect(frame)).toEqual(["36617,70055"]);
    });

    it("finds points in a plain per-player frame and in a jsonObject diff", () => {
        expect(collect([2, [3850929751, 0, 1, pos(23400, 26600)], [3850929751, 1, 1, pos(19800, 13800)]])).toEqual(["23400,26600", "19800,13800"]);
        const json = JSON.parse(JSON.stringify({ type: "diff", patches: [{ op: "replace", path: "/players/p1/targetPosition", value: pos(5, 6) }] }));
        expect(collect(json)).toEqual(["5,6"]);
    });

    it("finds a point inside a whole added player and inside a firstSync", () => {
        const added = { type: "diff", patches: [{ op: "add", path: "/players/p2", value: { health: 100, targetPosition: pos(7, 8), position: pos(1, 1) } }] };
        expect(collect(added).sort()).toEqual(["1,1", "7,8"]);
    });

    it("does not take a bare coordinate or a near-miss shape for a point", () => {
        expect(collect([2, [1, 0, 1, 36617], [2, 0, 1, { x: 36617, y: 70055 }], [3, 0, 1, { v: { x: 1 } }]])).toEqual([]);
    });
});

describe("InputLatencyTracker", () => {
    it("times an input from its send to the first frame that shows its point", () => {
        const t = new InputLatencyTracker();
        t.recordSent({ x: 10, y: 20 }, 1_000);
        t.observe([2, [1, 0, 1, pos(99, 99)]], 1_040); // another point: not ours
        t.observe([107, [2, [1, 0, 1, pos(10, 20)]], []], 1_090);
        t.observe([107, [2, [1, 0, 1, pos(10, 20)]], []], 1_140); // seen once only
        expect(t.metrics.latencyMs).toEqual([90]);
        expect(t.metrics.latencySentAt).toEqual([1_000]);
        expect(t.pendingCount).toBe(0);
    });

    it("drops the oldest pending input past the limit as superseded", () => {
        const t = new InputLatencyTracker();
        for (let i = 0; i <= INPUT_LATENCY_MAX_PENDING; i += 1) t.recordSent({ x: i, y: 0 }, i);
        expect(t.metrics.supersededSentAt).toEqual([0]);
        expect(t.pendingCount).toBe(INPUT_LATENCY_MAX_PENDING);
    });

    it("counts an input not seen within the timeout as timed out, and does not time it later", () => {
        const t = new InputLatencyTracker();
        t.recordSent({ x: 1, y: 1 }, 0);
        t.observe([2, [1, 0, 1, pos(1, 1)]], INPUT_LATENCY_TIMEOUT_MS + 1);
        expect(t.metrics.timedOutSentAt).toEqual([0]);
        expect(t.metrics.latencyMs).toEqual([]);
    });

    it("matches a repeated point to its oldest pending send", () => {
        const t = new InputLatencyTracker();
        t.recordSent({ x: 3, y: 4 }, 100);
        t.recordSent({ x: 3, y: 4 }, 200);
        t.observe([2, [1, 0, 1, pos(3, 4)]], 250);
        expect(t.metrics.latencyMs).toEqual([150]);
        expect(t.pendingCount).toBe(1);
    });

    it("does not scan frames while nothing is pending", () => {
        const t = new InputLatencyTracker();
        let scanned = 0;
        const frame = new Proxy([2], { get: (target, key) => { scanned += 1; return Reflect.get(target, key); } });
        t.observe(frame, 10);
        expect(scanned).toBe(0);
    });
});

describe("measureInputLatency", () => {
    it("reports inputs sent in the window: distribution, seen, superseded, timed out", () => {
        const m = measureInputLatency(
            [
                { latencyMs: [10, 20, 500], latencySentAt: [900, 1_100, 1_500], supersededSentAt: [1_200], timedOutSentAt: [1_300, 2_100] },
                { latencyMs: [30], latencySentAt: [1_900], supersededSentAt: [], timedOutSentAt: [] }
            ],
            1_000,
            2_000
        );
        expect(m).toMatchObject({ sent: 5, seen: 3, superseded: 1, timedOut: 1 });
        expect(m?.latencyMs.count).toBe(3);
        expect(m?.latencyMs.max).toBe(500);
    });

    it("is null when no input was tracked, so reports without move events keep their shape", () => {
        expect(measureInputLatency([{ latencyMs: [], latencySentAt: [], supersededSentAt: [], timedOutSentAt: [] }], 0, 1_000)).toBeNull();
        expect(measureInputLatency([{}], 0, 1_000)).toBeNull();
    });
});

class FakeSocket {
    sent: Array<string | Uint8Array> = [];
    private handlers: Record<string, Array<(data?: any) => void>> = {};
    on(event: string, handler: (data?: any) => void): void {
        (this.handlers[event] ??= []).push(handler);
    }
    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }
    emit(event: string, data?: any): void {
        for (const handler of this.handlers[event] ?? []) handler(data);
    }
    close(): void {}
}

describe("WorkerClient input latency", () => {
    const config = { serverUrl: "ws://localhost:8080/game/hero-defense", landType: "hero-defense", landInstanceId: "room-1", playerId: "0-0", actions: [] };
    const joined = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true, encoding: "messagepack" } } });

    async function run(trackInputLatency?: boolean) {
        const { WorkerClient } = await import("../src/worker");
        const fake = new FakeSocket();
        let clock = 0;
        const client = new WorkerClient(config, { createSocket: () => fake, now: () => clock, ...(trackInputLatency === undefined ? {} : { trackInputLatency }) });
        client.connect();
        fake.emit("open");
        fake.emit("message", joined);
        clock = 1_000;
        client.sendEvent("MoveTo", { target: pos(60_000, 36_000) });
        clock = 1_030;
        fake.emit("message", msgpackEncode([107, [2, [1, [0, "p1"], 1, pos(1, 1)]], []]));
        clock = 1_120;
        fake.emit("message", msgpackEncode([107, [2, [1, [0, "p1"], 1, pos(60_000, 36_000)]], []]));
        return client.getSession().metrics.inputLatency;
    }

    it("times a sent MoveTo until a state frame shows its target", async () => {
        expect(await run(true)).toMatchObject({ latencyMs: [120], latencySentAt: [1_000] });
    });

    it("tracks nothing by default or with input latency off", async () => {
        const none = { latencyMs: [], latencySentAt: [], supersededSentAt: [], timedOutSentAt: [] };
        expect(await run()).toEqual(none);
        expect(await run(false)).toEqual(none);
    });
});

describe("measurePhase inputToVisible", () => {
    it("is present only when a move event was tracked", async () => {
        const { measurePhase } = await import("../src/run");
        const base = {
            rttMs: [], rttAt: [], stateUpdateIntervalsMs: [], updateAt: [], sendLagMs: [], sentAt: [],
            errorCount: 0, disconnectCount: 0, actionsSent: 0, closes: [], cpuSamples: [], loopDelay: null,
            errorAt: [], pendingAtEnd: [], lateResponseOrigins: [], activeIntervals: [],
            connectionsOpened: 0, connectionsStarted: 0, joinedAtEnd: 0, connectionsReused: 0, connectionsClosed: 0, connectRampMs: 0
        } as any;
        expect(measurePhase([base], 0, 4_000, 1_000, 1_000, 1)).not.toHaveProperty("inputToVisible");
        const tracked = { ...base, inputLatency: { latencyMs: [80, 120], latencySentAt: [1_500, 2_500], supersededSentAt: [], timedOutSentAt: [500] } };
        const m = measurePhase([tracked], 0, 4_000, 1_000, 1_000, 1);
        expect(m.inputToVisible).toMatchObject({ sent: 2, seen: 2, superseded: 0, timedOut: 0 });
        expect(m.inputToVisible?.latencyMs.max).toBe(120);
    });
});
