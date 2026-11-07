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
 * The quiet window isn't proof that the last frame arrived: a tail loss waits for a TCP
 * retransmit, longer than 200 ms under the impairments. So a difference isn't final at once. The
 * land stays frozen and its projections fixed, and the connection's state is read again until it
 * matches or `capMs` after the freeze has passed (design § 7). A difference that went away is
 * "converged late", with its delay; only one that lasts to the cap is a mismatch.
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

/** Design § 6: at most 20 lands checked at once. */
export const MAX_CONCURRENCY = 20;

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
    /** Lands checked at once, at most `MAX_CONCURRENCY`. */
    concurrency?: number;
    quietMs?: number;
    settleTimeoutMs?: number;
    /** How long after the freeze a difference may still go away (default 5000, design § 7). */
    capMs?: number;
    /** How often a differing connection's state is read again before the cap (default 100). */
    recheckMs?: number;
    /** No land check starts later than this after the start; the lands left are errors. */
    deadlineMs?: number;
    /** Checks per land in all; the extra ones retry an inconclusive check (default 2: one retry). */
    maxAttempts?: number;
    retryDelayMs?: number;
    /** Differences kept per connection. */
    maxPaths?: number;
    now?: () => number;
    sleep?: (ms: number) => Promise<void>;
}

export type ConnectionOutcome = "converged" | "convergedLate" | "mismatched" | "missing" | "noServerPlayer";

export interface ConnectionResult {
    key: string;
    instance: string;
    player: string;
    serverPlayer?: string;
    reconnected: boolean;
    outcome: ConnectionOutcome;
    /** convergedLate: ms from the freeze until the state matched. */
    lateMs?: number;
    decodeErrors: number;
    differences: number;
    paths: ConvergenceDifference[];
}

export type LandOutcome = "converged" | "convergedLate" | "mismatched" | "missingClients" | "inconclusive" | "error";

export interface LandResult {
    land: string;
    outcome: LandOutcome;
    attempts: number;
    tickId?: number;
    /** convergedLate: the largest of its connections' `lateMs`. */
    lateMs?: number;
    error?: string;
    connections: ConnectionResult[];
}

export interface ConvergenceReport {
    startedAt: number;
    sendingStoppedAt: number;
    endedAt: number;
    /** Connections per land per instance, as the instances listed them before the checks. */
    roster: Record<string, Record<string, number>>;
    lands: LandResult[];
    totals: {
        lands: number;
        converged: number;
        convergedLate: number;
        mismatched: number;
        missingClients: number;
        inconclusive: number;
        errors: number;
        /** The largest `lateMs` of any land. */
        lateMaxMs: number | null;
        /** Connections compared, by whether their session came from a reconnect (design § 6). */
        survivors: { compared: number; converged: number; convergedLate: number };
        reconnected: { compared: number; converged: number; convergedLate: number };
    };
}

