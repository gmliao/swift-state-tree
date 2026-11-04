// State convergence check (#79): freeze the land, let the settle sync arrive, then compare each
// client's reconstructed state with the server's projection of the same state copy.
//
// Until the ordered-writer work (#60) lands, frames of an earlier cycle can arrive after the
// settle frames, so state mismatches are report-only by default. Route, auth, timeout and
// projection errors are always fatal.

import type { StateTreeView } from "@swiftstatetree/sdk/core";

/** Greppable line printed for each report-only mismatch. */
export const MISMATCH_MARKER = "CONVERGENCE MISMATCH (report-only)";
/** Line printed for each mismatch when mismatches fail the script. */
export const GATING_MISMATCH_MARKER = "CONVERGENCE MISMATCH (gating)";
/** Greppable line printed when a join or leave during the freeze made the check inconclusive. */
export const INCONCLUSIVE_MARKER = "CONVERGENCE INCONCLUSIVE (membership changed)";

// MARK: - Comparison semantics

/**
 * Normalize a value for convergence comparison. Both sides go through the same function:
 * - SDK classes (Position2, IVec2, Angle, ...) are reduced through `toJSON()`, which yields the
 *   raw fixed-point integers the state wire carries (e.g. `{ v: { x: 1500, y: -250 } }`).
 * - Object keys whose value is `null` or `undefined` are dropped: a nil optional may reach the
 *   client as an explicit `null` or as a removed key, and both mean "no value".
 * - `bigint` (MessagePack 64-bit integers) becomes a `number`, the type JSON decoding yields.
 * - An integer outside the safe range (|n| > 2^53 - 1, from a `bigint` or a JSON number) becomes
 *   an `UnsafeInteger`, which never compares equal: both decoders may round two different
 *   64-bit values to the same number, so equality there would be a false "converged".
 * - Key order does not matter (the comparison is key-set based).
 */
export function normalizeForConvergence(value: unknown): unknown {
  if (value === null || value === undefined) return null;
  if (typeof value === "bigint") {
    const asNumber = Number(value);
    return Number.isSafeInteger(asNumber) ? asNumber : new UnsafeInteger(value.toString());
  }
  if (typeof value === "number" && Number.isInteger(value) && !Number.isSafeInteger(value)) {
    return new UnsafeInteger(String(value));
  }
  if (value instanceof UnsafeInteger) return value;
  if (Array.isArray(value)) return value.map((item) => normalizeForConvergence(item));
  if (typeof value === "object") {
    const withJSON = value as { toJSON?: () => unknown };
    if (typeof withJSON.toJSON === "function") {
      return normalizeForConvergence(withJSON.toJSON());
    }
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(value as object).sort()) {
      const normalized = normalizeForConvergence((value as Record<string, unknown>)[key]);
      if (normalized !== null) result[key] = normalized;
    }
    return result;
  }
  return value;
}

/** An integer that cannot be compared exactly after decoding; always reported as a difference. */
export class UnsafeInteger {
  constructor(readonly digits: string) {}
  toJSON(): string {
    return `<unsafe integer ${this.digits}>`;
  }
}

export type ConvergenceDifference = {
  /** JSON-pointer style path, e.g. `/players/p1/position/v/x`. */
  path: string;
  client: unknown;
  server: unknown;
};

/**
 * Differences between two normalized values, depth first. A key present on one side only is
 * reported with `undefined` on the other side.
 */
export function diffNormalized(
  client: unknown,
  server: unknown,
  path = "",
  out: ConvergenceDifference[] = [],
): ConvergenceDifference[] {
  if (client instanceof UnsafeInteger || server instanceof UnsafeInteger) {
    out.push({ path: path || "/", client, server });
    return out;
  }
  if (Object.is(client, server)) return out;
  const bothObjects =
    typeof client === "object" && client !== null &&
    typeof server === "object" && server !== null;
  if (bothObjects && Array.isArray(client) === Array.isArray(server)) {
    if (Array.isArray(client) && Array.isArray(server)) {
      const length = Math.max(client.length, server.length);
      for (let i = 0; i < length; i += 1) {
        diffNormalized(client[i], server[i], `${path}/${i}`, out);
      }
      return out;
    }
    const c = client as Record<string, unknown>;
    const s = server as Record<string, unknown>;
    const keys = [...new Set([...Object.keys(c), ...Object.keys(s)])].sort();
    for (const key of keys) {
      diffNormalized(c[key], s[key], `${path}/${key}`, out);
    }
    return out;
  }
  out.push({ path: path || "/", client, server });
  return out;
}

/** Compare a client state with a server projection; returns the differing paths. */
export function compareStates(clientState: unknown, serverState: unknown): ConvergenceDifference[] {
  return diffNormalized(normalizeForConvergence(clientState), normalizeForConvergence(serverState));
}

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
