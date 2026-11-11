import { describe, it, expect, vi } from "vitest";
import { encode as msgpackEncode, decode as msgpackDecode } from "@msgpack/msgpack";
import {
    INPUT_LATENCY_MAX_PENDING,
    INPUT_LATENCY_TIMEOUT_MS,
    InputLatencyTracker,
    echoPointOf,
    forEachPoint,
    inputLatencyHitRateFailure,
    measureInputLatency,
    statePartOf
} from "../src/input-latency";
import { summarizePhase } from "../src/report/render-html";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { ConnectionReconstruction, loadSdkCore } from "../src/reconstruction";
import { decodeRaw } from "../src/protocol";

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
    it("matches the positional [x, y] form, nested in a merged entry's values", () => {
        const t = new InputLatencyTracker();
        t.recordSent({ x: 101_000, y: 52_000 }, 1_000);
        // A merged entry `[parentId, dynamicKey, op, fieldMask, v1, v2]`, its value positional.
        t.observe(msgpackDecode(msgpackEncode([2, [17, [0, "p1"], 6, 5, 100, [101_000, 52_000]]])), 1_030);
        expect(t.metrics.latencyMs).toEqual([30]);
    });

    it("doesn't take an opcode-107 frame's events for its state", () => {
        const t = new InputLatencyTracker();
        t.recordSent({ x: 101_000, y: 52_000 }, 1_000);
        // A PlayerShootEvent whose `from` is the target the player reached: not the echo.
        t.observe([107, [2], [[1, { from: pos(101_000, 52_000), to: pos(5, 5) }]]], 1_800);
        expect(t.pendingCount).toBe(1);
        t.observe([107, [2, [9, 0, 1, [101_000, 52_000]]], []], 1_850);
        expect(t.metrics.latencyMs).toEqual([850]);
    });

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

    it("times the frame's arrival, not the end of this client's reconstruction of it", async () => {
        // A slow reconstruction (--reconstruct-slots samples some connections): its feed moves the
        // clock, which must not move the input's seenAt.
        const { WorkerClient } = await import("../src/worker");
        const { ConnectionReconstruction } = await import("../src/reconstruction");
        let clock = 0;
        const feed = vi.spyOn(ConnectionReconstruction.prototype, "feed").mockImplementation(() => {
            clock += 50;
        });
        try {
            const fake = new FakeSocket();
            const sdk = { StateTreeView: class {}, RowTables: class { clear() {} }, ResyncSkip: class {} } as any;
            const client = new WorkerClient(config, {
                createSocket: () => fake, now: () => clock, trackInputLatency: true, reconstruction: { sdk, schema: {} }
            });
            client.connect();
            fake.emit("open");
            fake.emit("message", joined);
            clock = 1_000;
            client.sendEvent("MoveTo", { target: pos(60_000, 36_000) });
            clock = 1_120;
            fake.emit("message", msgpackEncode([107, [2, [1, [0, "p1"], 1, pos(60_000, 36_000)]], []]));
            expect(feed).toHaveBeenCalledTimes(2);
            expect(clock).toBe(1_170);
            expect(client.getSession().metrics.inputLatency).toMatchObject({ latencyMs: [120], latencySentAt: [1_000] });
        } finally {
            feed.mockRestore();
        }
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
            errorCount: 0, disconnectCount: 0, actionsSent: 0, closes: [], cpuSamples: [], eluSamples: [], loopDelay: null,
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

describe("the matcher against the real encoder (recorded GameServer frames)", () => {
    // Every frame after which the SDK's view shows a player's `targetPosition` at a new point
    // must hold that point in its state part, in every encoding: what the tracker relies on.
    const fixtureDir = path.join(__dirname, "fixtures");
    const fixtures = fs.readdirSync(fixtureDir).filter((f) => /^hero-defense-frames-.*\.json\.gz$/.test(f)).sort();

    it("has the three encodings' fixtures, and the two recorded with row addressing", () => {
        expect(fixtures).toEqual([
            "hero-defense-frames-json.json.gz",
            "hero-defense-frames-jsonOpcode.json.gz",
            "hero-defense-frames-messagepack.json.gz",
            "hero-defense-frames-rows-jsonOpcode.json.gz",
            "hero-defense-frames-rows-messagepack.json.gz"
        ]);
    });

    for (const file of fixtures) {
        it(`${file}: every new targetPosition is found in the frame that sets it`, async () => {
            const fixture = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(fixtureDir, file))).toString("utf8"));
            const sdk = await loadSdkCore();
            let changes = 0;
            for (const connection of fixture.connections) {
                const reconstruction = new ConnectionReconstruction(sdk, fixture.schema, `hero-defense:${fixture.land}`);
                const targets = () => {
                    const players = (reconstruction.view.getState() as any).players ?? {};
                    // The view holds the point in units (27.919); the wire holds fixed-point integers (27919).
                    const wire = (u: number) => Math.round(u * 1000);
                    return new Map(Object.entries(players).map(([id, p]: [string, any]) => [id, p?.targetPosition?.v ? `${wire(p.targetPosition.v.x)},${wire(p.targetPosition.v.y)}` : undefined]));
                };
                let before = targets();
                for (const frame of connection.frames) {
                    const bytes = Buffer.from(frame.data, "base64");
                    reconstruction.feed(bytes);
                    const after = targets();
                    const found: string[] = [];
                    forEachPoint(statePartOf(decodeRaw(bytes)), (x, y) => found.push(`${x},${y}`));
                    for (const [id, point] of after) {
                        if (point !== undefined && point !== before.get(id)) {
                            changes += 1;
                            expect(found, `${file} ${connection.name} player ${id}`).toContain(point);
                        }
                    }
                    before = after;
                }
            }
            expect(changes, file).toBeGreaterThan(20);
        });
    }
});

