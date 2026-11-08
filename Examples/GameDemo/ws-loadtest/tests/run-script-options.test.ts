import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { USAGE } from "../src/cli.js";

// run-ws-loadtest.sh parses its options and builds the client's command line (CMD) itself, so an
// option the CLI gained can be accepted by the script and silently dropped.
describe("run-ws-loadtest.sh forwards the client options it parses", () => {
    const script = fs.readFileSync(path.join(__dirname, "..", "scripts", "run-ws-loadtest.sh"), "utf8");
    const parsed = new Set([...script.matchAll(/^ {4}(--[a-z-]+)\)/gm)].map((m) => m[1]));
    const forwarded = new Set([...script.matchAll(/CMD\+=\((--[a-z-]+)/g)].map((m) => m[1]));
    const cliOptions = new Set([...USAGE.matchAll(/^ {2}(--[a-z-]+)/gm)].map((m) => m[1]));
    // The script resolves these itself (paths, the server, the profile) and passes the result on
    // in its own form, or uses them only for its own steps.
    const ownedByScript = new Set([
        "--scenario", "--output-dir", "--startup-timeout", "--profile", "--system-metrics-out",
        "--external-server", "--external-profile"
    ]);

    it("parses and forwards --input-latency-min-seen", () => {
        expect(parsed.has("--input-latency-min-seen")).toBe(true);
        expect(forwarded.has("--input-latency-min-seen")).toBe(true);
    });

    it("forwards every CLI option it parses, except the ones it owns", () => {
        const dropped = [...parsed].filter((o) => cliOptions.has(o) && !ownedByScript.has(o) && !forwarded.has(o));
        expect(dropped).toEqual([]);
        expect(cliOptions.size).toBeGreaterThan(20);
    });
});
