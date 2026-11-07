import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { runScenario } from "../src/run";
import { parseRoomSlots } from "../src/layout";

/**
 * Stub game server: answers joins, records every connection's land and how it closed.
 * A close that isn't a client close frame (code 1006) is what the real server logs as a reset.
 */
interface ServerConnection {
    land?: string;
    openedAt: number;
    closeCode?: number;
}

describe("phase lifecycle against a stub server", () => {
    let server: WebSocketServer;
    let url: string;
    const connections: ServerConnection[] = [];
    /** Server-side arrival time of every action. */
    const actionArrivals: number[] = [];

    beforeAll(async () => {
        server = new WebSocketServer({ port: 0 });
        await new Promise<void>((resolve) => server.once("listening", () => resolve()));
        url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}`;
        server.on("connection", (socket) => {
            const record: ServerConnection = { openedAt: Date.now() };
            connections.push(record);
            socket.on("message", (data) => {
                const msg = JSON.parse(String(data));
                if (msg.kind === "join") {
                    record.land = msg.payload.join.landInstanceId;
                    socket.send(JSON.stringify({
                        kind: "joinResponse",
                        payload: { joinResponse: { requestID: msg.payload.join.requestID, success: true, encoding: "json" } }
                    }));
                } else if (msg.kind === "action") {
                    actionArrivals.push(Date.now());
                    socket.send(JSON.stringify({
                        kind: "actionResponse",
                        payload: { actionResponse: { requestID: msg.payload.requestID, response: {} } }
                    }));
                }
            });
            socket.on("close", (code) => {
                record.closeCode = code;
            });
        });
    });

    afterAll(async () => {
        await new Promise<void>((resolve) => server.close(() => resolve()));
    });

    function writeScenario(phases: Record<string, unknown>): string {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ws-loadtest-lifecycle-"));
        const file = path.join(dir, "scenario.json");
        fs.writeFileSync(file, JSON.stringify({ name: "lifecycle", serverUrl: url, phases }));
        return file;
    }

    it("reuses connections across same-size phases and closes every connection with a close frame", async () => {
        connections.length = 0;
        const phase = (rooms: number) => ({ durationSeconds: 1, rooms, playersPerRoom: 3, actionsPerSecond: 5, verify: false });
        const file = writeScenario({ preflight: phase(2), steady: phase(4), postflight: phase(2) });

        const result = await runScenario(file, { workers: 2, layout: "rooms", connectMode: "ramp", connectRatePerSecond: 200 });
        await new Promise((resolve) => setTimeout(resolve, 200));

        // 4 rooms × 3 players at most, opened once each: no reconnect at phase boundaries.
        expect(connections.length).toBe(12);
        expect(new Set(connections.map((c) => c.land)).size).toBe(4);
        expect(connections.every((c) => c.closeCode === 1000)).toBe(true);

        const [pre, steady, post] = result.phases;
        expect(pre.layout).toMatchObject({ connections: 6, lands: 2, playersPerLand: { min: 3, max: 3 } });
        expect(steady.connections).toMatchObject({ opened: 6, reused: 6, closedAtStart: 0 });
        expect(post.connections).toMatchObject({ opened: 0, reused: 6, closedAtStart: 6 });
        expect(post.connections.closes).toMatchObject({ clientInitiated: 6, serverInitiated: 0, forced: 0, byCode: { "1000": 6 } });
        expect(result.shutdownCloses).toMatchObject({ clientInitiated: 6, serverInitiated: 0 });
        for (const p of result.phases) {
            expect(p.report.disconnectCount).toBe(0);
            expect(p.report.rttMs.length).toBeGreaterThan(0);
        }
        expect(result.runConfig).toMatchObject({ layout: "rooms", connectMode: "ramp", connectRatePerSecond: 200, workers: 2 });
        expect(result.runConfig.phases.map((p) => p.lands)).toEqual([2, 4, 2]);
    }, 30_000);

    it("two instances with one run id and disjoint --room-slots fill the same rooms, started together by --start-at", async () => {
        connections.length = 0;
        const phase = { durationSeconds: 1, rooms: 4, playersPerRoom: 3, actionsPerSecond: 5, verify: false };
        const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });
        const startAt = Date.now() + 1500;
        const common = { layout: "rooms" as const, connectMode: "burst" as const, runId: "shared", startAt };
        const [impaired, healthy] = await Promise.all([
            runScenario(file, { ...common, workers: 1, roomSlots: parseRoomSlots("0-1:0") }),
            runScenario(file, { ...common, workers: 2, roomSlots: parseRoomSlots("0-1:1-2,2-3:0-2") })
        ]);
        await new Promise((resolve) => setTimeout(resolve, 200));

        // 4 rooms × 3 players in all, every room joined by its own players only once.
        expect(connections.length).toBe(12);
        const perLand = new Map<string, number>();
        for (const c of connections) perLand.set(c.land!, (perLand.get(c.land!) ?? 0) + 1);
        expect([...perLand.values()]).toEqual([3, 3, 3, 3]);

        expect(impaired.phases[1].connections).toMatchObject({ target: 2, joinedAtEnd: 2 });
        expect(healthy.phases[1].connections).toMatchObject({ target: 10, joinedAtEnd: 10 });
        expect(impaired.phases[1].layout).toMatchObject({ connections: 2, lands: 2 });
        expect(impaired.runConfig).toMatchObject({ runId: "shared", startAt, roomSlots: [{ rooms: [0, 1], slots: [0, 0] }] });
        // Both instances waited for the barrier, so their first phases began together.
        for (const r of [impaired, healthy]) {
            expect(r.runConfig.firstPhaseStartedAt).toBeGreaterThanOrEqual(startAt);
            expect(r.runConfig.firstPhaseStartedAt! - startAt).toBeLessThan(200);
        }
    }, 30_000);

    it("refuses a --start-at that has passed by the time the workers are up", async () => {
        const phase = { durationSeconds: 1, rooms: 1, playersPerRoom: 1, actionsPerSecond: 1, verify: false };
        const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });
        await expect(
            runScenario(file, { workers: 1, layout: "rooms", connectMode: "burst", startAt: Date.now() - 1000 })
        ).rejects.toThrow(/--start-at .* in the past/);
    }, 30_000);

    it("legacy flags give one land per connection, fresh connections per phase, still closed cleanly", async () => {
        connections.length = 0;
        const phase = { durationSeconds: 1, rooms: 2, playersPerRoom: 3, actionsPerSecond: 5, verify: false };
        const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });

        const result = await runScenario(file, { workers: 2, layout: "per-connection", connectMode: "burst" });
        await new Promise((resolve) => setTimeout(resolve, 200));

        expect(connections.length).toBe(18);
        expect(new Set(connections.map((c) => c.land)).size).toBe(18);
        expect(connections.every((c) => c.closeCode === 1000)).toBe(true);
        expect(result.phases.map((p) => p.layout.lands)).toEqual([6, 6, 6]);
        expect(result.phases[1].connections).toMatchObject({ opened: 6, reused: 0, closedAtStart: 6, connectRampMs: 0 });
        // The origin is taken after every worker closed the previous phase's surplus.
        const steady = result.phases[1];
        const transitionCloses = steady.connections.closes.records.filter((c) => c.reason === "phase change");
        expect(transitionCloses).toHaveLength(6);
        expect(Math.max(...transitionCloses.map((c) => c.t))).toBeLessThan(steady.measurement.originAt);
        expect(steady.connections.transitionMs).toBeGreaterThanOrEqual(0);
    }, 30_000);

    it("counts a server-initiated close as a disconnect, not a client close", async () => {
        connections.length = 0;
        const onConnection = (socket: import("ws").WebSocket) => {
            setTimeout(() => socket.close(1001, "going away"), 300);
        };
        server.on("connection", onConnection);
        try {
            const phase = { durationSeconds: 1, rooms: 1, playersPerRoom: 2, actionsPerSecond: 0, verify: false };
            const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });
            const result = await runScenario(file, { workers: 1, layout: "rooms", connectMode: "burst" });
            const pre = result.phases[0];
            // The closes come at 300 ms, inside the 500 ms warm-up: whole-phase count 2, measured 0.
            expect(pre.phaseTotals.disconnectCount).toBe(2);
            expect(pre.report.disconnectCount).toBe(0);
            expect(pre.connections.closes).toMatchObject({ serverInitiated: 2, clientInitiated: 0, byCode: { "1001": 2 } });
            // The closed connections are replaced in the next phase.
            expect(result.phases[1].connections).toMatchObject({ opened: 2, reused: 0 });
        } finally {
            server.off("connection", onConnection);
        }
    }, 30_000);

    it("--boundary abrupt drops sockets at boundaries and at the end without a close frame", async () => {
        connections.length = 0;
        const phase = { durationSeconds: 1, rooms: 2, playersPerRoom: 2, actionsPerSecond: 0, verify: false };
        const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });
        const result = await runScenario(file, { workers: 2, layout: "per-connection", connectMode: "burst", boundaryMode: "abrupt" });
        await new Promise((resolve) => setTimeout(resolve, 300));

        expect(connections.length).toBe(12);
        // No close frame reached the server: 1006 is "closed without a close frame".
        expect(connections.every((c) => c.closeCode === 1006)).toBe(true);
        expect(result.runConfig.boundaryMode).toBe("abrupt");
        expect(result.phases[1].connections.closes).toMatchObject({ clientInitiated: 4, serverInitiated: 0 });
        expect(result.phases[1].connections.closes.records.every((r) => r.abrupt === true)).toBe(true);
        expect(result.phases.every((p) => p.report.disconnectCount === 0)).toBe(true);
    }, 30_000);

    it("refuses a ramp longer than the phase unless partial ramps are allowed", async () => {
        connections.length = 0;
        // 3 × 4 = 12 new connections at 4/s need 3 s; the phase lasts 1 s.
        const phase = { durationSeconds: 1, rooms: 3, playersPerRoom: 4, actionsPerSecond: 0, verify: false };
        const file = writeScenario({ preflight: phase, steady: phase, postflight: phase });
        await expect(
            runScenario(file, { workers: 1, layout: "rooms", connectMode: "ramp", connectRatePerSecond: 4 })
        ).rejects.toThrow(/preflight: ramp 3\.0 s > phase 1 s.*--allow-partial-ramp/);
        expect(connections.length).toBe(0);

        const warnings: string[] = [];
        const result = await runScenario(file, {
            workers: 1,
            layout: "rooms",
            connectMode: "ramp",
            connectRatePerSecond: 4,
            allowPartialRamp: true,
            warn: (m) => warnings.push(m)
        });
        expect(warnings).toHaveLength(1);
        expect(result.runConfig.phases[0].rampMs).toBe(3000);
        const pre = result.phases[0].connections;
        expect(pre.target).toBe(12);
        expect(pre.opened).toBe(12);
        expect(pre.started).toBeLessThan(12);
        expect(pre.joinedAtEnd).toBeLessThan(12);
    }, 30_000);

    it("a phase that adds rooms on one worker ramps at the full rate (20 → 21 rooms, 3 workers)", async () => {
        connections.length = 0;
        // 50/s: preflight's busiest worker (7 rooms × 5) needs 35 × 3 / 50 = 2.1 s of its 3 s.
        const phase = (rooms: number, durationSeconds: number) => ({ durationSeconds, rooms, playersPerRoom: 5, actionsPerSecond: 0, verify: false });
        const file = writeScenario({ preflight: phase(20, 3), steady: phase(21, 1), postflight: phase(21, 1) });
        const result = await runScenario(file, { workers: 3, layout: "rooms", connectMode: "ramp", connectRatePerSecond: 50 });
        const steady = result.phases[1];
        expect(result.phases[0].connections).toMatchObject({ target: 100, started: 100, joinedAtEnd: 100 });
        expect(steady.connections).toMatchObject({ opened: 5, reused: 100, started: 5, joinedAtEnd: 105 });
        // 5 new connections on the one connecting worker at the full 50/s: 100 ms.
        expect(result.runConfig.phases[1].rampMs).toBe(100);
        // The worker's last connect delay is in the ramp's last 20 ms slot; with the rate split
        // over all 3 workers it would be 240–300 ms.
        expect(steady.connections.connectRampMs).toBeGreaterThanOrEqual(80);
        expect(steady.connections.connectRampMs).toBeLessThanOrEqual(100);
    }, 60_000);

    /** Largest number of action arrivals within any `spanMs` interval. */
    function maxInSpan(times: number[], spanMs: number): number {
        const sorted = [...times].sort((a, b) => a - b);
        let best = 0;
        let start = 0;
        for (let end = 0; end < sorted.length; end += 1) {
            while (sorted[end] - sorted[start] >= spanMs) start += 1;
            best = Math.max(best, end - start + 1);
        }
        return best;
    }

    it("spread sends don't arrive as one burst; lockstep sends do", async () => {
        // 1 worker, 20 clients, 5 actions/s each (200 ms period).
        const phase = { durationSeconds: 2, rooms: 4, playersPerRoom: 5, actionsPerSecond: 5, verify: false, warmupSeconds: 0.5 };
        const file = writeScenario({ preflight: { ...phase, durationSeconds: 1 }, steady: phase, postflight: { ...phase, durationSeconds: 1 } });

        actionArrivals.length = 0;
        const spread = await runScenario(file, { workers: 1, layout: "rooms", connectMode: "burst", sendMode: "spread" });
        const spreadBurst = maxInSpan(actionArrivals, 2);
        actionArrivals.length = 0;
        const lockstep = await runScenario(file, { workers: 1, layout: "rooms", connectMode: "burst", sendMode: "lockstep" });
        const lockstepBurst = maxInSpan(actionArrivals, 2);

        expect(lockstepBurst).toBeGreaterThanOrEqual(15);
        expect(spreadBurst).toBeLessThanOrEqual(6);

        const steady = spread.phases[1];
        expect(spread.runConfig).toMatchObject({ sendMode: "spread", windowMs: 1000 });
        expect(steady.measurement.warmupMs).toBe(500);
        expect(steady.measurement.excludedSamples.rtt).toBeGreaterThan(0);
        expect(steady.measurement.sendRate.targetPerSecond).toBe(100);
        expect(steady.measurement.sendRate.achievedPerSecond).toBeGreaterThan(80);
        expect(steady.measurement.sendRate.achievedPerSecond).toBeLessThan(120);
        // Windows split at the warm-up boundary: [0, 500) warm-up, then [500, 1500), [1500, 2000).
        expect(steady.measurement.windows.map((w) => [w.startMs, w.endMs, w.warmup])).toEqual([
            [0, 500, true],
            [500, 1500, false],
            [1500, 2000, false]
        ]);
        expect(steady.measurement.unanswered.measured).toEqual({ pendingAtEnd: expect.any(Number), timedOutAtEnd: 0, lateResponses: 0 });
        expect(steady.measurement.unanswered.measured.pendingAtEnd).toBeLessThanOrEqual(20);
        expect(steady.report.actionsSent).toBe(steady.measurement.sendRate.sentInWindow);
        // The measured-start counter read happens at origin + warm-up, before the end read.
        const readAt = steady.listenQueue.readAt;
        expect(readAt.measuredStartAt).toBeGreaterThanOrEqual(steady.measurement.originAt + 500);
        expect(readAt.measuredStartAt).toBeLessThan(readAt.endAt);
        expect(readAt.phaseStartAt).toBeLessThan(steady.measurement.originAt);
        expect(steady.phaseTotals.actionsSent).toBeGreaterThan(steady.report.actionsSent);
        expect(steady.report.rttMs.length).toBeGreaterThan(100);
        expect(lockstep.phases[1].measurement.sendRate.lagMs.max).toBe(0);
    }, 40_000);
});

