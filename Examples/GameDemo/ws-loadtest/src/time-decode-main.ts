import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { loadSdkCore, type SdkCore } from "./reconstruction";
import { captureStreams, frameSizes, recordingStreams, roomBytes, summarize, timeStream, type DecodeStream, type TimingOptions } from "./time-decode";

/**
 * `node dist/time-decode-main.js --capture <dir> --out <time-decode.json> [--passes 20] [--warmup 3]`
 * `node dist/time-decode-main.js --recording <frames.json.gz> --out <file> [...]`
 *
 * Client decode cost (`time-decode.ts`) for every run of an `EncodingBenchmark --capture-views`
 * directory, or for a GameServer recording from `scripts/record-frames.mjs`. Run it pinned
 * (`taskset -c 0-7 node ...`). The output records node's version, the CPUs the process may run
 * on, and the commit the SDK was built from; for a capture, that commit must be the capture's
 * benchmark commit and both trees clean, or the run fails (`--allow-unverified-provenance`
 * records the mismatch instead, for a smoke run off the measurement machine).
 */

function git(args: string[]): string | undefined {
    try {
        return execFileSync("git", args, { cwd: __dirname, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch {
        return undefined;
    }
}

/** The CPUs this process may run on: Linux's affinity list, or null where there is none to read. */
function cpuAffinity(): string | null {
    try {
        const status = fs.readFileSync("/proc/self/status", "utf8");
        return status.match(/^Cpus_allowed_list:\s*(.+)$/m)?.[1].trim() ?? null;
    } catch {
        return null;
    }
}

function provenance() {
    const root = git(["rev-parse", "--show-toplevel"]);
    // The SDK the bundle was built from, and this tool: both under the same tree.
    const dirty = root ? git(["-C", root, "status", "--porcelain", "--untracked-files=no", "--", "sdk/ts", "Examples/GameDemo/ws-loadtest"]) : undefined;
    return {
        node: process.version,
        v8: process.versions.v8,
        cpuAffinity: cpuAffinity(),
        sdk: { commit: git(["rev-parse", "HEAD"]) ?? null, dirty: dirty === undefined ? null : dirty.length > 0 }
    };
}

function time(sdk: SdkCore, streams: DecodeStream[], options: TimingOptions) {
    const timings = streams.map((s) => timeStream(sdk, s, options));
    return { summary: summarize(timings, options), frameSizes: frameSizes(streams), streams: timings };
}

async function main(): Promise<void> {
    const argv = process.argv.slice(2);
    const value = (flag: string) => {
        const i = argv.indexOf(flag);
        return i >= 0 ? argv[i + 1] : undefined;
    };
    const capture = value("--capture");
    const recording = value("--recording");
    const out = value("--out");
    const options: TimingOptions = { passes: Number(value("--passes") ?? 20), warmup: Number(value("--warmup") ?? 3) };
    const allowUnverified = argv.includes("--allow-unverified-provenance");
    if (!out || (!capture === !recording) || !(options.passes > 0) || !(options.warmup >= 0)) {
        throw new Error("Usage: node dist/time-decode-main.js (--capture <dir> | --recording <file>) --out <file> [--passes N] [--warmup W] [--allow-unverified-provenance]");
    }
    const sdk = await loadSdkCore();
    const here = provenance();
    const problems: string[] = [];
    if (here.sdk.commit === null) problems.push("the SDK commit is unknown");
    if (here.sdk.dirty !== false) problems.push("the SDK or tool tree has uncommitted changes");
    // The SDK's per-decode debug line goes to its protocol logger, which writes nothing by
    // default; set the default explicitly so a logger set elsewhere can't land in the timing.
    sdk.setProtocolLogger(undefined);
    let report: Record<string, unknown>;
    {
        if (recording) {
            report = { source: { recording: path.resolve(recording) }, ...time(sdk, recordingStreams(sdk, recording), options) };
        } else {
            const runs: Record<string, unknown> = {};
            for (const run of fs.readdirSync(capture!).sort()) {
                const dir = path.join(capture!, run);
                if (!fs.statSync(dir).isDirectory()) continue;
                const files = fs.readdirSync(dir).filter((f) => /^room-\d+\.ndjson$/.test(f)).sort((a, b) => parseInt(a.slice(5)) - parseInt(b.slice(5)));
                if (files.length === 0) continue;
                const header = JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8").split("\n", 1)[0]);
                const benchmark = header.git ?? {};
                if (benchmark.commit !== here.sdk.commit) problems.push(`${run}: captured at ${benchmark.commit ?? "unknown"}, SDK at ${here.sdk.commit}`);
                if (benchmark.dirty !== false) problems.push(`${run}: the benchmark tree was ${benchmark.dirty ? "dirty" : "unknown"}`);
                const streams = files.flatMap((f) => captureStreams(path.join(dir, f), sdk));
                runs[run] = {
                    benchmark, cell: header.cell ?? null, format: header.format, syncStrategy: header.syncStrategy,
                    roomBytes: await roomBytes(files.map((f) => path.join(dir, f))),
                    ...time(sdk, streams, options)
                };
            }
            if (Object.keys(runs).length === 0) problems.push("the capture has no runs");
            report = { source: { capture: path.resolve(capture!) }, runs };
        }
    }
    const verified = problems.length === 0;
    const output = { provenance: { ...here, verified, problems }, timing: { passes: options.passes, warmup: options.warmup, statistic: "median pass" }, ...report };
    fs.writeFileSync(out, `${JSON.stringify(output, null, 2)}\n`);
    if (!verified && !allowUnverified) {
        console.error(`time-decode: provenance not verified (${problems.join("; ")}); report written to ${out}`);
        process.exit(1);
    }
    console.log(`time-decode: ${verified ? "OK" : "UNVERIFIED"} -> ${out}`);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error instanceof Error ? error.message : String(error));
        process.exit(1);
    });
}
