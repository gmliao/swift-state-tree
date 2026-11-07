// State convergence check (#79): freeze the land, let the settle sync arrive, then compare each
// client's reconstructed state with the server's projection of the same state copy.
//
// Since the ordered outbound writer (#60), a land's frames arrive in issue order, so the settle
// frames are the last ones of the frozen state. The CLI reports state mismatches only unless
// gating is on; the E2E scripts turn gating on by default. Route, auth, timeout and projection
// errors are always fatal.

import { compareStates, type ConvergenceDifference, type StateTreeView } from "@swiftstatetree/sdk/core";

/** Greppable line printed for each report-only mismatch. */
export const MISMATCH_MARKER = "CONVERGENCE MISMATCH (report-only)";
/** Line printed for each mismatch when mismatches fail the script. */
export const GATING_MISMATCH_MARKER = "CONVERGENCE MISMATCH (gating)";
/** Greppable line printed when a join or leave during the freeze made the check inconclusive. */
export const INCONCLUSIVE_MARKER = "CONVERGENCE INCONCLUSIVE (membership changed)";

// MARK: - Comparison semantics

// The comparison lives in the SDK, shared with the load client's convergence coordinator.
export {
  normalizeForConvergence,
  UnsafeInteger,
  diffNormalized,
  compareStates,
  type ConvergenceDifference,
} from "@swiftstatetree/sdk/core";

// MARK: - Debug state routes

/** A route, auth, timeout or projection failure. Always fatal, also in report-only mode. */
export class ConvergenceInfraError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "ConvergenceInfraError";
  }
}

export type FreezeResponse = {
  freezeToken: string;
  tickId: number;
  freezeCount: number;
  reused: boolean;
};

export type ProjectionResponse = {
  freezeToken: string;
  tickId: number;
  playerID?: string | null;
  membershipChanged: boolean;
  state: Record<string, unknown>;
};

export type ResumeResponse = { freezeCount: number; resumed: boolean };

export type DebugStateClientOptions = {
  /** Admin base URL, e.g. `http://localhost:8080`. */
  adminUrl: string;
  apiKey: string;
  /** Per-request timeout. */
  requestTimeoutMs?: number;
};

/** Client for `/admin/lands/:landID/debug/{freeze,projection,resume}`. */
export class DebugStateClient {
  constructor(private readonly options: DebugStateClientOptions) {}

  freeze(landID: string): Promise<FreezeResponse> {
    return this.request<FreezeResponse>("POST", landID, "freeze");
  }

  projection(landID: string, playerID?: string): Promise<ProjectionResponse> {
    const query = playerID ? `?playerID=${encodeURIComponent(playerID)}` : "";
    return this.request<ProjectionResponse>("GET", landID, `projection${query}`);
  }

  resume(landID: string, freezeToken: string): Promise<ResumeResponse> {
    return this.request<ResumeResponse>(
      "POST",
      landID,
      `resume?freezeToken=${encodeURIComponent(freezeToken)}`,
    );
  }

