import { describe, it, expect } from "vitest";
import { percentile, evaluateThresholds } from "../src/metrics";

describe("metrics", () => {
    it("computes percentiles", () => {
        expect(percentile([1, 2, 3, 4, 5], 0.95)).toBe(5);
    });

    it("evaluates thresholds", () => {
        const result = evaluateThresholds(
            { errorRate: 0.01, disconnectRate: 0.01, rttP95: 80, rttP99: 200, updateP95: 90, updateP99: 220 },
            { errorRate: 0.1, disconnectRate: 0.1, rttP95: 100, rttP99: 250, updateP95: 100, updateP99: 250 }
        );
        expect(result.passed).toBe(true);
    });
});
