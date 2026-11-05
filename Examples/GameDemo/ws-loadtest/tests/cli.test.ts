import { describe, it, expect, vi } from "vitest";
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


describe("help and unknown arguments start no run", () => {
    it("parses --help and -h; any other unknown argument throws with the usage", () => {
        expect(parseArgs(["node", "cli", "--help"]).help).toBe(true);
        expect(parseArgs(["node", "cli", "-h"]).help).toBe(true);
        expect(parseArgs(["node", "cli"]).help).toBe(false);
        expect(() => parseArgs(["node", "cli", "--bogus"])).toThrow(/Unknown argument: --bogus[\s\S]*Usage:/);
        expect(() => parseArgs(["node", "cli", "--scenario", "a.json", "stray"])).toThrow(/Unknown argument: stray/);
        expect(() => parseArgs(["node", "cli", "--workerz", "3"])).toThrow(/Unknown argument: --workerz/);
    });

    it("main prints the usage for --help and rejects an unknown flag, never calling runScenario", async () => {
        vi.resetModules();
        const runScenario = vi.fn(async () => {
            throw new Error("runScenario must not be called");
        });
        vi.doMock("../src/run", () => ({ runScenario }));
        const cli = await import("../src/cli");
        const log = vi.spyOn(console, "log").mockImplementation(() => {});
        try {
            await cli.main(["node", "cli", "--help"]);
            expect(log).toHaveBeenCalledWith(cli.USAGE);
            await expect(cli.main(["node", "cli", "--bogus"])).rejects.toThrow(/Unknown argument/);
            expect(runScenario).not.toHaveBeenCalled();
        } finally {
            log.mockRestore();
            vi.doUnmock("../src/run");
        }
    });
});