describe("the hit-rate gate", () => {
    /** 200 inputs, each followed by a per-player frame holding its point in `shape`. */
    const run = (shape: (x: number, y: number) => unknown) => {
        const t = new InputLatencyTracker();
        for (let i = 0; i < 200; i += 1) {
            const x = 100_000 + i, y = 50_000 + i;
            t.recordSent({ x, y }, i * 1_000);
            t.observe([2, [9, 0, 1, shape(x, y)]], i * 1_000 + 40);
        }
        t.expire(1e9);
        return measureInputLatency([t.metrics], 0, 1e9)!;
    };

    it("passes when the matcher finds the echoes, positional or keyed", () => {
        expect(run((x, y) => [x, y])).toMatchObject({ sent: 200, seen: 200 });
        expect(inputLatencyHitRateFailure(run((x, y) => [x, y]), 0.95)).toBeUndefined();
        expect(inputLatencyHitRateFailure(run((x, y) => pos(x, y)), 0.95)).toBeUndefined();
    });

    it("fails the phase, naming the matcher, when the echo comes in a shape it doesn't know", () => {
        // As after #271 for the old matcher: every input times out, and nothing looks slow.
        const m = run((x, y) => ({ point: { x, y } }));
        expect(m).toMatchObject({ sent: 200, seen: 0, timedOut: 200 });
        expect(inputLatencyHitRateFailure(m, 0.95)).toMatch(/seen 0 of 200 \(0\.0 %\) < 95 %: the input-latency matcher/);
        const phase = { name: "steady", connections: { joinedAtEnd: 5 }, report: { actionsSent: 0, errorCount: 0, disconnectCount: 0, rttMs: [], stateUpdateIntervalsMs: [100] }, measurement: { inputToVisible: m }, config: { rooms: 1, playersPerRoom: 5 } } as any;
        const summary = summarizePhase(phase, { inputLatencyMinSeen: 0.95 } as any);
        expect(summary.passed).toBe(false);
        expect(summary.failures.join("\n")).toMatch(/input-latency matcher/);
        expect(summarizePhase(phase, { inputLatencyMinSeen: 0 } as any).failures.join("\n")).not.toMatch(/matcher/);
    });

    it("doesn't gate a phase with few inputs, or with the gate off", () => {
        const few = { sent: 99, seen: 0, superseded: 0, timedOut: 99, latencyMs: run((x, y) => [x, y]).latencyMs };
        expect(inputLatencyHitRateFailure(few, 0.95)).toBeUndefined();
        expect(inputLatencyHitRateFailure({ ...few, sent: 100, timedOut: 100 }, 0.95)).toBeDefined();
        expect(inputLatencyHitRateFailure({ ...few, sent: 100, timedOut: 100 }, 0)).toBeUndefined();
        expect(inputLatencyHitRateFailure(undefined, 0.95)).toBeUndefined();
    });
});
