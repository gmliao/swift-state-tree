import { describe, expect, it } from "vitest";
import { runConvergence, type ConvergenceInstance, type DebugStateApi } from "../src/converge";
import type { ConvergenceConnection } from "../src/worker";
import { loadSdkCore } from "../src/reconstruction";

// The coordinator against fake instances and a fake admin API: coverage, outcomes, the quiet
// barrier, the retry of an inconclusive land, and resume on every path.

function connection(land: string, player: string, extra: Partial<ConvergenceConnection> = {}): ConvergenceConnection {
    return { key: `${land}:${player}`, land, player, serverPlayer: `sp-${player}`, open: true, reconnected: false, decodeErrors: 0, lastPatchAt: 0, ...extra };
}

class FakeInstance implements ConvergenceInstance {
    stopped = 0;
    constructor(
        readonly name: string,
        private readonly connections: ConvergenceConnection[],
        private readonly states: Record<string, unknown>,
        private readonly patchAt: (key: string) => number | undefined = () => 0
    ) {}
    async stopSending(): Promise<void> {
        this.stopped += 1;
    }
    async lands(only?: string[], withStates?: string[]): Promise<ConvergenceConnection[]> {
        return this.connections
            .filter((c) => !only || only.includes(c.land))
            .map((c) => ({ ...c, lastPatchAt: this.patchAt(c.key), state: withStates?.includes(c.land) && c.open ? this.states[c.key] : undefined }));
    }
}

class FakeDebug implements DebugStateApi {
    calls: string[] = [];
    frozen = new Set<string>();
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
        this.frozen.delete(landID);
        return {};
    }
}

const instant = async () => {};

describe("runConvergence", () => {
    it("checks every land across instances, and reports converged, mismatched and missing clients", async () => {
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
        const report = await runConvergence({ instances: [a, b], debug, compareStates, landType: "hd", sleep: instant });
        expect([a.stopped, b.stopped]).toEqual([1, 1]);
        expect(report.lands.map((l) => [l.land, l.outcome])).toEqual([
            ["r0", "converged"],
            ["r1", "mismatched"],
            ["r2", "missingClients"]
        ]);
        expect(report.totals).toMatchObject({ lands: 3, converged: 1, mismatched: 1, missingClients: 1, inconclusive: 0, errors: 0 });
        // The reconnected connection is counted in its own row.
        expect(report.totals.reconnected).toEqual({ compared: 1, converged: 0 });
        expect(report.totals.survivors).toEqual({ compared: 4, converged: 4 });
        const r1 = report.lands[1].connections.find((c) => c.player === "1")!;
        expect(r1.paths).toEqual([{ path: "/hp", client: 9, server: 2 }]);
        expect(debug.frozen.size).toBe(0);
        expect(debug.calls.filter((c) => c.startsWith("projection hd:r2"))).toEqual(["projection hd:r2 sp-1"]);
    });

    it("waits for the quiet window after the freeze before reading states", async () => {
        const { compareStates } = await loadSdkCore();
        let t = 1000;
        // Patches keep arriving until t = 1300, then stop.
        const inst = new FakeInstance("i", [connection("r0", "0")], { "r0:0": { v: 1 } }, () => Math.min(t, 1300));
        const debug = new FakeDebug({ "hd:r0/sp-0": { v: 1 } });
        const report = await runConvergence({
            instances: [inst], debug, compareStates, landType: "hd", quietMs: 200,
            now: () => t,
            sleep: async (ms) => { t += ms; }
        });
        expect(report.lands[0].outcome).toBe("converged");
        expect(t).toBeGreaterThanOrEqual(1500);
    });

    it("fails a land whose patches don't settle, and resumes it", async () => {
        const { compareStates } = await loadSdkCore();
        let t = 0;
        const inst = new FakeInstance("i", [connection("r0", "0")], {}, () => t);
        const debug = new FakeDebug({});
        const report = await runConvergence({
            instances: [inst], debug, compareStates, landType: "hd", settleTimeoutMs: 1000,
            now: () => t, sleep: async (ms) => { t += ms; }
        });
        expect(report.lands[0]).toMatchObject({ outcome: "error" });
        expect(report.lands[0].error).toMatch(/still arriving/);
        expect(debug.calls.at(-1)).toBe("resume hd:r0");
    });

    it("retries an inconclusive land once, and reports it inconclusive if it stays so", async () => {
        const { compareStates } = await loadSdkCore();
        const inst = new FakeInstance("i", [connection("r0", "0"), connection("r1", "0")], { "r0:0": {}, "r1:0": {} });
        // r0 changes membership on its first check only; r1 on every check.
        const debug = new FakeDebug({ "hd:r0/sp-0": {}, "hd:r1/sp-0": {} }, (landID, attempt) => landID === "hd:r1" || attempt === 1);
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", sleep: instant });
        expect(report.lands.map((l) => [l.land, l.outcome, l.attempts])).toEqual([
            ["r0", "converged", 2],
            ["r1", "inconclusive", 2]
        ]);
        expect(debug.calls.filter((c) => c === "freeze hd:r1")).toHaveLength(2);
        expect(debug.frozen.size).toBe(0);
    });

    it("counts a connection without a server player as a mismatch, and an empty land as an error", async () => {
        const { compareStates } = await loadSdkCore();
        const inst = new FakeInstance("i", [connection("r0", "0", { serverPlayer: undefined })], {});
        const report = await runConvergence({ instances: [inst], debug: new FakeDebug({}), compareStates, landType: "hd", sleep: instant });
        expect(report.lands[0].outcome).toBe("mismatched");
        expect(report.lands[0].connections[0].outcome).toBe("noServerPlayer");
        const none = await runConvergence({ instances: [new FakeInstance("i", [], {})], debug: new FakeDebug({}), compareStates, landType: "hd" });
        expect(none.totals.lands).toBe(0);
    });

    it("keeps at most `concurrency` lands frozen at once", async () => {
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
        const report = await runConvergence({ instances: [inst], debug, compareStates, landType: "hd", concurrency: 3, sleep: instant });
        expect(report.totals.converged).toBe(7);
        expect(maxFrozen).toBe(3);
    });
});
