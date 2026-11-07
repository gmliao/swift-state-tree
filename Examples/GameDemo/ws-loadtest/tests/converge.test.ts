import { describe, expect, it } from "vitest";
import { runConvergence, type ConvergenceInstance, type DebugStateApi } from "../src/converge";
import type { ConvergenceConnection } from "../src/worker";
import { loadSdkCore } from "../src/reconstruction";

// The coordinator against fake instances, a fake admin API and a fake clock: coverage and the
// roster, outcomes, the quiet barrier, the re-read of a difference until the cap (converged late
// or mismatched), the retry of an inconclusive land, resume (retried, and an error when it fails
// twice), the concurrency limit and the deadline.

function connection(land: string, player: string, extra: Partial<ConvergenceConnection> = {}): ConvergenceConnection {
    return { key: `${land}:${player}`, land, player, serverPlayer: `sp-${player}`, open: true, reconnected: false, decodeErrors: 0, lastFrameAt: 0, ...extra };
}

/** A clock that only moves when the coordinator sleeps. */
function clock(start = 1000) {
    const c = { t: start, now: () => c.t, sleep: async (ms: number) => { c.t += ms; } };
    return c;
}

class FakeInstance implements ConvergenceInstance {
    stopped = 0;
    constructor(
        readonly name: string,
        private readonly connections: ConvergenceConnection[],
        /** A connection's state, or a function of its key giving the state now. */
        private readonly states: Record<string, unknown> | ((key: string) => unknown),
        private readonly frameAt: (key: string) => number | undefined = () => 0
    ) {}
    async stopSending(): Promise<void> {
        this.stopped += 1;
    }
    async lands(only?: string[], withStates?: string[]): Promise<ConvergenceConnection[]> {
        const stateOf = (key: string) => (typeof this.states === "function" ? this.states(key) : this.states[key]);
        return this.connections
            .filter((c) => !only || only.includes(c.land))
            .map((c) => ({ ...c, lastFrameAt: this.frameAt(c.key), state: withStates?.includes(c.land) && c.open ? stateOf(c.key) : undefined }));
    }
}

class FakeDebug implements DebugStateApi {
    calls: string[] = [];
    frozen = new Set<string>();
    resumeFailures = 0;
    constructor(
        private readonly server: Record<string, unknown>,
        private readonly membershipChanged: (landID: string, attempt: number) => boolean = () => false
    ) {}
    private attempts = new Map<string, number>();
    async freeze(landID: string) {
        this.calls.push(`freeze ${landID}`);
        this.frozen.add(landID);
        this.attempts.set(landID, (this.attempts.get(landID) ?? 0) + 1);
        return { freezeToken: `t-${landID}`, tickId: 7 };
    }
    async projection(landID: string, playerID: string) {
        this.calls.push(`projection ${landID} ${playerID}`);
        return {
            freezeToken: `t-${landID}`,
            membershipChanged: this.membershipChanged(landID, this.attempts.get(landID)!),
            state: this.server[`${landID}/${playerID}`] as Record<string, unknown>
        };
    }
    async resume(landID: string) {
        this.calls.push(`resume ${landID}`);
        if (this.resumeFailures > 0) {
            this.resumeFailures -= 1;
            throw new Error("HTTP 500");
        }
        this.frozen.delete(landID);
        return {};
    }
}

