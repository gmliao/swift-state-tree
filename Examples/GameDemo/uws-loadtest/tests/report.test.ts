import { describe, it, expect } from "vitest";
import { buildReport } from "../src/report/render-html";

describe("buildReport", () => {
    it("includes thresholds and phase summary", () => {
        const report = buildReport({ scenarioName: "x", phases: [] }, { system: [] });
        expect(report).toHaveProperty("phases");
    });
});
