import type { ConvergenceDifference } from "./reconstruction";
import type { ConvergenceConnection } from "./worker";

/**
 * The convergence coordinator of the network impairment runs (design § 6): one driver for every
 * client instance. It stops every instance's sends, then checks each land, at most `concurrency`
 * at a time, with the `Tools/CLI` protocol (#79): freeze, wait until no connection of the land
 * applied a patch for `quietMs`, fetch each player's projection, compare it with that
 * connection's reconstructed state (`compareStates`, shared with the CLI through the SDK), resume.
 * A land whose membership changed during the check is inconclusive and retried (#226).
 *
 * Coverage is every land and every expected connection: an instance reports every connection it
 * holds, open or not, and one that isn't open is a missing client.
 */

/** One client instance, through its control socket (`control.ts`). */
export interface ConvergenceInstance {
    name: string;
    stopSending(): Promise<void>;
    lands(only?: string[], withStates?: string[]): Promise<ConvergenceConnection[]>;
}

export interface FreezeResponse {
    freezeToken: string;
    tickId: number;
}

export interface ProjectionResponse {
    freezeToken: string;
    membershipChanged: boolean;
    state: Record<string, unknown>;
}

/** The admin debug routes `/admin/lands/:landID/debug/{freeze,projection,resume}`. */
export interface DebugStateApi {
    freeze(landID: string): Promise<FreezeResponse>;
    projection(landID: string, playerID: string): Promise<ProjectionResponse>;
    resume(landID: string, freezeToken: string): Promise<unknown>;
}

export interface ConvergenceOptions {
    instances: ConvergenceInstance[];
    debug: DebugStateApi;
    compareStates(client: unknown, server: unknown): ConvergenceDifference[];
    landType: string;
    /** Lands checked at once (design § 6: at most 20). */
    concurrency?: number;
    quietMs?: number;
    settleTimeoutMs?: number;
    /** Checks per land in all; the extra ones retry an inconclusive check (default 2: one retry). */
    maxAttempts?: number;
    retryDelayMs?: number;
    /** Differences kept per connection. */
    maxPaths?: number;
    now?: () => number;
    sleep?: (ms: number) => Promise<void>;
}

export type ConnectionOutcome = "converged" | "mismatched" | "missing" | "noServerPlayer";

export interface ConnectionResult {
    key: string;
    instance: string;
    player: string;
    serverPlayer?: string;
    reconnected: boolean;
    outcome: ConnectionOutcome;
    decodeErrors: number;
    differences: number;
    paths: ConvergenceDifference[];
}

export type LandOutcome = "converged" | "mismatched" | "missingClients" | "inconclusive" | "error";

export interface LandResult {
    land: string;
    outcome: LandOutcome;
    attempts: number;
    tickId?: number;
    error?: string;
    connections: ConnectionResult[];
}

export interface ConvergenceReport {
    startedAt: number;
    sendingStoppedAt: number;
    endedAt: number;
    lands: LandResult[];
    totals: {
        lands: number;
        converged: number;
        mismatched: number;
        missingClients: number;
        inconclusive: number;
        errors: number;
        /** Connections compared, by whether their session came from a reconnect (design § 6). */
        survivors: { compared: number; converged: number };
        reconnected: { compared: number; converged: number };
    };
}

export async function runConvergence(options: ConvergenceOptions): Promise<ConvergenceReport> {
    const now = options.now ?? (() => Date.now());
    const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
    const concurrency = Math.max(1, options.concurrency ?? 20);
    const startedAt = now();
    await Promise.all(options.instances.map((instance) => instance.stopSending()));
    const sendingStoppedAt = now();

    const byLand = new Map<string, number>();
    for (const instance of options.instances) {
        for (const connection of await instance.lands()) {
            byLand.set(connection.land, (byLand.get(connection.land) ?? 0) + 1);
        }
    }
    const lands = [...byLand.keys()].sort();
    const results: LandResult[] = new Array(lands.length);
    let next = 0;
    const workers = Array.from({ length: Math.min(concurrency, lands.length) }, async () => {
        while (next < lands.length) {
            const index = next++;
            results[index] = await checkLandWithRetry(lands[index], options, now, sleep);
        }
    });
    await Promise.all(workers);

    const count = (outcome: LandOutcome) => results.filter((r) => r.outcome === outcome).length;
    const compared = results.flatMap((r) => (r.outcome === "inconclusive" || r.outcome === "error" ? [] : r.connections));
    const rows = (reconnected: boolean) => {
        const subset = compared.filter((c) => c.reconnected === reconnected && c.outcome !== "missing");
        return { compared: subset.length, converged: subset.filter((c) => c.outcome === "converged").length };
    };
    return {
        startedAt,
        sendingStoppedAt,
        endedAt: now(),
        lands: results,
        totals: {
            lands: results.length,
            converged: count("converged"),
            mismatched: count("mismatched"),
            missingClients: count("missingClients"),
            inconclusive: count("inconclusive"),
            errors: count("error"),
            survivors: rows(false),
            reconnected: rows(true)
        }
    };
}

