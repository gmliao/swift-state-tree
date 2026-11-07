import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { parseScenario } from "../src/scenario";

// The network impairment runs (design § 3, § 8): the whole timeline of a run, warm-up through
// tail, is the first phase, which starts at --start-at, the origin that --slow-read and the
// impairment schedule count from. Steady and postflight are short tails in the same rooms, so
// their connections are reused and no transition close falls inside the run.
const dir = path.join(__dirname, "..", "scenarios", "hero-defense");
const files = readdirSync(dir).filter((f) => /^impairment-\d+(-[a-z0-9]+)?\.json$/.test(f));

describe("impairment scenarios", () => {
    it("exist for both load points, BO75 and the SR calibration", () => {
        expect(files.sort()).toEqual(["impairment-10-bo75.json", "impairment-10.json", "impairment-300-bo75.json", "impairment-300-srcal.json", "impairment-300.json"]);
    });

    for (const file of files) {
        it(`${file}: its first phase covers warm-up through tail`, () => {
            const raw = JSON.parse(readFileSync(path.join(dir, file), "utf-8"));
            const tl = raw.impairment;
            const scenario = parseScenario(raw);
            const first = scenario.phases.preflight;
            const total = tl.warmupSeconds + tl.baselineSeconds + tl.impairedSeconds + tl.recoverySeconds + tl.tailSeconds;
            expect(first.durationSeconds).toBe(total);
            expect(first.warmupSeconds).toBe(tl.warmupSeconds);
            expect([tl.warmupSeconds, tl.baselineSeconds, tl.recoverySeconds]).toEqual([15, 30, 90]);
            // The tail holds the convergence check (up to 30 s, design § 6) with a margin, and keeps
            // the phase end past the analysis's LATE_MS (5 s): a phase end closes the connections.
            expect(tl.tailSeconds).toBe(45);
            // BO75 is 75 s; the SR calibration pauses 180 s (design § 4); the rest are 60 s.
            expect(tl.impairedSeconds).toBe(file.includes("-bo75") ? 75 : file.includes("-srcal") ? 180 : 60);
            const rooms = Number(/^impairment-(\d+)/.exec(file)![1]);
            for (const phase of [scenario.phases.preflight, scenario.phases.steady, scenario.phases.postflight]) {
                expect([phase.rooms, phase.playersPerRoom, phase.actionsPerSecond, phase.verify]).toEqual([rooms, 5, 1, false]);
            }
            expect(scenario.serverUrl).toBe("ws://10.200.0.1:8080/game/hero-defense");
        });
    }
});
