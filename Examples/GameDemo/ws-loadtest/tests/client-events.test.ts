import fs from "node:fs";
import path from "node:path";
import { describe, it, expect } from "vitest";
import { decode as msgpackDecode, encode as msgpackEncode } from "@msgpack/msgpack";
import {
    HERO_DEFENSE_WORLD,
    VISIBILITY_TEST_ARENA,
    effectiveEvents,
    eventRandom,
    loadFixedPointTypes,
    mulberry32,
    payloadGenerators,
    uniformPoint
} from "../src/client-events";
import { SendSchedule, sendOffsetMs } from "../src/send-schedule";
import { WorkerClient, WorkerSession, buildEventMessage, frameByteLength } from "../src/worker";
import { parseScenario } from "../src/scenario";
import { measureEvents, measureStateUpdates } from "../src/run";

describe("eventRandom", () => {
    it("is reproducible for the same seed, event and connection", () => {
        const a = eventRandom(42, "MoveTo", "room-p5-0-s0");
        const b = eventRandom(42, "MoveTo", "room-p5-0-s0");
        const first = Array.from({ length: 50 }, () => a());
        expect(Array.from({ length: 50 }, () => b())).toEqual(first);
    });

    it("differs across seeds, events and connections", () => {
        const draw = (seed: number, name: string, key: string) => {
            const r = eventRandom(seed, name, key);
            return Array.from({ length: 5 }, () => r());
        };
        const base = draw(42, "MoveTo", "room-p5-0-s0");
        expect(draw(43, "MoveTo", "room-p5-0-s0")).not.toEqual(base);
        expect(draw(42, "Other", "room-p5-0-s0")).not.toEqual(base);
        expect(draw(42, "MoveTo", "room-p5-0-s1")).not.toEqual(base);
    });

    it("returns floats in [0, 1)", () => {
        const r = mulberry32(7);
        const values = Array.from({ length: 10_000 }, () => r());
        expect(values.every((v) => v >= 0 && v < 1)).toBe(true);
    });
});

describe("uniformPoint", () => {
    it("stays inside the hero-defense world and covers it", () => {
        const r = eventRandom(1, "MoveTo", "k");
        const points = Array.from({ length: 5_000 }, () => uniformPoint(r, HERO_DEFENSE_WORLD));
        expect(points.every((p) => p.x >= 0 && p.x < 128 && p.y >= 0 && p.y < 72)).toBe(true);
        // Roughly uniform: each of a 4 × 4 grid of cells gets about 1/16 of the points.
        const cells = new Map<string, number>();
        for (const p of points) {
            const cell = `${Math.floor(p.x / 32)},${Math.floor(p.y / 18)}`;
            cells.set(cell, (cells.get(cell) ?? 0) + 1);
        }
        expect(cells.size).toBe(16);
        for (const n of cells.values()) {
            expect(n).toBeGreaterThan(5_000 / 16 * 0.7);
            expect(n).toBeLessThan(5_000 / 16 * 1.3);
        }
    });
});

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/move-to-seed42.json"), "utf-8"));

