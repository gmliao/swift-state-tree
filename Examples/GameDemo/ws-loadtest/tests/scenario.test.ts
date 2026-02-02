import { describe, it, expect } from "vitest";
import { parseScenario } from "../src/scenario";

describe("parseScenario", () => {
    it("fills defaults when rooms missing", () => {
        const scenario = parseScenario({ phases: { steady: { durationSeconds: 10 } } });
        expect(scenario.phases.steady.rooms).toBe(500);
    });
});
