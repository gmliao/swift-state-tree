// Schema conformance (#175): every field a client receives must exist in the land's schema and
// must not be server-only there. Independent of the server's own conversion, which both the
// convergence check (server projection) and the replay verifier share, so a field the server
// should never send is caught on the wire.

import type { StateTreeView } from "@swiftstatetree/sdk/core";
import { normalizeForConvergence } from "./convergence.js";

/** Greppable line printed for each violation. */
export const SCHEMA_VIOLATION_MARKER = "SCHEMA CONFORMANCE VIOLATION";

interface SchemaNode {
  $ref?: string;
  type?: string;
  properties?: Record<string, SchemaNode>;
  additionalProperties?: SchemaNode | boolean;
  items?: SchemaNode;
  "x-stateTree"?: { sync?: { policy?: string }; optional?: boolean; innerType?: string };
}

export interface ConformanceSchema {
  defs: Record<string, SchemaNode>;
  lands: Record<string, { stateType: string }>;
}

export interface ConformanceViolation {
  /** Client path, `/`-separated, with map keys and array indices as given. */
  path: string;
  /** The schema path with map keys and indices as `*` (e.g. `players.*.lastFireTick`). */
  schemaPath: string;
  reason: "not in schema" | "server-only";
}

/** Follows `$ref` and optional wrappers to the node that describes a present value. */
function resolve(schema: ConformanceSchema, node: SchemaNode | undefined): SchemaNode | undefined {
  let current = node;
  for (let depth = 0; current && depth < 16; depth += 1) {
    if (current.$ref) {
      current = schema.defs[current.$ref.replace("#/defs/", "")];
      continue;
    }
    const meta = current["x-stateTree"];
    if (meta?.optional && meta.innerType && schema.defs[meta.innerType]) {
      current = schema.defs[meta.innerType];
      continue;
    }
    return current;
  }
  return current;
}

/** The schema node one segment below `node`, or the violation for that segment. */
function step(
  schema: ConformanceSchema,
  node: SchemaNode | undefined,
  segment: string
): { node?: SchemaNode; star: boolean; violation?: ConformanceViolation["reason"] } {
  const resolved = resolve(schema, node);
  if (!resolved) return { star: false };
  if (resolved.properties) {
    const property = resolved.properties[segment];
    if (!property) {
      // A closed object: a key it does not declare is never sent.
      return { star: false, violation: "not in schema" };
    }
    if (property["x-stateTree"]?.sync?.policy === "serverOnly") {
      return { node: property, star: false, violation: "server-only" };
    }
    return { node: property, star: false };
  }
  if (resolved.additionalProperties && typeof resolved.additionalProperties === "object") {
    return { node: resolved.additionalProperties, star: true };
  }
  if (resolved.items) {
    return { node: resolved.items, star: true };
  }
  // A leaf or an untyped object: nothing below it to check.
  return { star: false };
}

function checkValue(
  schema: ConformanceSchema,
  node: SchemaNode | undefined,
  value: unknown,
  path: string[],
  schemaPath: string[],
  out: ConformanceViolation[]
): void {
  if (value === null || value === undefined || typeof value !== "object") return;
  const entries: Array<[string, unknown]> = Array.isArray(value)
    ? value.map((v, i) => [String(i), v])
    : Object.entries(value as Record<string, unknown>);
  for (const [key, child] of entries) {
    const next = step(schema, node, key);
    const childPath = [...path, key];
    const childSchemaPath = [...schemaPath, next.star ? "*" : key];
    if (next.violation) {
      out.push({ path: "/" + childPath.join("/"), schemaPath: childSchemaPath.join("."), reason: next.violation });
      if (next.violation === "not in schema") continue;
    }
    if (next.node) checkValue(schema, next.node, child, childPath, childSchemaPath, out);
  }
}

/** Violations in one patch: its path, then the value it carries. */
export function checkPatch(
  schema: ConformanceSchema,
  landType: string,
  patch: { path: string; value?: unknown }
): ConformanceViolation[] {
  const land = schema.lands[landType];
  if (!land) return [];
  const out: ConformanceViolation[] = [];
  let node: SchemaNode | undefined = schema.defs[land.stateType];
  const segments = patch.path.split("/").filter((s) => s.length > 0);
  const schemaPath: string[] = [];
  for (const [i, segment] of segments.entries()) {
    const next = step(schema, node, segment);
    schemaPath.push(next.star ? "*" : segment);
    if (next.violation) {
      out.push({ path: "/" + segments.slice(0, i + 1).join("/"), schemaPath: schemaPath.join("."), reason: next.violation });
      if (next.violation === "not in schema") return out;
    }
    node = next.node;
    if (!node) return out;
  }
  if (patch.value !== undefined) {
    checkValue(schema, node, normalizeForConvergence(patch.value), segments, [...schemaPath], out);
  }
  return out;
}

/** Violations in a whole client state. */
export function checkState(schema: ConformanceSchema, landType: string, state: unknown): ConformanceViolation[] {
  const land = schema.lands[landType];
  if (!land) return [];
  const out: ConformanceViolation[] = [];
  checkValue(schema, schema.defs[land.stateType], normalizeForConvergence(state), [], [], out);
  return out;
}

/**
 * Checks every state update the view receives (firstSync and diffs) before it is applied.
 * Returns a function that reports the violations seen so far, once per schema path.
 */
export function watchSchemaConformance(
  view: StateTreeView,
  schema: ConformanceSchema,
  landType: string
): () => ConformanceViolation[] {
  type Update = { type: string; patches?: Array<{ path: string; value?: unknown }> };
  const target = view as unknown as { handleStateUpdate?: (update: Update) => void };
  const original = target.handleStateUpdate;
  if (typeof original !== "function") {
    throw new Error("schema conformance: StateTreeView.handleStateUpdate not found");
  }
  const seen = new Map<string, ConformanceViolation>();
  target.handleStateUpdate = function (this: unknown, update: Update) {
    for (const patch of update.patches ?? []) {
      for (const violation of checkPatch(schema, landType, patch)) {
        const key = `${violation.reason} ${violation.schemaPath}`;
        if (!seen.has(key)) seen.set(key, violation);
      }
    }
    return original.call(this, update);
  };
  return () => [...seen.values()];
}

export function formatViolations(clientName: string, violations: ConformanceViolation[]): string[] {
  return violations.map(
    (v) => `${SCHEMA_VIOLATION_MARKER} ${clientName}: ${v.schemaPath} (${v.reason}; first at ${v.path})`
  );
}