describe("moveTo payload generator", () => {
    it("matches the fixed wire fixture: MoveToEvent { target: Position2 { v: { x, y } } } in fixed point", async () => {
        const moveTo = payloadGenerators(await loadFixedPointTypes()).moveTo;
        const random = eventRandom(fixture.seed, fixture.event, fixture.connectionKey);
        const payloads = fixture.payloads.map(() => moveTo(random));
        expect(payloads).toEqual(fixture.payloads);
        // Through the wire and back, in both encodings, the payload is unchanged.
        const json = JSON.parse(JSON.stringify({ kind: "event", payload: { fromClient: { type: "MoveTo", payload: payloads[0] } } }));
        expect(json.payload.fromClient.payload).toEqual(fixture.payloads[0]);
        const packed = msgpackDecode(msgpackEncode(buildEventMessage("MoveTo", payloads[0])));
        expect(packed).toEqual([103, 0, "MoveTo", fixture.payloads[0]]);
    });

    it("gives integer fixed-point targets inside the world, from the SDK's scale", async () => {
        const types = await loadFixedPointTypes();
        const { FIXED_POINT_SCALE } = await import("@swiftstatetree/sdk/core/deterministic-math");
        const moveTo = payloadGenerators(types).moveTo;
        const random = eventRandom(7, "MoveTo", "k");
        const shadow = eventRandom(7, "MoveTo", "k");
        for (let i = 0; i < 2_000; i += 1) {
            const { target } = moveTo(random) as { target: { v: { x: number; y: number } } };
            const point = uniformPoint(shadow, HERO_DEFENSE_WORLD);
            expect(Number.isInteger(target.v.x) && Number.isInteger(target.v.y)).toBe(true);
            expect(target.v.x).toBeGreaterThanOrEqual(0);
            expect(target.v.x).toBeLessThanOrEqual(128 * FIXED_POINT_SCALE);
            expect(target.v.y).toBeGreaterThanOrEqual(0);
            expect(target.v.y).toBeLessThanOrEqual(72 * FIXED_POINT_SCALE);
            expect(Math.abs(target.v.x - point.x * FIXED_POINT_SCALE)).toBeLessThanOrEqual(1);
            expect(Math.abs(target.v.y - point.y * FIXED_POINT_SCALE)).toBeLessThanOrEqual(1);
        }
    });

    it("keeps the send rate: 2/s per player on spread schedules is 2/s per player", () => {
        const players = Array.from({ length: 50 }, (_, i) => `r-room-p5-${Math.floor(i / 5)}-s${i % 5}`);
        const periodMs = 1000 / 2;
        let sent = 0;
        const firstSlots: number[] = [];
        for (const key of players) {
            const schedule = new SendSchedule(0, periodMs, sendOffsetMs(`MoveTo:${key}`, periodMs));
            schedule.startAt(0);
            const due = schedule.takeDue(60_000, 60_000);
            sent += due.length;
            firstSlots.push(due[0]);
        }
        const perPlayerPerSecond = sent / players.length / 60;
        expect(perPlayerPerSecond).toBeGreaterThan(2 * 0.98);
        expect(perPlayerPerSecond).toBeLessThan(2 * 1.02);
        // Not lockstep: the players' first sends spread over the period.
        expect(new Set(firstSlots.map((t) => Math.floor(t / 50))).size).toBeGreaterThan(5);
    });
});

describe("effectiveEvents (--move-to-rate overlay)", () => {
    const other = { name: "Ping", ratePerSecond: 1 };
    it("keeps the scenario's events without the flag", () => {
        expect(effectiveEvents([other], undefined)).toEqual([other]);
    });
    it("adds or replaces MoveTo at a positive rate", () => {
        expect(effectiveEvents([other], 2)).toEqual([other, { name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }]);
        expect(effectiveEvents([{ name: "MoveTo", ratePerSecond: 5, payloadGenerator: "moveTo" }], 2)).toEqual([
            { name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }
        ]);
    });
    it("removes MoveTo at 0", () => {
        expect(effectiveEvents([other, { name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }], 0)).toEqual([other]);
    });
});

describe("scenario events", () => {
    it("parses events and the seed, and defaults to none", () => {
        const s = parseScenario({ events: [{ name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }], eventSeed: 9 });
        expect(s.events).toEqual([{ name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }]);
        expect(s.eventSeed).toBe(9);
        const plain = parseScenario({});
        expect(plain.events).toEqual([]);
        expect(plain.eventSeed).toBe(1);
    });
    it("rejects a malformed event", () => {
        expect(() => parseScenario({ events: {} })).toThrow(/array/);
        expect(() => parseScenario({ events: [{ ratePerSecond: 1 }] })).toThrow(/name/);
        expect(() => parseScenario({ events: [{ name: "MoveTo", ratePerSecond: 0 }] })).toThrow(/ratePerSecond/);
    });
    it("the moving-players example is default.json plus the events block", () => {
        const read = (name: string) => JSON.parse(fs.readFileSync(path.join(__dirname, "../scenarios/hero-defense", name), "utf-8"));
        const moving = read("moving-players.json");
        const base = read("default.json");
        const { events, name, ...rest } = moving;
        const { name: baseName, ...baseRest } = base;
        expect(rest).toEqual(baseRest);
        expect(events).toEqual([{ name: "MoveTo", ratePerSecond: 2, payloadGenerator: "moveTo" }]);
    });
});

