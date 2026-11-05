import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import type { AddressInfo } from "node:net";
import { runScenario } from "../src/run";
import { buildReport, renderHtml } from "../src/report/render-html";

/**
 * Stub game server that admits `capacity` players per land. Further joins are refused the way
 * `rejectMode` says: an error frame (as SwiftStateTree rejects a full room), a join response with
 * `success: false`, a server close, or no answer at all.
 */
type RejectMode = "error" | "response" | "close" | "silent";

describe("join failures against a stub server", () => {
    let server: WebSocketServer;
    let url: string;
    let capacity = 2;
    let rejectMode: RejectMode = "error";
    /** Delay before an admitted join is answered. */
    let joinDelayMs = 0;
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
                        const answer = () => socket.send(JSON.stringify({
                            kind: "joinResponse",
                            payload: { joinResponse: { requestID, success: true, encoding: "json" } }
                        }));
                        if (joinDelayMs > 0) {
                            setTimeout(answer, joinDelayMs);
                        } else {
                            answer();
                        }
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
                    } else if (rejectMode === "close") {
                        socket.close(4000, "room is full");
                    }
                    // "silent": the join is never answered.
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

    function writeScenario(playersPerRoom: number, durationSeconds = 1.5): string {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ws-loadtest-join-failures-"));
        const file = path.join(dir, "scenario.json");
        const phase = { durationSeconds, rooms: 1, playersPerRoom, actionsPerSecond: 2, verify: false };
        fs.writeFileSync(
            file,
            JSON.stringify({ name: "join-failures", serverUrl: url, phases: { preflight: phase, steady: phase, postflight: phase } })
        );
        return file;
    }

    async function run(playersPerRoom: number, allowJoinFailures = false, extra: Record<string, unknown> = {}) {
        joinedPerLand.clear();
        const result = await runScenario(writeScenario(playersPerRoom), {
            workers: 1,
            layout: "rooms",
            warmupSeconds: 0.3,
            allowJoinFailures,
            ...extra
        });
        return { result, report: buildReport(result, { system: [] }) };
    }

    it("all joins admitted: no join failures, joined average equals the target, every phase passes", async () => {
        capacity = 4;
        const { result, report } = await run(4);
        for (const phase of result.phases) {
            expect(phase.connections.joinFailures).toEqual({ phase: 0, measured: 0, byReason: {} });
            expect(phase.measurement.joined.average).toBe(4);
            expect(phase.measurement.joined.atMeasuredStart).toBe(4);
        }
        expect(report.phases.map((p) => p.failures)).toEqual([[], [], []]);
        expect(report.phases.every((p) => p.passed)).toBe(true);
    }, 30_000);

    it("rejected joins fail the phase although the error rate stays 0; the next phase rejoins and fails again", async () => {
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
        expect(report.phases[0].failures).toEqual([
            "joinFailures 2 > 0 (error 2)",
            "joined 2 < target 4 (at the phase end)",
            "joined 2 < target 4 (at the measured-window start)"
        ]);
        // The HTML shows the join failures with reasons and why each FAIL row failed.
        const html = renderHtml(report);
        expect(html).toContain("Join failures (phase)");
        expect(html).toContain("2 (error 2)</span>");
        expect(html).toContain("<li>joinFailures 2 &gt; 0 (error 2)</li>");
        expect(html).toContain("<li>joined 2 &lt; target 4 (at the phase end)</li>");
        expect(html).toContain("at window start: 2</div>");
        // Only joined connections are kept: the 2 refused ones are closed at the transition, and
        // the next phase opens 2 new ones that join again (and are refused again).
        for (const [i, phase] of [steady, post].entries()) {
            expect(phase.connections.reused).toBe(2);
            expect(phase.connections.closedAtStart).toBe(2);
            expect(phase.connections.opened).toBe(2);
            expect(phase.connections.joinFailures.byReason).toEqual({ error: 2 });
            expect(phase.measurement.joined.average).toBe(2);
            expect(report.phases[i + 1].passed).toBe(false);
            expect(report.phases[i + 1].failures).toEqual([
                "joinFailures 2 > 0 (error 2)",
                "joined 2 < target 4 (at the phase end)",
                "joined 2 < target 4 (at the measured-window start)"
            ]);
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

    it("a join the server never answers is a timeout join failure at the phase end", async () => {
        capacity = 3;
        rejectMode = "silent";
        const { result, report } = await run(4);
        const [pre, steady] = result.phases;
        expect(pre.connections.joinFailures.byReason).toEqual({ timeout: 1 });
        expect(pre.connections.joinFailureRecords[0].message).toBe("no join response by the phase end");
        expect(report.phases[0].passed).toBe(false);
        // The unanswered connection is closed at the transition and the next phase tries again.
        expect(steady.connections.opened).toBe(1);
        expect(steady.connections.joinFailures.byReason).toEqual({ timeout: 1 });
    }, 30_000);

    it("with --allow-partial-ramp the joined count is checked against the connections the phase held", async () => {
        capacity = 3;
        rejectMode = "error";
        const { report } = await run(4, false, { allowPartialRamp: true });
        expect(report.phases[0].failures).toEqual([
            "joinFailures 1 > 0 (error 1)",
            "joined 3 < opened 4 (at the phase end, partial ramp)",
            "joined 3 < opened 4 (at the measured-window start)"
        ]);
        capacity = 4;
        const healthy = await run(4, false, { allowPartialRamp: true });
        expect(healthy.report.phases.every((p) => p.passed)).toBe(true);
    }, 60_000);

    it("legacy flags with warm-up 0 pass when every join succeeds; the window-start check is n/a", async () => {
        capacity = 4;
        joinedPerLand.clear();
        const result = await runScenario(writeScenario(1), {
            workers: 1,
            layout: "per-connection",
            connectMode: "burst",
            boundaryMode: "abrupt",
            sendMode: "lockstep",
            warmupSeconds: 0
        });
        const report = buildReport(result, { system: [] });
        for (const phase of result.phases) {
            expect(phase.connections.joinFailures.phase).toBe(0);
            expect(phase.measurement.joined.atMeasuredStart).toBeNull();
            expect(phase.measurement.joined.atMeasuredStartNote).toBe("n/a (warm-up <= ramp)");
        }
        expect(report.phases.map((p) => p.failures)).toEqual([[], [], []]);
        expect(renderHtml(report)).toContain("at window start: n/a (warm-up &lt;= ramp)");
    }, 30_000);

    it("joins answered after the measured window starts fail on the window-start check (default warm-up)", async () => {
        capacity = 4;
        joinDelayMs = 1300;
        try {
            joinedPerLand.clear();
            // 2 s phases: the default warm-up is ramp + 2 s capped at half the phase, 1 s.
            const result = await runScenario(writeScenario(2, 2), { workers: 1, layout: "rooms" });
            const report = buildReport(result, { system: [] });
            const pre = result.phases[0];
            expect(result.runConfig.phases[0].warmupMs).toBe(1000);
            expect(pre.connections.joinFailures.phase).toBe(0);
            expect(pre.connections.joinedAtEnd).toBe(2);
            expect(pre.measurement.joined.atMeasuredStart).toBe(0);
            expect(report.phases[0].failures).toEqual(["joined 0 < target 2 (at the measured-window start)"]);
            // Later phases keep the joined connections: joined from the start, they pass.
            expect(report.phases[1].passed).toBe(true);
        } finally {
            joinDelayMs = 0;
        }
    }, 30_000);
});
