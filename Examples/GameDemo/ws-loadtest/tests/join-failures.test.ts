import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { runScenario } from "../src/run";
import { buildReport } from "../src/report/render-html";

/**
 * Stub game server that admits `capacity` players per land. Further joins are refused the way
 * `rejectMode` says: an error frame (as SwiftStateTree rejects a full room), a join response with
 * `success: false`, or a server close.
 */
type RejectMode = "error" | "response" | "close";

describe("join failures against a stub server", () => {
    let server: WebSocketServer;
    let url: string;
    let capacity = 2;
    let rejectMode: RejectMode = "error";
    const joinedPerLand = new Map<string, number>();

    beforeAll(async () => {
        server = new WebSocketServer({ port: 0 });
        await new Promise<void>((resolve) => server.once("listening", () => resolve()));
        url = `ws://127.0.0.1:${(server.address() as AddressInfo).port}`;
        server.on("connection", (socket) => {
            socket.on("message", (data) => {
                const msg = JSON.parse(String(data));
                if (msg.kind === "join") {
                    const land = msg.payload.join.landInstanceId;
                    const requestID = msg.payload.join.requestID;
                    const joined = joinedPerLand.get(land) ?? 0;
                    if (joined < capacity) {
                        joinedPerLand.set(land, joined + 1);
                        socket.send(JSON.stringify({
                            kind: "joinResponse",
                            payload: { joinResponse: { requestID, success: true, encoding: "json" } }
                        }));
                    } else if (rejectMode === "error") {
                        socket.send(JSON.stringify({
                            kind: "error",
                            payload: { error: { code: "JOIN_DENIED", message: "room is full", details: { requestID, landID: land } } }
                        }));
                    } else if (rejectMode === "response") {
                        socket.send(JSON.stringify({
                            kind: "joinResponse",
                            payload: { joinResponse: { requestID, success: false, reason: "room is full" } }
                        }));
                    } else {
                        socket.close(4000, "room is full");
                    }
                } else if (msg.kind === "action") {
                    socket.send(JSON.stringify({
                        kind: "actionResponse",
                        payload: { actionResponse: { requestID: msg.payload.requestID, response: {} } }
                    }));
                }
            });
        });
    });

    afterAll(async () => {
        await new Promise<void>((resolve) => server.close(() => resolve()));
    });

    function writeScenario(playersPerRoom: number): string {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ws-loadtest-join-failures-"));
        const file = path.join(dir, "scenario.json");
        const phase = { durationSeconds: 1.5, rooms: 1, playersPerRoom, actionsPerSecond: 2, verify: false };
        fs.writeFileSync(
            file,
            JSON.stringify({ name: "join-failures", serverUrl: url, phases: { preflight: phase, steady: phase, postflight: phase } })
        );
        return file;
    }

    async function run(playersPerRoom: number, allowJoinFailures = false) {
        joinedPerLand.clear();
        const result = await runScenario(writeScenario(playersPerRoom), {
            workers: 1,
            layout: "rooms",
            warmupSeconds: 0.3,
            allowJoinFailures
        });
        return { result, report: buildReport(result, { system: [] }) };
    }

    it("all joins admitted: no join failures, joined average equals the target, every phase passes", async () => {
        capacity = 4;
        const { result, report } = await run(4);
        for (const phase of result.phases) {
            expect(phase.connections.joinFailures).toEqual({ phase: 0, measured: 0, byReason: {} });
            expect(phase.measurement.joined.average).toBe(4);
        }
        expect(report.phases.map((p) => p.failures)).toEqual([[], [], []]);
        expect(report.phases.every((p) => p.passed)).toBe(true);
    }, 30_000);

    it("rejected joins fail the phase although the error rate stays 0; reused phases fail on the joined count", async () => {
        capacity = 2;
        rejectMode = "error";
        const { result, report } = await run(4);
        const [pre, steady, post] = result.phases;
        expect(pre.connections.joinFailures.phase).toBe(2);
        expect(pre.connections.joinFailures.byReason).toEqual({ error: 2 });
        expect(pre.connections.joinFailureRecords.map((f) => f.code)).toEqual(["JOIN_DENIED", "JOIN_DENIED"]);
        // Join errors are not action errors: they can't be diluted by the actions sent.
        expect(pre.phaseTotals.errorCount).toBe(0);
        expect(report.phases[0].errorRate).toBe(0);
        expect(report.phases[0].passed).toBe(false);
        expect(report.phases[0].failures.some((f) => f.startsWith("joinFailures 2 > 0 (error 2)"))).toBe(true);
        expect(report.phases[0].failures.some((f) => f.startsWith("joined 2 < target 4"))).toBe(true);
        // The refused connections stay open and are kept without joining again: no new failure,
        // but only 2 of 4 joined, so the later phases fail too.
        for (const [i, phase] of [steady, post].entries()) {
            expect(phase.connections.reused).toBe(4);
            expect(phase.connections.joinFailures.phase).toBe(0);
            expect(phase.measurement.joined.average).toBe(2);
            expect(report.phases[i + 1].passed).toBe(false);
            expect(report.phases[i + 1].failures).toEqual(["joined 2 < target 4 (time-weighted over the measured window)"]);
        }
    }, 30_000);

    it("--allow-join-failures records the failures but doesn't fail the phase", async () => {
        capacity = 2;
        rejectMode = "error";
        const { result, report } = await run(4, true);
        expect(result.runConfig.allowJoinFailures).toBe(true);
        expect(report.meta.runConfig?.allowJoinFailures).toBe(true);
        expect(result.phases[0].connections.joinFailures.phase).toBe(2);
        expect(report.phases.every((p) => p.passed)).toBe(true);
    }, 30_000);

    it("counts a join response with success false and a close before joining as join failures", async () => {
        capacity = 3;
        rejectMode = "response";
        const rejected = await run(4);
        expect(rejected.result.phases[0].connections.joinFailures.byReason).toEqual({ rejected: 1 });
        expect(rejected.report.phases[0].passed).toBe(false);

        rejectMode = "close";
        const closed = await run(4);
        const pre = closed.result.phases[0];
        expect(pre.connections.joinFailures.byReason).toEqual({ closed: 1 });
        expect(pre.connections.joinFailureRecords[0].code).toBe("4000");
        expect(closed.report.phases[0].passed).toBe(false);
        // The closed connection isn't reused: the next phase opens a new one, which is refused again.
        expect(closed.result.phases[1].connections.joinFailures.byReason).toEqual({ closed: 1 });
    }, 60_000);
});
