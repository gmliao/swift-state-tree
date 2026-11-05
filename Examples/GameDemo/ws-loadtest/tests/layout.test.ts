import { describe, it, expect } from "vitest";
import { makeRunId, planPhaseConnections, summarizeLayout } from "../src/layout";
import { computeAssignments } from "../src/orchestrator";

describe("planPhaseConnections (rooms)", () => {
    it("puts 10 rooms × 5 players on exactly 10 lands of 5 players over 3 workers", () => {
        const plan = planPhaseConnections("steady", { rooms: 10, playersPerRoom: 5 }, 3, "rooms", "r1");
        const perLand = new Map<string, number>();
        const landWorkers = new Map<string, Set<number>>();
        plan.forEach((specs, worker) => {
            for (const spec of specs) {
                perLand.set(spec.landInstanceId, (perLand.get(spec.landInstanceId) ?? 0) + 1);
                if (!landWorkers.has(spec.landInstanceId)) landWorkers.set(spec.landInstanceId, new Set());
                landWorkers.get(spec.landInstanceId)!.add(worker);
            }
        });
        expect(perLand.size).toBe(10);
        expect([...perLand.values()].every((n) => n === 5)).toBe(true);
        // Whole rooms per worker.
        expect([...landWorkers.values()].every((workers) => workers.size === 1)).toBe(true);
        expect(plan.map((s) => s.length)).toEqual([20, 15, 15]);

        const keys = plan.flat().map((s) => s.key);
        expect(new Set(keys).size).toBe(50);
        expect(summarizeLayout(plan, "rooms")).toEqual({
            layout: "rooms",
            connections: 50,
            lands: 10,
            playersPerLand: { min: 5, max: 5 },
            connectionsPerWorker: [20, 15, 15]
        });
    });

    it("keeps a room on the same worker and key in phases of the same size", () => {
        const pre = planPhaseConnections("preflight", { rooms: 4, playersPerRoom: 5 }, 3, "rooms", "r1");
        const steady = planPhaseConnections("steady", { rooms: 10, playersPerRoom: 5 }, 3, "rooms", "r1");
        pre.forEach((specs, worker) => {
            const steadyKeys = new Set(steady[worker].map((s) => s.key));
            for (const spec of specs) expect(steadyKeys.has(spec.key)).toBe(true);
        });
    });

    it("gives a phase with another room size different lands and keys", () => {
        const a = planPhaseConnections("preflight", { rooms: 2, playersPerRoom: 2 }, 2, "rooms", "r1").flat();
        const b = planPhaseConnections("steady", { rooms: 2, playersPerRoom: 5 }, 2, "rooms", "r1").flat();
        const aLands = new Set(a.map((s) => s.landInstanceId));
        expect(b.some((s) => aLands.has(s.landInstanceId))).toBe(false);
        const aKeys = new Set(a.map((s) => s.key));
        expect(b.some((s) => aKeys.has(s.key))).toBe(false);
    });
});

describe("planPhaseConnections (per-connection, legacy)", () => {
    it("reproduces the legacy ids and split", () => {
        const workers = 3;
        const plan = planPhaseConnections("steady", { rooms: 10, playersPerRoom: 5 }, workers, "per-connection", "r1");
        // The formula the tool used before room layouts (worker-runner.ts at eb4aef1), behind
        // the run id prefix.
        const legacy = computeAssignments(50, workers).map((count, w) =>
            Array.from({ length: count }, (_, i) => ({ land: `r1-steady-${w}-${i}`, player: `${w}-${i}` }))
        );
        expect(plan.map((specs) => specs.map((s) => ({ land: s.landInstanceId, player: s.playerId })))).toEqual(legacy);
        expect(summarizeLayout(plan, "per-connection").lands).toBe(50);
    });
});

describe("run id", () => {
    it("prefixes every land id, so two runs never share a land", () => {
        const a = planPhaseConnections("steady", { rooms: 3, playersPerRoom: 2 }, 2, "rooms", "rA").flat();
        const b = planPhaseConnections("steady", { rooms: 3, playersPerRoom: 2 }, 2, "rooms", "rB").flat();
        expect(a.every((s) => s.landInstanceId.startsWith("rA-"))).toBe(true);
        const aLands = new Set(a.map((s) => s.landInstanceId));
        expect(b.some((s) => aLands.has(s.landInstanceId))).toBe(false);
        const legacy = planPhaseConnections("steady", { rooms: 3, playersPerRoom: 2 }, 2, "per-connection", "rA").flat();
        expect(legacy.every((s) => s.landInstanceId.startsWith("rA-steady-"))).toBe(true);
    });

    it("makes short ids that differ between runs", () => {
        expect(makeRunId(1_700_000_000_000, 0.5)).toMatch(/^r[0-9a-z]{7}$/);
        expect(makeRunId(1_700_000_000_000, 0.1)).not.toBe(makeRunId(1_700_000_000_000, 0.9));
        expect(makeRunId(1_700_000_000_000, 0.5)).not.toBe(makeRunId(1_700_000_001_000, 0.5));
    });
});
