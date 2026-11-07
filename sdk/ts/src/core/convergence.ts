// State comparison for convergence checks (#79), shared by the CLI's E2E check and the load
// client's convergence coordinator, so both judge "converged" by one definition.

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
