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

    it("leaves input latency off unless --input-latency on", () => {
        expect(parseArgs(["node", "cli"]).inputLatency).toBe(false);
        expect(parseArgs(["node", "cli", "--input-latency", "on"]).inputLatency).toBe(true);
        expect(parseArgs(["node", "cli", "--input-latency", "off"]).inputLatency).toBe(false);
        expect(() => parseArgs(["node", "cli", "--input-latency", "yes"])).toThrow(/--input-latency/);
    });

    it("gates the share of inputs seen at 0.95 unless --input-latency-min-seen says otherwise", () => {
        expect(parseArgs(["node", "cli"]).inputLatencyMinSeen).toBe(0.95);
        expect(parseArgs(["node", "cli", "--input-latency-min-seen", "0"]).inputLatencyMinSeen).toBe(0);
        expect(parseArgs(["node", "cli", "--input-latency-min-seen", "0.8"]).inputLatencyMinSeen).toBe(0.8);
        expect(() => parseArgs(["node", "cli", "--input-latency-min-seen", "95"])).toThrow(/--input-latency-min-seen/);
        // Number("") is 0: a blank value must not turn the gate off.
        expect(() => parseArgs(["node", "cli", "--input-latency-min-seen", ""])).toThrow(/--input-latency-min-seen/);
        expect(() => parseArgs(["node", "cli", "--input-latency-min-seen", " "])).toThrow(/--input-latency-min-seen/);
        expect(() => parseArgs(["node", "cli", "--input-latency-min-seen"])).toThrow(/--input-latency-min-seen/);
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
    it("parses --room-slots and --start-at, and leaves both unset by default", () => {
        expect(parseArgs(["node", "cli"])).toMatchObject({ roomSlots: undefined, startAt: undefined });
        const parsed = parseArgs(["node", "cli", "--room-slots", "0-149:0", "--start-at", "1767225600000"]);
        expect(parsed.roomSlots).toEqual([{ rooms: [0, 149], slots: [0, 0] }]);
        expect(parsed.startAt).toBe(1767225600000);
        expect(() => parseArgs(["node", "cli", "--room-slots", "0-149"])).toThrow(/--room-slots/);
        expect(() => parseArgs(["node", "cli", "--room-slots"])).toThrow(/--room-slots/);
        expect(() => parseArgs(["node", "cli", "--start-at", "soon"])).toThrow(/--start-at/);
        expect(() => parseArgs(["node", "cli", "--start-at", "1.5"])).toThrow(/--start-at/);
    });

    it("parses --stale-after and --slow-read in seconds", () => {
        expect(parseArgs(["node", "cli"])).toMatchObject({ staleAfterSeconds: undefined, slowRead: undefined });
        expect(parseArgs(["node", "cli", "--stale-after", "10s"]).staleAfterSeconds).toBe(10);
        expect(parseArgs(["node", "cli", "--stale-after", "2.5"]).staleAfterSeconds).toBe(2.5);
        expect(parseArgs(["node", "cli", "--slow-read", "40:95.5"]).slowRead).toEqual({ startSeconds: 40, durationSeconds: 95.5 });
        for (const bad of ["0", "-1", "s", "ten"]) {
            expect(() => parseArgs(["node", "cli", "--stale-after", bad])).toThrow(/--stale-after/);
        }
        expect(() => parseArgs(["node", "cli", "--stale-after"])).toThrow(/--stale-after/);
        for (const bad of ["40", "40:0", "-1:5", "a:b", "40:5:1"]) {
            expect(() => parseArgs(["node", "cli", "--slow-read", bad])).toThrow(/--slow-read/);
        }
    });

    it("parses --reconnect and --reconnect-until", () => {
        expect(parseArgs(["node", "cli"]).reconnect).toBeUndefined();
        expect(parseArgs(["node", "cli", "--reconnect", "on-server-close"]).reconnect).toEqual({ untilSeconds: undefined });
        expect(parseArgs(["node", "cli", "--reconnect", "on-server-close", "--reconnect-until", "210"]).reconnect).toEqual({ untilSeconds: 210 });
        expect(() => parseArgs(["node", "cli", "--reconnect", "always"])).toThrow(/--reconnect must be on-server-close/);
        expect(() => parseArgs(["node", "cli", "--reconnect-until", "210"])).toThrow(/needs --reconnect/);
        expect(() => parseArgs(["node", "cli", "--reconnect", "on-server-close", "--reconnect-until", "0"])).toThrow(/--reconnect-until/);
    });

    it("parses --samples-dir", () => {
        expect(parseArgs(["node", "cli"]).samplesDir).toBeUndefined();
        expect(parseArgs(["node", "cli", "--samples-dir", "results/s1"]).samplesDir).toBe("results/s1");
        expect(() => parseArgs(["node", "cli", "--samples-dir"])).toThrow(/--samples-dir/);
        expect(() => parseArgs(["node", "cli", "--samples-dir", "--workers"])).toThrow(/--samples-dir/);
    });

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
