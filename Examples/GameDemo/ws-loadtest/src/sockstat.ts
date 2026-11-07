import { execFile } from "node:child_process";
import fs from "node:fs";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/**
 * Kernel TCP socket memory and queues, per network namespace (`--netns`), one JSON line per
 * sample. Linux only.
 *
 * What is per namespace and what isn't: in `/proc/net/sockstat`'s TCP line, `inuse` and `tw`
 * are the namespace's own, but `orphan`, `alloc` and `mem` are host-wide counters
 * (`net/ipv4/proc.c`, `sockstat_seq_show`), whichever namespace reads them. So `mem` (pages of
 * TCP buffer memory) is sampled once per sample, as `hostTcpMemPages`. What a namespace's
 * sockets hold is summed from `ss` instead: the established sockets' `Recv-Q` (bytes received,
 * not yet read by the application) and `Send-Q` (bytes sent, not yet acknowledged).
 */
export interface SockstatTcp {
    inuse: number;
    orphan: number;
    tw: number;
    alloc: number;
    mem: number;
}

export interface NamespaceSample {
    /** The namespace (`ip netns` name), or `""` for the sampler's own. */
    netns: string;
    /** Per namespace: from `/proc/net/sockstat`. */
    tcpInuse: number;
    tcpTw: number;
    /** Per namespace: summed over established TCP sockets (`ss -tnH state established`). */
    established: number;
    recvQBytes: number;
    sendQBytes: number;
    /** The largest single socket's queues. */
    recvQMaxBytes: number;
    sendQMaxBytes: number;
}

export interface SockstatSample {
    /** ms since epoch, when the sample started. */
    t: number;
    /** Host-wide TCP buffer memory, pages (`/proc/net/sockstat` TCP `mem`). */
    hostTcpMemPages: number;
    /** Host-wide orphaned TCP sockets. */
    hostTcpOrphan: number;
    namespaces: NamespaceSample[];
    /** Namespaces whose read failed this time, with the error; they're absent from `namespaces`. */
    errors?: Array<{ netns: string; error: string }>;
}

/** The TCP line of `/proc/net/sockstat`. */
export function parseSockstat(text: string): SockstatTcp {
    const line = text.split("\n").find((l) => l.startsWith("TCP:"));
    if (!line) {
        throw new Error("no TCP line in /proc/net/sockstat");
    }
    const fields = line.slice(4).trim().split(/\s+/);
    const values: Record<string, number> = {};
    for (let i = 0; i + 1 < fields.length; i += 2) {
        values[fields[i]] = Number(fields[i + 1]);
    }
    for (const key of ["inuse", "orphan", "tw", "alloc", "mem"]) {
        if (!Number.isFinite(values[key])) {
            throw new Error(`/proc/net/sockstat TCP line has no ${key}: ${line}`);
        }
    }
    return { inuse: values.inuse, orphan: values.orphan, tw: values.tw, alloc: values.alloc, mem: values.mem };
}

/** `ss -tnH state established` output (columns `Recv-Q Send-Q Local Peer`), summed. */
export function parseSsQueues(text: string): Pick<NamespaceSample, "established" | "recvQBytes" | "sendQBytes" | "recvQMaxBytes" | "sendQMaxBytes"> {
    let established = 0;
    let recvQBytes = 0;
    let sendQBytes = 0;
    let recvQMaxBytes = 0;
    let sendQMaxBytes = 0;
    for (const line of text.split("\n")) {
        const fields = line.trim().split(/\s+/);
        if (fields.length < 4) {
            continue;
        }
        const recvQ = Number(fields[0]);
        const sendQ = Number(fields[1]);
        if (!Number.isInteger(recvQ) || !Number.isInteger(sendQ)) {
            throw new Error(`unexpected ss line: ${line}`);
        }
        established += 1;
        recvQBytes += recvQ;
        sendQBytes += sendQ;
        recvQMaxBytes = Math.max(recvQMaxBytes, recvQ);
        sendQMaxBytes = Math.max(sendQMaxBytes, sendQ);
    }
    return { established, recvQBytes, sendQBytes, recvQMaxBytes, sendQMaxBytes };
}

/** Runs a command, inside `netns` unless it is `""`. */
export type Runner = (netns: string, command: string, args: string[]) => Promise<string>;

export const defaultRunner: Runner = async (netns, command, args) => {
    const [file, argv] = netns === "" ? [command, args] : ["ip", ["netns", "exec", netns, command, ...args]];
    const { stdout } = await execFileAsync(file, argv, { maxBuffer: 64 * 1024 * 1024 });
    return stdout;
};

/** One sample of every namespace; `""` is the sampler's own. */
export async function sampleOnce(namespaces: string[], run: Runner = defaultRunner, now: () => number = Date.now): Promise<SockstatSample> {
    const t = now();
    const errors: Array<{ netns: string; error: string }> = [];
    let host: SockstatTcp | undefined;
    const results = await Promise.all(
        namespaces.map(async (netns): Promise<NamespaceSample | undefined> => {
            try {
                const [sockstat, ss] = await Promise.all([
                    run(netns, "cat", ["/proc/net/sockstat"]),
                    run(netns, "ss", ["-tnH", "state", "established"])
                ]);
                const tcp = parseSockstat(sockstat);
                host ??= tcp;
                return { netns, tcpInuse: tcp.inuse, tcpTw: tcp.tw, ...parseSsQueues(ss) };
            } catch (error) {
                errors.push({ netns, error: error instanceof Error ? error.message : String(error) });
                return undefined;
            }
        })
    );
    const sample: SockstatSample = {
        t,
        hostTcpMemPages: host?.mem ?? -1,
        hostTcpOrphan: host?.orphan ?? -1,
        namespaces: results.filter((r): r is NamespaceSample => r !== undefined)
    };
    if (errors.length > 0) {
        sample.errors = errors;
    }
    return sample;
}

/** Samples every `intervalMs` into `outFile` (one JSON line each) until `signal` aborts. */
export async function runSampler(
    namespaces: string[],
    outFile: string,
    intervalMs: number,
    signal: AbortSignal,
    run: Runner = defaultRunner
): Promise<number> {
    const out = fs.openSync(outFile, "a");
    let count = 0;
    try {
        let next = Date.now();
        while (!signal.aborted) {
            const sample = await sampleOnce(namespaces, run);
            fs.writeSync(out, JSON.stringify(sample) + "\n");
            count += 1;
            next += intervalMs;
            const wait = Math.max(0, next - Date.now());
            await new Promise<void>((resolve) => {
                const timer = setTimeout(resolve, wait);
                signal.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
            });
        }
    } finally {
        fs.closeSync(out);
    }
    return count;
}
