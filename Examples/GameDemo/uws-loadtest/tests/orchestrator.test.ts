import { describe, it, expect } from "vitest";
import { buildPhases, computeAssignments } from "../src/orchestrator";

describe("buildPhases", () => {
    it("builds phases with default ordering", () => {
        const phases = buildPhases({ phases: { steady: { durationSeconds: 10 } } } as any);
        expect(phases[0].name).toBe("preflight");
    });

    it("distributes connections across workers", () => {
        const assignments = computeAssignments(10, 3);
        expect(assignments).toEqual([4, 3, 3]);
    });
});
