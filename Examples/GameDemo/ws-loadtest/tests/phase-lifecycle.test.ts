import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { runScenario } from "../src/run";

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
            expect(pre.report.disconnectCount).toBe(2);
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
});