async function checkLandWithRetry(
    land: string,
    options: ConvergenceOptions,
    now: () => number,
    sleep: (ms: number) => Promise<void>
): Promise<LandResult> {
    const maxAttempts = Math.max(1, options.maxAttempts ?? 2);
    let result: LandResult | undefined;
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        if (attempt > 1) await sleep(options.retryDelayMs ?? 200);
        result = { ...(await checkLand(land, options, now, sleep)), attempts: attempt };
        if (result.outcome !== "inconclusive") break;
    }
    return result!;
}

async function checkLand(
    land: string,
    options: ConvergenceOptions,
    now: () => number,
    sleep: (ms: number) => Promise<void>
): Promise<LandResult> {
    const landID = `${options.landType}:${land}`;
    const quietMs = options.quietMs ?? 200;
    const settleTimeoutMs = options.settleTimeoutMs ?? 3000;
    const maxPaths = options.maxPaths ?? 5;
    let freeze: FreezeResponse | undefined;
    try {
        freeze = await options.debug.freeze(landID);
        const frozenAt = now();
        // The settle frames were sent before freeze answered: wait until every connection of the
        // land has been quiet for quietMs.
        let connections: Array<{ instance: string; connection: ConvergenceConnection }>;
        for (;;) {
            connections = await landConnections(options.instances, land, false);
            const lastPatchAt = Math.max(frozenAt, ...connections.map(({ connection }) => connection.lastPatchAt ?? 0));
            if (now() - lastPatchAt >= quietMs) break;
            if (now() - frozenAt > settleTimeoutMs) {
                return { land, outcome: "error", attempts: 1, tickId: freeze.tickId, error: `patches still arriving ${settleTimeoutMs} ms after the freeze`, connections: [] };
            }
            await sleep(Math.min(50, quietMs));
        }
        connections = await landConnections(options.instances, land, true);
        let membershipChanged = false;
        const results: ConnectionResult[] = [];
        for (const { instance, connection } of connections) {
            const base = {
                key: connection.key,
                instance,
                player: connection.player,
                serverPlayer: connection.serverPlayer,
                reconnected: connection.reconnected,
                decodeErrors: connection.decodeErrors,
                differences: 0,
                paths: []
            };
            if (!connection.open) {
                results.push({ ...base, outcome: "missing" });
                continue;
            }
            if (connection.serverPlayer === undefined) {
                results.push({ ...base, outcome: "noServerPlayer" });
                continue;
            }
            const projection = await options.debug.projection(landID, connection.serverPlayer);
            if (projection.freezeToken !== freeze.freezeToken) {
                throw new Error(`projection of ${landID} belongs to another freeze`);
            }
            membershipChanged ||= projection.membershipChanged;
            const differences = options.compareStates(connection.state, projection.state);
            results.push({
                ...base,
                outcome: differences.length === 0 ? "converged" : "mismatched",
                differences: differences.length,
                paths: differences.slice(0, maxPaths)
            });
        }
        const outcome: LandOutcome = membershipChanged
            ? "inconclusive"
            : results.some((r) => r.outcome === "mismatched" || r.outcome === "noServerPlayer")
              ? "mismatched"
              : results.some((r) => r.outcome === "missing")
                ? "missingClients"
                : results.length === 0
                  ? "error"
                  : "converged";
        return { land, outcome, attempts: 1, tickId: freeze.tickId, connections: results, ...(results.length === 0 ? { error: "no connections" } : {}) };
    } catch (error) {
        return { land, outcome: "error", attempts: 1, tickId: freeze?.tickId, error: error instanceof Error ? error.message : String(error), connections: [] };
    } finally {
        if (freeze) {
            await options.debug.resume(landID, freeze.freezeToken).catch(() => undefined);
        }
    }
}

async function landConnections(
    instances: ConvergenceInstance[],
    land: string,
    withStates: boolean
): Promise<Array<{ instance: string; connection: ConvergenceConnection }>> {
    const replies = await Promise.all(
        instances.map(async (instance) =>
            (await instance.lands([land], withStates ? [land] : undefined)).map((connection) => ({ instance: instance.name, connection }))
        )
    );
    return replies.flat();
}
