import { describe, it, expect } from "vitest";
import { buildReport, phaseWarningsOf, warningsList } from "../src/report/render-html";

describe("buildReport", () => {
    it("includes thresholds and phase summary", () => {
        const report = buildReport({ scenarioName: "x", phases: [] }, { system: [] });
        expect(report).toHaveProperty("phases");
    });
});

describe("phase warnings (#138)", () => {
    const phaseWith = (joinedAtEnd: number, intervals: number[]) =>
        ({ connections: { joinedAtEnd }, report: { stateUpdateIntervalsMs: intervals } }) as any;

    it("warns when joined clients recorded no state-update samples", () => {
        expect(phaseWarningsOf(phaseWith(4, []))).toEqual([
            "no state-update samples with 4 joined clients: update percentiles are empty"
        ]);
        expect(warningsList(phaseWarningsOf(phaseWith(4, [])))).toContain("warning: no state-update samples");
    });

    it("doesn't warn with samples or with no joined clients", () => {
        expect(phaseWarningsOf(phaseWith(4, [50]))).toEqual([]);
        expect(phaseWarningsOf(phaseWith(0, []))).toEqual([]);
        expect(warningsList([])).toBe("");
    });
});