  private async request<T>(method: string, landID: string, route: string): Promise<T> {
    const base = this.options.adminUrl.replace(/\/+$/, "");
    const url = `${base}/admin/lands/${encodeURIComponent(landID)}/debug/${route}`;
    const label = `${method} ${route.split("?")[0]} (${landID})`;
    let response: Response;
    try {
      response = await fetch(url, {
        method,
        headers: { "X-API-Key": this.options.apiKey },
        signal: AbortSignal.timeout(this.options.requestTimeoutMs ?? 15000),
      });
    } catch (error) {
      throw new ConvergenceInfraError(`${label} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    const text = await response.text();
    let body: { success?: boolean; data?: T; error?: { message?: string } } | undefined;
    try {
      body = text ? JSON.parse(text) : undefined;
    } catch {
      body = undefined;
    }
    if (!response.ok || !body?.success || body.data === undefined) {
      const detail = body?.error?.message ?? text.slice(0, 200);
      throw new ConvergenceInfraError(`${label} answered HTTP ${response.status}: ${detail}`, response.status);
    }
    return body.data;
  }
}

// MARK: - Check

export type ConvergenceClient = {
  /** Label for output, e.g. `client-0`. */
  name: string;
  view: StateTreeView;
  playerID: string;
};

export type ConvergenceCheckOptions = {
  label?: string;
  /** Quiet window after the freeze in which no client may receive a patch. */
  quietMs?: number;
  /** Upper bound for waiting on the quiet window. */
  settleTimeoutMs?: number;
  /** Differences printed per client. */
  maxPaths?: number;
  log?: (line: string) => void;
};

export type ClientConvergence = {
  name: string;
  playerID: string;
  differences: ConvergenceDifference[];
};

export type ConvergenceResult = {
  label: string;
  tickId: number;
  membershipChanged: boolean;
  clients: ClientConvergence[];
  /** True when no client differs and membership did not change. */
  converged: boolean;
};

/**
 * Run one convergence check for all clients of a land, as the single coordinator: one freeze,
 * a barrier until every client has been quiet for `quietMs`, one projection per client, and
 * one resume (always, also when a step throws). Callers must not send while it runs.
 */
export async function checkConvergence(
  debug: DebugStateClient,
  landID: string,
  clients: ConvergenceClient[],
  options: ConvergenceCheckOptions = {},
): Promise<ConvergenceResult> {
  const label = options.label ?? "assertConverged";
  const quietMs = options.quietMs ?? 200;
  const settleTimeoutMs = options.settleTimeoutMs ?? 3000;

  let lastPatchAt = Date.now();
  const unsubscribes = clients.map((client) =>
    client.view.onPatch(() => {
      lastPatchAt = Date.now();
    }),
  );

  const log = options.log ?? ((line: string) => console.warn(line));
  let freeze: FreezeResponse | undefined;
  let checkError: unknown;
  try {
    freeze = await debug.freeze(landID);
    // Barrier: the settle frames were sent before freeze answered; wait until every client
    // has applied them (no patch for `quietMs`).
    const freezeAnsweredAt = Date.now();
    lastPatchAt = Math.max(lastPatchAt, freezeAnsweredAt);
    while (Date.now() - lastPatchAt < quietMs) {
      if (Date.now() - freezeAnsweredAt > settleTimeoutMs) {
        throw new ConvergenceInfraError(
          `${label}: clients still received patches ${settleTimeoutMs}ms after the freeze`,
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    let membershipChanged = false;
    const results: ClientConvergence[] = [];
    for (const client of clients) {
      const projection = await debug.projection(landID, client.playerID);
      if (projection.freezeToken !== freeze.freezeToken) {
        throw new ConvergenceInfraError(`${label}: projection belongs to another freeze`);
      }
      membershipChanged ||= projection.membershipChanged;
      results.push({
        name: client.name,
        playerID: client.playerID,
        differences: compareStates(client.view.getState(), projection.state),
      });
    }
    return {
      label,
      tickId: freeze.tickId,
      membershipChanged,
      clients: results,
      converged: !membershipChanged && results.every((r) => r.differences.length === 0),
    };
  } catch (error) {
    checkError = error;
    throw error;
  } finally {
    unsubscribes.forEach((unsubscribe) => unsubscribe());
    if (freeze) {
      try {
        const resume = await debug.resume(landID, freeze.freezeToken);
        if (!resume.resumed && resume.freezeCount === 0) {
          // The token was stale: the server already auto-resumed, so the check outlived it.
          log(`⚠️  ${label}: resume answered resumed=false (freeze already released, e.g. by auto-resume)`);
        }
      } catch (resumeError) {
        // Never hide the error that ended the check; report the resume failure next to it.
        if (checkError !== undefined) {
          log(`⚠️  ${label}: resume failed after an earlier error: ${String(resumeError)}`);
        } else {
          throw resumeError;
        }
      }
    }
  }
}

// MARK: - Retrying an inconclusive check (#226)

export type ConvergenceAttemptOptions = {
  /** Checks in all, at least 1 (default 3). */
  maxAttempts?: number;
  /** Wait between attempts, ms (default 200: two sync intervals of the game land). */
  retryDelayMs?: number;
  /** Mismatches, and a check that stays inconclusive, fail the step. */
  gating: boolean;
  /** Replaced in tests. */
  sleep?: (ms: number) => Promise<void>;
};

/** The outcome of one `assertConverged` step over its attempts. */
export type ConvergenceStepResult = {
  /** The deciding attempt: the first conclusive one, or the last when none was. */
  result: ConvergenceResult;
  /** Every attempt's result, in order. */
  attempts: ConvergenceResult[];
  outcome: "converged" | "mismatch" | "inconclusive";
};

/** Thrown when every attempt was inconclusive under gating. */
export class ConvergenceInconclusiveError extends Error {}

/**
 * Runs `check` until one attempt is conclusive (membership did not change during it), at most
 * `maxAttempts` times, `retryDelayMs` apart. Each attempt is a full check with its own freeze
 * and resume (`checkConvergence` resumes in its `finally` on every path), so a retry never
 * starts with the land frozen. An error from `check` (route, auth, timeout, projection) is not
 * the membership race: it ends the step at once, without a retry. Under gating, a step whose
 * every attempt was inconclusive throws `ConvergenceInconclusiveError`; a mismatch is returned
 * for the caller to report (and, under gating, to fail).
 */
export async function runConvergenceAttempts(
  check: () => Promise<ConvergenceResult>,
  options: ConvergenceAttemptOptions,
): Promise<ConvergenceStepResult> {
  const maxAttempts = Math.max(1, Math.floor(options.maxAttempts ?? 3));
  const retryDelayMs = options.retryDelayMs ?? 200;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const attempts: ConvergenceResult[] = [];
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    if (attempt > 1) await sleep(retryDelayMs);
    const result = await check();
    attempts.push(result);
    if (!result.membershipChanged) {
      return { result, attempts, outcome: result.converged ? "converged" : "mismatch" };
    }
  }
  const last = attempts[attempts.length - 1];
  if (options.gating) {
    throw new ConvergenceInconclusiveError(
      `State convergence was inconclusive after ${attempts.length} attempt(s) (${last.label}); membership kept changing`,
    );
  }
  return { result: last, attempts, outcome: "inconclusive" };
}

/**
 * The line for one inconclusive attempt: `INCONCLUSIVE_MARKER`, the attempt number and, when
 * its comparison differed, the mismatch it saw. That mismatch does not count (membership
 * changed, so the comparison is not valid), but a later attempt that mismatches too then
 * shows it was there before the retry.
 */
export function formatInconclusiveAttempt(result: ConvergenceResult, attempt: number, of: number): string {
  const differing = result.clients.filter((client) => client.differences.length > 0);
  const paths = differing.reduce((sum, client) => sum + client.differences.length, 0);
  const seen = paths > 0 ? ` mismatchedPaths=${paths} first=${differing[0].differences[0].path}` : "";
  return `${INCONCLUSIVE_MARKER} ${result.label} tick=${result.tickId} attempt=${attempt}/${of}${seen}`;
}

/**
 * Lines describing a result; mismatch lines start with `MISMATCH_MARKER`, or with
 * `GATING_MISMATCH_MARKER` when `gating` is set.
 */
export function formatConvergence(result: ConvergenceResult, maxPaths = 10, gating = false): string[] {
  if (result.membershipChanged) {
    return [`${INCONCLUSIVE_MARKER} ${result.label} tick=${result.tickId}`];
  }
  const lines: string[] = [];
  for (const client of result.clients) {
    if (client.differences.length === 0) continue;
    lines.push(
      `${gating ? GATING_MISMATCH_MARKER : MISMATCH_MARKER} ${result.label} tick=${result.tickId} ${client.name} player=${client.playerID} paths=${client.differences.length}`,
    );
    for (const diff of client.differences.slice(0, maxPaths)) {
      lines.push(`  ${diff.path}: client=${stringify(diff.client)} server=${stringify(diff.server)}`);
    }
    if (client.differences.length > maxPaths) {
      lines.push(`  ... ${client.differences.length - maxPaths} more`);
    }
  }
  return lines;
}

function stringify(value: unknown): string {
  if (value === undefined) return "<absent>";
  const text = JSON.stringify(value);
  return text.length > 120 ? `${text.slice(0, 117)}...` : text;
}

// MARK: - Fault injection

/**
 * Drop the next diff patch whose path starts with `pathPrefix` (negative test for the check).
 * Only `diff` updates are filtered, so the joiner's firstSync stays intact and the dropped
 * change cannot be repaired by it. Lives in the CLI wrapper, not the SDK: it wraps the view's
 * `handleStateUpdate`. Returns a function reporting the dropped path, if any.
 */
export function injectDropOnePatch(view: StateTreeView, pathPrefix: string): () => string | undefined {
  type Update = { type: string; patches: Array<{ path: string }> };
  const target = view as unknown as { handleStateUpdate?: (update: Update) => void };
  const original = target.handleStateUpdate;
  if (typeof original !== "function") {
    throw new Error("fault injection: StateTreeView.handleStateUpdate not found");
  }
  let dropped: string | undefined;
  target.handleStateUpdate = function (this: unknown, update: Update) {
    if (dropped === undefined && update.type === "diff") {
      const index = update.patches.findIndex((patch) => patch.path.startsWith(pathPrefix));
      if (index >= 0) {
        dropped = update.patches[index].path;
        update = { ...update, patches: update.patches.filter((_, i) => i !== index) };
      }
    }
    return original.call(this, update);
  };
  return () => dropped;
}