export async function runConvergence(options: ConvergenceOptions): Promise<ConvergenceReport> {
    const now = options.now ?? (() => Date.now());
    const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
    const concurrency = Math.max(1, options.concurrency ?? MAX_CONCURRENCY);
    if (concurrency > MAX_CONCURRENCY) {
        throw new Error(`concurrency ${concurrency} is above ${MAX_CONCURRENCY} (design § 6)`);
    }
    const startedAt = now();
    const deadlineAt = options.deadlineMs === undefined ? Infinity : startedAt + options.deadlineMs;
    await Promise.all(options.instances.map((instance) => instance.stopSending()));
    const sendingStoppedAt = now();

    const roster: ConvergenceReport["roster"] = {};
    const landSet = new Set<string>();
    for (const instance of options.instances) {
        const counts: Record<string, number> = (roster[instance.name] = {});
        for (const connection of await instance.lands()) {
            counts[connection.land] = (counts[connection.land] ?? 0) + 1;
            landSet.add(connection.land);
        }
    }
    const lands = [...landSet].sort();
    const results: LandResult[] = new Array(lands.length);
    let next = 0;
    const workers = Array.from({ length: Math.min(concurrency, lands.length) }, async () => {
        while (next < lands.length) {
            const index = next++;
            results[index] = await checkLandWithRetry(lands[index], options, now, sleep, deadlineAt);
        }
    });
    await Promise.all(workers);

    const count = (outcome: LandOutcome) => results.filter((r) => r.outcome === outcome).length;
    const compared = results.flatMap((r) => (r.outcome === "inconclusive" || r.outcome === "error" ? [] : r.connections));
    const rows = (reconnected: boolean) => {
        const subset = compared.filter((c) => c.reconnected === reconnected && c.outcome !== "missing");
        return {
            compared: subset.length,
            converged: subset.filter((c) => c.outcome === "converged").length,
            convergedLate: subset.filter((c) => c.outcome === "convergedLate").length
        };
    };
    const late = results.flatMap((r) => (r.lateMs === undefined ? [] : [r.lateMs]));
    return {
        startedAt,
        sendingStoppedAt,
        endedAt: now(),
        roster,
        lands: results,
        totals: {
            lands: results.length,
            converged: count("converged"),
            convergedLate: count("convergedLate"),
            mismatched: count("mismatched"),
            missingClients: count("missingClients"),
            inconclusive: count("inconclusive"),
            errors: count("error"),
            lateMaxMs: late.length ? Math.max(...late) : null,
            survivors: rows(false),
            reconnected: rows(true)
        }
    };
}

async function checkLandWithRetry(
    land: string,
    options: ConvergenceOptions,
    now: () => number,
    sleep: (ms: number) => Promise<void>,
    deadlineAt: number
): Promise<LandResult> {
    const maxAttempts = Math.max(1, options.maxAttempts ?? 2);
    let result: LandResult | undefined;
    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        if (attempt > 1) await sleep(options.retryDelayMs ?? 200);
        if (now() > deadlineAt) {
            // A check started past the deadline could still be running when the phase ends and
            // the connections close; an unchecked land is an error, not a pass.
            return result ?? { land, outcome: "error", attempts: 0, error: "not checked: the deadline passed", connections: [] };
        }
        result = { ...(await checkLand(land, options, now, sleep)), attempts: attempt };
        if (result.outcome !== "inconclusive") break;
    }
    return result!;
}

type Listed = { instance: string; connection: ConvergenceConnection };

