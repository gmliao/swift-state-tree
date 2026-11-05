import { describe, it, expect } from "vitest";
import { parseArgs } from "../src/cli";

describe("parseArgs", () => {
    it("parses scenario and workers", () => {
        const parsed = parseArgs(["node", "cli", "--scenario", "foo.json", "--workers", "3"]);
        expect(parsed.scenarioPath).toBe("foo.json");
        expect(parsed.workers).toBe(3);
    });

    it("defaults to the rooms layout and a 1000/s ramp", () => {
        const parsed = parseArgs(["node", "cli"]);
        expect(parsed.layout).toBe("rooms");
        expect(parsed.connectMode).toBe("ramp");
        expect(parsed.connectRatePerSecond).toBe(1000);
    });

    it("parses the legacy flags and the ramp rate", () => {
        const parsed = parseArgs(["node", "cli", "--layout", "per-connection", "--connect", "burst", "--connect-rate", "250"]);
        expect(parsed.layout).toBe("per-connection");
        expect(parsed.connectMode).toBe("burst");
        expect(parsed.connectRatePerSecond).toBe(250);
    });

    it("rejects unknown layouts, connect modes and rates", () => {
        expect(() => parseArgs(["node", "cli", "--layout", "rooms5"])).toThrow(/--layout/);
        expect(() => parseArgs(["node", "cli", "--connect", "slow"])).toThrow(/--connect/);
        expect(() => parseArgs(["node", "cli", "--connect-rate", "0"])).toThrow(/--connect-rate/);
    });

    it("parses --boundary, --allow-partial-ramp and --run-id", () => {
        const defaults = parseArgs(["node", "cli"]);
        expect(defaults).toMatchObject({ boundaryMode: "clean", allowPartialRamp: false, runId: undefined });
        const parsed = parseArgs(["node", "cli", "--boundary", "abrupt", "--allow-partial-ramp", "--run-id", "ref-500_a"]);
        expect(parsed).toMatchObject({ boundaryMode: "abrupt", allowPartialRamp: true, runId: "ref-500_a" });
        expect(() => parseArgs(["node", "cli", "--boundary", "rst"])).toThrow(/--boundary/);
        expect(() => parseArgs(["node", "cli", "--run-id", "a/b"])).toThrow(/--run-id/);
    });
});

