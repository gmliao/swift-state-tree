import { describe, it, expect } from "vitest";
import { makeRunId, parseRoomSlots, planPhaseConnections, summarizeLayout } from "../src/layout";
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

describe("--room-slots", () => {
    it("two instances with the same run id and disjoint slots hold exactly the full plan", () => {
        const config = { rooms: 6, playersPerRoom: 5 };
        const full = planPhaseConnections("steady", config, 3, "rooms", "shared").flat();
        const impaired = planPhaseConnections("steady", config, 2, "rooms", "shared", parseRoomSlots("0-2:0")).flat();
        const healthy = planPhaseConnections("steady", config, 4, "rooms", "shared", parseRoomSlots("0-2:1-4,3-5:0-4")).flat();

        expect(impaired.map((s) => s.playerId).sort()).toEqual(["p5-r0-s0", "p5-r1-s0", "p5-r2-s0"]);
        expect(healthy).toHaveLength(27);
        const keyOf = (s: { key: string; landInstanceId: string; playerId: string }) => `${s.key}|${s.landInstanceId}|${s.playerId}`;
        const together = [...impaired, ...healthy].map(keyOf).sort();
        expect(together).toEqual(full.map(keyOf).sort());
        // Mixed rooms: both instances name the same land.
        const lands = (specs: typeof full) => new Set(specs.map((s) => s.landInstanceId));
        for (const land of lands(impaired)) expect(lands(healthy).has(land)).toBe(true);
    });

    it("keeps whole rooms on one worker of each instance", () => {
        const plan = planPhaseConnections("steady", { rooms: 4, playersPerRoom: 5 }, 2, "rooms", "r", parseRoomSlots("0-3:1-4"));
        expect(plan.map((specs) => specs.length)).toEqual([8, 8]);
        expect(new Set(plan[0].map((s) => s.landInstanceId))).toEqual(new Set(["r-room-p5-0", "r-room-p5-2"]));
    });

    it("parses single numbers and ranges", () => {
        expect(parseRoomSlots("3:0")).toEqual([{ rooms: [3, 3], slots: [0, 0] }]);
        expect(parseRoomSlots("0-149:1-4,150-299:0-4")).toEqual([
            { rooms: [0, 149], slots: [1, 4] },
            { rooms: [150, 299], slots: [0, 4] }
        ]);
    });

    it.each([
        ["", /each entry is <rooms>:<slots>/],
        ["0-3", /each entry is <rooms>:<slots>/],
        ["a:0", /rooms must be a number or a range/],
        ["0:x", /slots must be a number or a range/],
        ["5-2:0", /reversed/],
        ["0-3:0,2:0", /room 2 slot 0 is named twice/]
    ])("refuses %j", (spec, message) => {
        expect(() => parseRoomSlots(spec)).toThrow(message);
    });

    it("refuses slots or rooms outside a phase, instead of holding fewer connections", () => {
        expect(() =>
            planPhaseConnections("preflight", { rooms: 6, playersPerRoom: 2 }, 2, "rooms", "r", parseRoomSlots("0-5:1-4"))
        ).toThrow(/slots 1-4 exceed phase preflight's 2 players per room/);
        expect(() =>
            planPhaseConnections("steady", { rooms: 6, playersPerRoom: 5 }, 2, "rooms", "r", parseRoomSlots("0-6:0"))
        ).toThrow(/rooms 0-6 exceed phase steady's 6 rooms/);
    });

    it("needs the rooms layout", () => {
        expect(() =>
            planPhaseConnections("steady", { rooms: 2, playersPerRoom: 5 }, 1, "per-connection", "r", parseRoomSlots("0:0"))
        ).toThrow(/needs --layout rooms/);
    });
});

describe("--reconstruct-slots", () => {
    const config = { rooms: 4, playersPerRoom: 5 };

    it("without it, no connection carries the flag: every one reconstructs as before", () => {
        const plain = planPhaseConnections("steady", config, 2, "rooms", "r").flat();
        expect(plain).toHaveLength(20);
        expect(plain.every((s) => !("reconstruct" in s))).toBe(true);
    });

    it("flags exactly the connections in its slots, with or without --room-slots", () => {
        const sampled = planPhaseConnections("steady", config, 2, "rooms", "r", undefined, parseRoomSlots("0-3:0-1")).flat();
        expect(sampled).toHaveLength(20);
        expect(sampled.filter((s) => s.reconstruct).map((s) => s.playerId).sort()).toEqual(
            ["p5-r0-s0", "p5-r0-s1", "p5-r1-s0", "p5-r1-s1", "p5-r2-s0", "p5-r2-s1", "p5-r3-s0", "p5-r3-s1"]
        );
        expect(sampled.filter((s) => s.reconstruct === false)).toHaveLength(12);
        // M's healthy instance: slot 1 of the mixed rooms and slot 0 of the healthy ones.
        const good = planPhaseConnections("steady", config, 2, "rooms", "r", parseRoomSlots("0-1:1-4,2-3:0-4"),
            parseRoomSlots("0-1:1,2-3:0")).flat();
        expect(good).toHaveLength(18);
        expect(good.filter((s) => s.reconstruct).map((s) => s.playerId).sort()).toEqual(["p5-r0-s1", "p5-r1-s1", "p5-r2-s0", "p5-r3-s0"]);
    });

    it("refuses slots outside the phase, and the per-connection layout", () => {
        expect(() => planPhaseConnections("steady", config, 2, "rooms", "r", undefined, parseRoomSlots("0-4:0"))).toThrow(/--reconstruct-slots: rooms/);
        expect(() => planPhaseConnections("steady", config, 2, "rooms", "r", undefined, parseRoomSlots("0:5"))).toThrow(/--reconstruct-slots: slots/);
        expect(() => planPhaseConnections("steady", config, 2, "per-connection", "r", undefined, parseRoomSlots("0:0"))).toThrow(/--reconstruct-slots needs --layout rooms/);
    });
});
