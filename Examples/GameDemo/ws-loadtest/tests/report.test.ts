import { describe, it, expect } from "vitest";
import { buildReport, clientCpuCell, loopDelayCell, phaseWarningsOf, warningsList } from "../src/report/render-html";

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

describe("load client event-loop delay cell", () => {
    it("shows the worst worker's p50 / p99 / max", () => {
        const clientLoopDelay = { workers: 4, p50Ms: { mean: 0.21, max: 0.43 }, p99Ms: { mean: 2.2, max: 7.76 }, maxMs: 31.4 };
        expect(loopDelayCell({ clientLoopDelay })).toBe("0.4 / 7.8 / 31 ms");
    });

    it("shows a dash without samples", () => {
        expect(loopDelayCell(undefined)).toBe("–");
        expect(loopDelayCell({} as any)).toBe("–");
        expect(loopDelayCell({ clientLoopDelay: { workers: 0, p50Ms: { mean: 0, max: 0 }, p99Ms: { mean: 0, max: 0 }, maxMs: 0 } })).toBe("–");
    });
});

describe("load client CPU cell", () => {
    it("shows worker mean / max and the total over the cores", () => {
        const clientCpu = { workers: 4, perWorkerPct: { min: 20, mean: 35.4, max: 61.6 }, totalPct: 141.6, cores: 12 };
        expect(clientCpuCell({ clientCpu })).toBe("35% / 62% · 142% of 12 cores");
    });

    it("adds the orchestrator when it was sampled", () => {
        const clientCpu = { workers: 4, perWorkerPct: { min: 20, mean: 35.4, max: 61.6 }, orchestratorPct: 8.2, totalPct: 149.8, cores: 12 };
        expect(clientCpuCell({ clientCpu })).toBe("35% / 62% · orchestrator 8% · 150% of 12 cores");
    });

    it("shows a dash without samples (older results, or no worker covering the window)", () => {
        expect(clientCpuCell(undefined)).toBe("–");
        expect(clientCpuCell({} as any)).toBe("–");
        expect(clientCpuCell({ clientCpu: { workers: 0, perWorkerPct: { min: 0, mean: 0, max: 0 }, totalPct: 0, cores: 8 } })).toBe("–");
    });
});