describe("runConvergence", () => {
    it("checks every land across instances, reports converged, mismatched and missing clients, and the roster", async () => {
        const { compareStates } = await loadSdkCore();
        const a = new FakeInstance(
            "lt-client",
            [connection("r0", "0"), connection("r1", "0"), connection("r2", "0", { open: false })],
            { "r0:0": { hp: 1 }, "r1:0": { hp: 1 } }
        );
        const b = new FakeInstance(
            "lt-good",
            [connection("r0", "1"), connection("r1", "1", { reconnected: true }), connection("r2", "1")],
            { "r0:1": { hp: 2 }, "r1:1": { hp: 9 }, "r2:1": { hp: 3 } }
        );
        const debug = new FakeDebug({
            "hd:r0/sp-0": { hp: 1 }, "hd:r0/sp-1": { hp: 2 },
            "hd:r1/sp-0": { hp: 1 }, "hd:r1/sp-1": { hp: 2 },
            "hd:r2/sp-1": { hp: 3 }
        });
        const c = clock();
        const report = await runConvergence({ instances: [a, b], debug, compareStates, landType: "hd", now: c.now, sleep: c.sleep });
        expect([a.stopped, b.stopped]).toEqual([1, 1]);
        expect(report.lands.map((l) => [l.land, l.outcome])).toEqual([
            ["r0", "converged"],
            ["r1", "mismatched"],
            ["r2", "missingClients"]
        ]);
        expect(report.totals).toMatchObject({ lands: 3, converged: 1, convergedLate: 0, mismatched: 1, missingClients: 1, inconclusive: 0, errors: 0, lateMaxMs: null });
        // The reconnected connection is counted in its own row.
        expect(report.totals.reconnected).toEqual({ compared: 1, converged: 0, convergedLate: 0 });
        expect(report.totals.survivors).toEqual({ compared: 4, converged: 4, convergedLate: 0 });
        const r1 = report.lands[1].connections.find((x) => x.player === "1")!;
        expect(r1.paths).toEqual([{ path: "/hp", client: 9, server: 2 }]);
        expect(debug.frozen.size).toBe(0);
        expect(debug.calls.filter((x) => x.startsWith("projection hd:r2"))).toEqual(["projection hd:r2 sp-1"]);
        // The roster lists every instance's connections per land, including the closed one.
        expect(report.roster).toEqual({ "lt-client": { r0: 1, r1: 1, r2: 1 }, "lt-good": { r0: 1, r1: 1, r2: 1 } });
    });

    it("waits for the quiet window after the freeze before reading states", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock();
        // Frames keep arriving until t = 1300, then stop.
        const inst = new FakeInstance("i", [connection("r0", "0")], { "r0:0": { v: 1 } }, () => Math.min(c.t, 1300));
        const debug = new FakeDebug({ "hd:r0/sp-0": { v: 1 } });
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", quietMs: 200, now: c.now, sleep: c.sleep });
        expect(report.lands[0].outcome).toBe("converged");
        expect(c.t).toBeGreaterThanOrEqual(1500);
    });

    it("counts a difference that goes away before the cap as converged late, with its delay", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock(0);
        // The last patch (a retransmit) lands 400 ms after the freeze, after the quiet window.
        const inst = new FakeInstance("i", [connection("r0", "0"), connection("r0", "1")], (key) =>
            key === "r0:0" && c.t < 400 ? { v: 1 } : { v: 2 }
        );
        const debug = new FakeDebug({ "hd:r0/sp-0": { v: 2 }, "hd:r0/sp-1": { v: 2 } });
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", now: c.now, sleep: c.sleep });
        expect(report.lands[0]).toMatchObject({ outcome: "convergedLate", lateMs: 400 });
        expect(report.lands[0].connections.map((x) => [x.player, x.outcome, x.lateMs])).toEqual([
            ["0", "convergedLate", 400],
            ["1", "converged", undefined]
        ]);
        expect(report.lands[0].connections[0]).toMatchObject({ differences: 0, paths: [] });
        expect(report.totals).toMatchObject({ converged: 0, convergedLate: 1, mismatched: 0, lateMaxMs: 400 });
        expect(report.totals.survivors).toEqual({ compared: 2, converged: 1, convergedLate: 1 });
        // The projection is fetched once per connection: the server side stays fixed while frozen.
        expect(debug.calls.filter((x) => x.startsWith("projection"))).toHaveLength(2);
        expect(debug.frozen.size).toBe(0);
    });

    it("reports a difference that lasts to the cap as mismatched, at the cap", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock(0);
        const inst = new FakeInstance("i", [connection("r0", "0")], { "r0:0": { v: 1 } });
        const debug = new FakeDebug({ "hd:r0/sp-0": { v: 2 } });
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", capMs: 5000, now: c.now, sleep: c.sleep });
        expect(report.lands[0].outcome).toBe("mismatched");
        expect(report.lands[0].attempts).toBe(1);
        expect(report.lands[0].connections[0].paths).toEqual([{ path: "/v", client: 1, server: 2 }]);
        expect(c.t).toBeGreaterThanOrEqual(5000);
        expect(c.t).toBeLessThan(5000 + 200 + 100);
        expect(debug.frozen.size).toBe(0);
    });

    it("counts a connection that closes while frozen as missing, not mismatched", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock(0);
        const conns = [connection("r0", "0")];
        const inst = new FakeInstance("i", conns, { "r0:0": { v: 1 } });
        const debug = new FakeDebug({ "hd:r0/sp-0": { v: 2 } });
        const sleep = async (ms: number) => { c.t += ms; if (c.t > 1000) conns[0].open = false; };
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", now: c.now, sleep });
        expect(report.lands[0].outcome).toBe("missingClients");
    });

    it("fails a land whose frames don't settle, and resumes it", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock(0);
        const inst = new FakeInstance("i", [connection("r0", "0")], {}, () => c.t);
        const debug = new FakeDebug({});
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", settleTimeoutMs: 1000, now: c.now, sleep: c.sleep });
        expect(report.lands[0]).toMatchObject({ outcome: "error" });
        expect(report.lands[0].error).toMatch(/still arriving/);
        expect(debug.calls.at(-1)).toBe("resume hd:r0");
    });

    it("retries a failed resume once, and makes the land an error when it fails twice", async () => {
        const { compareStates } = await loadSdkCore();
        const make = () => new FakeInstance("i", [connection("r0", "0")], { "r0:0": {} });
        const once = new FakeDebug({ "hd:r0/sp-0": {} });
        once.resumeFailures = 1;
        const c1 = clock();
        const ok = await runConvergence({ instances: [make()], debug: once, compareStates, landType: "hd", now: c1.now, sleep: c1.sleep });
        expect(ok.lands[0].outcome).toBe("converged");
        expect(once.calls.filter((x) => x.startsWith("resume"))).toHaveLength(2);
        expect(once.frozen.size).toBe(0);

        const twice = new FakeDebug({ "hd:r0/sp-0": {} });
        twice.resumeFailures = 2;
        const c2 = clock();
        const bad = await runConvergence({ instances: [make()], debug: twice, compareStates, landType: "hd", now: c2.now, sleep: c2.sleep });
        expect(bad.lands[0].outcome).toBe("error");
        expect(bad.lands[0].error).toMatch(/resume failed twice: HTTP 500/);
        expect(bad.totals.errors).toBe(1);
    });

    it("retries an inconclusive land once, and reports it inconclusive if it stays so", async () => {
        const { compareStates } = await loadSdkCore();
        const inst = new FakeInstance("i", [connection("r0", "0"), connection("r1", "0")], { "r0:0": {}, "r1:0": {} });
        // r0 changes membership on its first check only; r1 on every check.
        const debug = new FakeDebug({ "hd:r0/sp-0": {}, "hd:r1/sp-0": {} }, (landID, attempt) => landID === "hd:r1" || attempt === 1);
        const c = clock();
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", now: c.now, sleep: c.sleep });
        expect(report.lands.map((l) => [l.land, l.outcome, l.attempts])).toEqual([
            ["r0", "converged", 2],
            ["r1", "inconclusive", 2]
        ]);
        expect(debug.calls.filter((x) => x === "freeze hd:r1")).toHaveLength(2);
        expect(debug.frozen.size).toBe(0);
    });

    it("counts a connection without a server player as a mismatch, and an empty land as an error", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock();
        const inst = new FakeInstance("i", [connection("r0", "0", { serverPlayer: undefined })], {});
        const report = await runConvergence({ instances: [inst], debug: new FakeDebug({}), compareStates, landType: "hd", now: c.now, sleep: c.sleep });
        expect(report.lands[0].outcome).toBe("mismatched");
        expect(report.lands[0].connections[0].outcome).toBe("noServerPlayer");
        const none = await runConvergence({ instances: [new FakeInstance("i", [], {})], debug: new FakeDebug({}), compareStates, landType: "hd" });
        expect(none.totals.lands).toBe(0);
        expect(none.roster).toEqual({ i: {} });
    });

    it("keeps at most `concurrency` lands frozen at once, and refuses more than 20", async () => {
        const { compareStates } = await loadSdkCore();
        const lands = Array.from({ length: 7 }, (_, i) => `r${i}`);
        const inst = new FakeInstance("i", lands.map((l) => connection(l, "0")), Object.fromEntries(lands.map((l) => [`${l}:0`, {}])));
        const server = Object.fromEntries(lands.map((l) => [`hd:${l}/sp-0`, {}]));
        const debug = new FakeDebug(server);
        let maxFrozen = 0;
        const freeze = debug.freeze.bind(debug);
        debug.freeze = async (landID: string) => {
            const r = await freeze(landID);
            maxFrozen = Math.max(maxFrozen, debug.frozen.size);
            await new Promise((resolve) => setTimeout(resolve, 1));
            return r;
        };
        const c = clock();
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", concurrency: 3, now: c.now, sleep: c.sleep });
        expect(report.totals.converged).toBe(7);
        expect(maxFrozen).toBe(3);
        await expect(runConvergence({ instances: [inst], debug, compareStates, landType: "hd", concurrency: 21 })).rejects.toThrow(/above 20/);
    });

    it("starts no land check after the deadline, and reports the lands left as errors", async () => {
        const { compareStates } = await loadSdkCore();
        const c = clock(0);
        const lands = ["r0", "r1", "r2"];
        // Every land differs to the cap: 5 s each, one at a time.
        const inst = new FakeInstance("i", lands.map((l) => connection(l, "0")), Object.fromEntries(lands.map((l) => [`${l}:0`, { v: 1 }])));
        const debug = new FakeDebug(Object.fromEntries(lands.map((l) => [`hd:${l}/sp-0`, { v: 2 }])));
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", concurrency: 1, deadlineMs: 8000, now: c.now, sleep: c.sleep });
        expect(report.lands.map((l) => [l.land, l.outcome, l.attempts])).toEqual([
            ["r0", "mismatched", 1],
            ["r1", "mismatched", 1],
            ["r2", "error", 0]
        ]);
        expect(report.lands[2].error).toMatch(/deadline/);
        expect(debug.calls).not.toContain("freeze hd:r2");
    });
});