describe("client events on the wire", () => {
    function joinedClient(encoding: "json" | "messagepack") {
        const fake = new FakeSocket();
        let now = 1_000;
        const client = new WorkerClient(
            { serverUrl: "ws://x", landType: "hero-defense", landInstanceId: "room-1", playerId: "p", actions: [] },
            { createSocket: () => fake, now: () => now }
        );
        client.connect();
        fake.emit("open");
        fake.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true, encoding } } }));
        fake.sent = [];
        return { client, fake, advance: (ms: number) => (now += ms) };
    }

    it("sends a client event in JSON and counts it, with no RTT", () => {
        const { client, fake } = joinedClient("json");
        client.sendEvent("MoveTo", fixture.payloads[0]);
        expect(JSON.parse(fake.sent[0] as string)).toEqual({
            kind: "event",
            payload: { fromClient: { type: "MoveTo", payload: fixture.payloads[0] } }
        });
        const metrics = client.getSession().metrics;
        expect(metrics.eventSentAt).toEqual({ MoveTo: [1_000] });
        expect(metrics.actionsSent).toBe(0);
        expect(client.getSession().takePending()).toEqual([]);
    });

    it("sends a client event as an opcode array in MessagePack", () => {
        const { client, fake } = joinedClient("messagepack");
        client.sendEvent("MoveTo", fixture.payloads[1]);
        expect(msgpackDecode(fake.sent[0] as Uint8Array)).toEqual([103, 0, "MoveTo", fixture.payloads[1]]);
    });

    it("records state-update payload sizes parallel to updateAt, without the first update", () => {
        const { fake, client, advance } = joinedClient("json");
        const snapshot = JSON.stringify({ type: "firstSync", patches: [{ op: "replace", path: "/players", value: { a: 1, b: 2 } }] });
        const update = JSON.stringify({ type: "diff", patches: [{ op: "replace", path: "/x", value: 1 }] });
        fake.emit("message", snapshot);
        advance(100);
        fake.emit("message", update);
        advance(100);
        fake.emit("message", Buffer.from(update));
        fake.emit("message", JSON.stringify({ kind: "actionResponse", payload: { actionResponse: { requestID: "a" } } }));
        const metrics = client.getSession().metrics;
        expect(metrics.updateBytes).toEqual([update.length, update.length]);
        expect(metrics.updateAt).toEqual([1_100, 1_200]);
        expect(frameByteLength("é")).toBe(2);
        expect(frameByteLength(new Uint8Array(5))).toBe(5);
    });
});

describe("event and update measurement", () => {
    it("counts events and update bytes in the measured window", () => {
        const reports = [
            { eventSentAt: { MoveTo: [500, 1_000, 1_500, 2_500] }, updateBytes: [100, 200, 300], updateAt: [900, 1_100, 2_100] },
            { eventSentAt: { MoveTo: [1_200, 1_700] }, updateBytes: [400], updateAt: [1_900] },
            // Sizes not parallel to updateAt (none recorded): counted in the rate, not in bytes.
            { eventSentAt: {}, updateBytes: [], updateAt: [1_300, 1_400] }
        ];
        const events = measureEvents(reports.slice(0, 2), [{ name: "MoveTo", ratePerSecond: 2 }], 1_000, 2_000, 2);
        expect(events.MoveTo).toEqual({
            ratePerPlayerPerSecond: 2,
            targetPerSecond: 4,
            sentInWindow: 4,
            achievedPerSecond: 4,
            perPlayerPerSecond: 2
        });
        const updates = measureStateUpdates(reports, 1_000, 2_000, 2);
        expect(updates.inWindow).toBe(4);
        expect(updates.perSecond).toBe(4);
        expect(updates.perPlayerPerSecond).toBe(2);
        expect(updates.bytes.count).toBe(2);
        expect(updates.bytesMean).toBe(300);
        expect(updates.bytes.p99).toBe(400);
    });

    it("a session records events and update bytes into its metrics", () => {
        const session = new WorkerSession();
        session.handleDecodedMessage({ type: "stateUpdate" }, 10, 900);
        session.handleDecodedMessage({ type: "stateUpdate" }, 110, 42);
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "x" }, 111, 7);
        expect(session.metrics.updateBytes).toEqual([42]);
        expect(session.metrics.updateAt).toEqual([110]);
    });

    it("counts connections by whether permessage-deflate was negotiated", () => {
        for (const [extensions, expected] of [
            ["permessage-deflate", { negotiated: 1, notNegotiated: 0 }],
            ["", { negotiated: 0, notNegotiated: 1 }],
            [undefined, { negotiated: 0, notNegotiated: 1 }]
        ] as const) {
            const fake = new FakeSocket();
            fake.extensions = extensions;
            const client = new WorkerClient(
                { serverUrl: "ws://x", landType: "hero-defense", landInstanceId: "room-1", playerId: "p", actions: [] },
                { createSocket: () => fake }
            );
            client.connect();
            fake.emit("open");
            expect(client.getSession().metrics.permessageDeflate).toEqual(expected);
        }
    });
});