async function checkLand(
    land: string,
    options: ConvergenceOptions,
    now: () => number,
    sleep: (ms: number) => Promise<void>
): Promise<LandResult> {
    const landID = `${options.landType}:${land}`;
    const quietMs = options.quietMs ?? 200;
    const settleTimeoutMs = options.settleTimeoutMs ?? 3000;
    const capMs = options.capMs ?? 5000;
    const recheckMs = options.recheckMs ?? 100;
    const maxPaths = options.maxPaths ?? 5;
    let freeze: FreezeResponse | undefined;
    let result: LandResult;
    try {
        freeze = await options.debug.freeze(landID);
        const frozenAt = now();
        // The settle frames were sent before freeze answered: wait until every connection of the
        // land has been quiet for quietMs. That is the common case's whole wait.
        for (;;) {
            const connections = await landConnections(options.instances, land, false);
            const lastFrameAt = Math.max(frozenAt, ...connections.map(({ connection }) => connection.lastFrameAt ?? 0));
            if (now() - lastFrameAt >= quietMs) break;
            if (now() - frozenAt > settleTimeoutMs) {
                throw new Error(`frames still arriving ${settleTimeoutMs} ms after the freeze`);
            }
            await sleep(Math.min(50, quietMs));
        }
        let membershipChanged = false;
        const results: ConnectionResult[] = [];
        // Open connections with a difference, against their fixed projection.
        const pending = new Map<string, { result: ConnectionResult; server: unknown }>();
        const keyOf = ({ instance, connection }: Listed) => `${instance}/${connection.key}`;
        for (const listed of await landConnections(options.instances, land, true)) {
            const { instance, connection } = listed;
            const base: ConnectionResult = {
                key: connection.key,
                instance,
                player: connection.player,
                serverPlayer: connection.serverPlayer,
                reconnected: connection.reconnected,
                outcome: "converged",
                decodeErrors: connection.decodeErrors,
                differences: 0,
                paths: []
            };
            results.push(base);
            if (!connection.open) {
                base.outcome = "missing";
                continue;
            }
            if (connection.serverPlayer === undefined) {
                base.outcome = "noServerPlayer";
                continue;
            }
            const projection = await options.debug.projection(landID, connection.serverPlayer);
            if (projection.freezeToken !== freeze.freezeToken) {
                throw new Error(`projection of ${landID} belongs to another freeze`);
            }
            membershipChanged ||= projection.membershipChanged;
            const differences = options.compareStates(connection.state, projection.state);
            if (differences.length > 0) {
                setDifferences(base, differences, maxPaths);
                pending.set(keyOf(listed), { result: base, server: projection.state });
            }
        }
        // A difference may be a frame still in a retransmit: read the client again until the cap.
        while (pending.size > 0 && !membershipChanged && now() - frozenAt < capMs) {
            await sleep(recheckMs);
            const current = new Map((await landConnections(options.instances, land, true)).map((l) => [keyOf(l), l.connection]));
            for (const [key, { result: r, server }] of pending) {
                const connection = current.get(key);
                if (!connection?.open) {
                    // Closed while frozen: the check can't see it converge.
                    Object.assign(r, { outcome: "missing", differences: 0, paths: [] });
                    pending.delete(key);
                    continue;
                }
                const differences = options.compareStates(connection.state, server);
                if (differences.length === 0) {
                    Object.assign(r, { outcome: "convergedLate", lateMs: now() - frozenAt, differences: 0, paths: [] });
                    pending.delete(key);
                } else {
                    setDifferences(r, differences, maxPaths);
                }
            }
        }
        for (const { result: r } of pending.values()) r.outcome = "mismatched";
        const outcome: LandOutcome = membershipChanged
            ? "inconclusive"
            : results.some((r) => r.outcome === "mismatched" || r.outcome === "noServerPlayer")
              ? "mismatched"
              : results.some((r) => r.outcome === "missing")
                ? "missingClients"
                : results.length === 0
                  ? "error"
                  : results.some((r) => r.outcome === "convergedLate")
                    ? "convergedLate"
                    : "converged";
        const lates = results.flatMap((r) => (r.lateMs === undefined ? [] : [r.lateMs]));
        result = {
            land,
            outcome,
            attempts: 1,
            tickId: freeze.tickId,
            connections: results,
            ...(outcome === "convergedLate" ? { lateMs: Math.max(...lates) } : {}),
            ...(results.length === 0 ? { error: "no connections" } : {})
        };
    } catch (error) {
        result = { land, outcome: "error", attempts: 1, tickId: freeze?.tickId, error: error instanceof Error ? error.message : String(error), connections: [] };
    }
    if (freeze) {
        const resumeError = await resume(options, landID, freeze.freezeToken, sleep);
        if (resumeError !== undefined) {
            // A land left frozen stops its game for the rest of the run: an error, whatever it compared.
            const prior = result.error ? `; ${result.error}` : "";
            result = { ...result, outcome: "error", error: `resume failed twice: ${resumeError}${prior}` };
        }
    }
    return result;
}

/** Resumes, retrying once. Returns the second failure's message, or undefined on success. */
async function resume(options: ConvergenceOptions, landID: string, token: string, sleep: (ms: number) => Promise<void>): Promise<string | undefined> {
    for (let attempt = 1; ; attempt += 1) {
        try {
            await options.debug.resume(landID, token);
            return undefined;
        } catch (error) {
            if (attempt >= 2) return error instanceof Error ? error.message : String(error);
            await sleep(options.retryDelayMs ?? 200);
        }
    }
}

function setDifferences(result: ConnectionResult, differences: ConvergenceDifference[], maxPaths: number): void {
    result.differences = differences.length;
    result.paths = differences.slice(0, maxPaths);
}

async function landConnections(instances: ConvergenceInstance[], land: string, withStates: boolean): Promise<Listed[]> {
    const replies = await Promise.all(
        instances.map(async (instance) =>
            (await instance.lands([land], withStates ? [land] : undefined)).map((connection) => ({ instance: instance.name, connection }))
        )
    );
    return replies.flat();
}
