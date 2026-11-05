/**
 * When new connections open.
 * - `ramp`: about `ratePerSecond` connections per second over all workers, each with a jitter
 *   inside its slot, so the server's accept queue never sees a single burst.
 * - `burst`: every new connection at once (the legacy behaviour; join-storm tests).
 */
export type ConnectMode = "ramp" | "burst";

export const CONNECT_MODES: readonly ConnectMode[] = ["ramp", "burst"];

/**
 * How connections a phase no longer needs (and all connections at the end) are closed.
 * - `clean` (default): a close frame, waiting for the handshake.
 * - `abrupt`: the socket is dropped without a close frame, as the tool before the long-lived
 *   workers did when each phase's workers exited; the server sees FIN or RST, depending on
 *   unread data.
 */
export type BoundaryMode = "clean" | "abrupt";

export const BOUNDARY_MODES: readonly BoundaryMode[] = ["clean", "abrupt"];

/**
 * Workers that open new connections in a phase. The ramp rate is split over these only, so the
 * total stays at `--connect-rate` when a phase adds connections on just some workers. Both the
 * scheduler (`connectDelaysMs`) and the ramp check (`rampDurationMs`) use this count.
 */
export function connectingWorkers(newPerWorker: number[]): number {
    return newPerWorker.filter((n) => n > 0).length;
}

/**
 * The longest time any worker needs to open its new connections, in ms: the worker with the
 * most new connections opens them at `ratePerSecond / connectingWorkers`. 0 in burst mode.
 */
export function rampDurationMs(newPerWorker: number[], mode: ConnectMode, ratePerSecond: number): number {
    if (mode === "burst") {
        return 0;
    }
    const most = Math.max(0, ...newPerWorker);
    return (most * Math.max(connectingWorkers(newPerWorker), 1) * 1000) / Math.max(ratePerSecond, 1);
}

/**
 * Default ramp rate over all workers. 1000/s keeps the accept queue far below the server's
 * default listen backlog of 4096: the queue only fills if accepts stall for about 4 s.
 */
export const DEFAULT_CONNECT_RATE = 1000;

/**
 * Stable 32-bit hash for reproducible jitter: FNV-1a followed by the murmur3 finalizer. The
 * finalizer matters because keys often differ only in their last characters (`...-s0`,
 * `...-s1`), which plain FNV-1a barely spreads into the high bits that set the offset.
 */
export function hash32(text: string): number {
    let h = 0x811c9dc5;
    for (let i = 0; i < text.length; i += 1) {
        h ^= text.charCodeAt(i);
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    h ^= h >>> 16;
    h = Math.imul(h, 0x85ebca6b) >>> 0;
    h ^= h >>> 13;
    h = Math.imul(h, 0xc2b2ae35) >>> 0;
    h ^= h >>> 16;
    return h >>> 0;
}

/**
 * Delay in ms before each of a worker's new connections opens, in the given order. With `ramp`,
 * this worker's share of the rate is `ratePerSecond / connectingWorkers` (see `connectingWorkers`);
 * connection i opens in slot
 * i with a jitter inside the slot derived from its key, so delays are increasing and
 * reproducible.
 */
export function connectDelaysMs(
    keys: string[],
    mode: ConnectMode,
    ratePerSecond: number,
    connectingWorkerCount: number
): number[] {
    if (mode === "burst" || keys.length === 0) {
        return keys.map(() => 0);
    }
    const workerRate = Math.max(ratePerSecond, 1) / Math.max(connectingWorkerCount, 1);
    const slotMs = 1000 / workerRate;
    return keys.map((key, i) => (i + hash32(key) / 0x1_0000_0000) * slotMs);
}