class FakeSocket {
    public sent: Array<string | Uint8Array> = [];
    public extensions: string | undefined;
    private handlers: Record<string, Array<(data?: any) => void>> = {};
    on(event: string, handler: (data?: any) => void): void {
        (this.handlers[event] ??= []).push(handler);
    }
    emit(event: string, data?: any): void {
        (this.handlers[event] ?? []).forEach((handler) => handler(data));
    }
    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }
    close(): void {}
}

describe("moveViewer payload generator", () => {
    it("gives a MoveViewerEvent with an integer fixed-point position inside the visibility-test arena", async () => {
        const types = await loadFixedPointTypes();
        const { FIXED_POINT_SCALE } = await import("@swiftstatetree/sdk/core/deterministic-math");
        const moveViewer = payloadGenerators(types).moveViewer;
        const random = eventRandom(7, "MoveViewer", "k");
        const shadow = eventRandom(7, "MoveViewer", "k");
        for (let i = 0; i < 2_000; i += 1) {
            const payload = moveViewer(random) as { position: { v: { x: number; y: number } } };
            expect(Object.keys(payload)).toEqual(["position"]);
            const point = uniformPoint(shadow, VISIBILITY_TEST_ARENA);
            const { x, y } = payload.position.v;
            expect(Number.isInteger(x) && Number.isInteger(y)).toBe(true);
            expect(x).toBeGreaterThanOrEqual(0);
            expect(x).toBeLessThanOrEqual(100 * FIXED_POINT_SCALE);
            expect(y).toBeGreaterThanOrEqual(0);
            expect(y).toBeLessThanOrEqual(100 * FIXED_POINT_SCALE);
            expect(Math.abs(x - point.x * FIXED_POINT_SCALE)).toBeLessThanOrEqual(1);
            expect(Math.abs(y - point.y * FIXED_POINT_SCALE)).toBeLessThanOrEqual(1);
        }
    });
});

describe("one sync, one update (#65)", () => {
    it("counts a merged broadcast frame and the per-player frame after it as one update", () => {
        const session = new WorkerSession();
        // Tick 1 (no interval yet), tick 2 and tick 3, each a 107 frame then the per-player frame.
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 0, 14);
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 0, 68);
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 50, 23);
        session.handleDecodedMessage({ kind: undefined, 0: 103 }, 50, 9); // a targeted event frame in between
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 51, 88);
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 100, 32);
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 100, 134);
        expect(session.metrics.updateAt).toEqual([50, 100]);
        expect(session.metrics.stateUpdateIntervalsMs).toEqual([50, 50]);
        expect(session.metrics.updateBytes).toEqual([23 + 88, 32 + 134]);
    });

    it("keeps a per-player frame without a 107 frame just before it as its own update", () => {
        const session = new WorkerSession();
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 0, 14);
        // Too late to belong to the 107 frame's sync.
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 50, 68);
        // A second plain frame after a plain frame: a new sync.
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 100, 70);
        expect(session.metrics.updateAt).toEqual([50, 100]);
        expect(session.metrics.updateBytes).toEqual([68, 70]);
    });

    it("leaves broadcast-only (hero-defense) and json streams unchanged: one frame, one update", () => {
        const session = new WorkerSession();
        for (const at of [0, 100, 200]) session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, at, 40);
        expect(session.metrics.updateAt).toEqual([100, 200]);
        expect(session.metrics.updateBytes).toEqual([40, 40]);
        const json = new WorkerSession();
        for (const at of [0, 1, 100]) json.handleDecodedMessage({ type: "stateUpdate", updateType: "diff" }, at, 30);
        expect(json.metrics.updateAt).toEqual([1, 100]);
    });

    it("does not add a per-player frame's bytes to a size recorded before a metrics reset", () => {
        const session = new WorkerSession();
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 0, 14);
        session.handleDecodedMessage({ type: "stateUpdateWithEvents" }, 50, 23);
        session.resetMetrics();
        session.handleDecodedMessage({ type: "stateUpdate", opcode: 2 }, 50, 88);
        expect(session.metrics.updateAt).toEqual([]);
        expect(session.metrics.updateBytes).toEqual([]);
    });
});
