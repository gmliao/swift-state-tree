import { describe, it, expect } from "vitest";
import { parseSystemMetrics } from "../src/system-metrics";

describe("parseSystemMetrics", () => {
    it("parses partial JSON without closing bracket", () => {
        const raw = `{"system":[\n{"ts":1,"cpuPct":10,"rssMb":1.5,"load1":0.2}\n`;
        const metrics = parseSystemMetrics(raw);
        expect(metrics.system.length).toBe(1);
        expect(metrics.system[0].ts).toBe(1);
    });
});
