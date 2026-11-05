// Samples a process's cumulative CPU time, RSS and the host's 1-minute load every interval,
// until the process exits or this sampler is terminated, into `{"system":[...]}`.
//
// Usage: node collect-system-metrics.mjs <pid> <output.json> [intervalSeconds]
//
// Each sample has `tsMs` (wall clock, to place it in a phase's measured window), `monoMs` (a
// monotonic clock, for interval lengths) and `cpuSec` (user + system CPU seconds since the
// process started). The report derives per-interval CPU rates from consecutive samples
// (`src/system-metrics.ts`). It doesn't use `ps -o %cpu`: on Linux that is cumulative CPU time
// divided by the process's whole lifetime, not the rate since the previous sample.
//
// CPU time: Linux reads /proc/<pid>/stat (utime + stime, in clock ticks); elsewhere
// `ps -o time=`. The file is written one sample per line, so a reader can parse it while it
// is still being written.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";

const [pidArg, outFile, intervalArg] = process.argv.slice(2);
const pid = Number(pidArg);
if (!Number.isInteger(pid) || pid <= 0 || !outFile) {
    console.error("Usage: node collect-system-metrics.mjs <pid> <output.json> [intervalSeconds]");
    process.exit(1);
}
const intervalMs = Math.max(100, Math.round(Number(intervalArg ?? "1") * 1000));

const hasProc = fs.existsSync(`/proc/${pid}/stat`);
const clockTicks = hasProc ? readClockTicks() : 0;

function readClockTicks() {
    try {
        const value = Number(execFileSync("getconf", ["CLK_TCK"], { encoding: "utf-8" }).trim());
        return value > 0 ? value : 100;
    } catch {
        return 100;
    }
}

/** `[[dd-]hh:]mm:ss[.frac]` (ps `time`) in seconds. */
function parsePsTime(text) {
    const trimmed = text.trim();
    const [days, rest] = trimmed.includes("-") ? trimmed.split("-") : ["0", trimmed];
    const parts = rest.split(":").map(Number);
    let seconds = 0;
    for (const part of parts) {
        seconds = seconds * 60 + part;
    }
    return Number(days) * 86400 + seconds;
}

/** `{ cpuSec, rssMb }`, or null when the process is gone. */
function sampleProcess() {
    try {
        if (hasProc) {
            const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf-8");
            // Fields after the command name, which is in parentheses and may contain spaces:
            // field 3 (state) is index 0, so utime (14) and stime (15) are 11 and 12.
            const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
            const cpuSec = (Number(fields[11]) + Number(fields[12])) / clockTicks;
            const status = fs.readFileSync(`/proc/${pid}/status`, "utf-8");
            const rssKb = Number(/VmRSS:\s+(\d+)/.exec(status)?.[1] ?? 0);
            return { cpuSec, rssMb: rssKb / 1024 };
        }
        const out = execFileSync("ps", ["-p", String(pid), "-o", "time=,rss="], { encoding: "utf-8" }).trim();
        if (!out) {
            return null;
        }
        const [time, rss] = out.split(/\s+/);
        return { cpuSec: parsePsTime(time), rssMb: Number(rss) / 1024 };
    } catch {
        return null;
    }
}

const monoStart = process.hrtime.bigint();
const monoMs = () => Number(process.hrtime.bigint() - monoStart) / 1e6;

fs.writeFileSync(outFile, '{"system":[\n');
let first = true;
let closed = false;

function close() {
    if (closed) {
        return;
    }
    closed = true;
    fs.appendFileSync(outFile, "\n]}\n");
}

function tick() {
    const sample = sampleProcess();
    if (!sample) {
        close();
        return;
    }
    const tsMs = Date.now();
    const line = JSON.stringify({
        ts: Math.floor(tsMs / 1000),
        tsMs,
        monoMs: Number(monoMs().toFixed(3)),
        cpuSec: Number(sample.cpuSec.toFixed(4)),
        rssMb: Number(sample.rssMb.toFixed(2)),
        load1: Number(os.loadavg()[0].toFixed(2))
    });
    fs.appendFileSync(outFile, `${first ? "" : ",\n"}${line}`);
    first = false;
    setTimeout(tick, intervalMs);
}

for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
    process.on(signal, () => {
        close();
        process.exit(0);
    });
}

tick();
