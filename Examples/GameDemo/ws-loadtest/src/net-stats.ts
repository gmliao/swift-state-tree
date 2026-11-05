import fs from "node:fs";

/** Kernel TCP listen-queue counters (Linux `/proc/net/netstat`, `TcpExt` section). */
export interface ListenCounters {
    listenOverflows: number;
    listenDrops: number;
}

/**
 * Parses `/proc/net/netstat`: each section is a header line (`TcpExt: Name1 Name2 ...`) followed
 * by a value line (`TcpExt: 1 2 ...`). Returns undefined when the TcpExt counters are missing.
 */
export function parseListenCounters(netstat: string): ListenCounters | undefined {
    const lines = netstat.split("\n").filter((line) => line.startsWith("TcpExt:"));
    if (lines.length < 2) {
        return undefined;
    }
    const names = lines[0].trim().split(/\s+/).slice(1);
    const values = lines[1].trim().split(/\s+/).slice(1).map(Number);
    const get = (name: string) => {
        const i = names.indexOf(name);
        return i >= 0 && Number.isFinite(values[i]) ? values[i] : undefined;
    };
    const listenOverflows = get("ListenOverflows");
    const listenDrops = get("ListenDrops");
    if (listenOverflows === undefined || listenDrops === undefined) {
        return undefined;
    }
    return { listenOverflows, listenDrops };
}

/**
 * Reads this host's counters, or undefined where `/proc/net/netstat` doesn't exist (macOS) or
 * can't be read. They are host-wide (or network-namespace-wide in a container), so they describe
 * the server's listen queue only when the server runs on the same host or namespace.
 */
export function readListenCounters(path = "/proc/net/netstat"): ListenCounters | undefined {
    try {
        return parseListenCounters(fs.readFileSync(path, "utf-8"));
    } catch {
        return undefined;
    }
}

export function counterDelta(before?: ListenCounters, after?: ListenCounters): ListenCounters | undefined {
    if (!before || !after) {
        return undefined;
    }
    return {
        listenOverflows: after.listenOverflows - before.listenOverflows,
        listenDrops: after.listenDrops - before.listenDrops
    };
}
