// Schema conformance (#175): every field a client receives must exist in the land's schema and
// must not be server-only there. Server event payloads (#154) are also checked for value types,
// so a field sent in another shape than its schema says (a PlayerID as an object, not a string)
// is caught on the wire, whichever frame carried the event. Independent of the server's own conversion, which both the
// convergence check (server projection) and the replay verifier share, so a field the server
// should never send is caught on the wire.

import type { StateTreeView } from "@swiftstatetree/sdk/core";

/** Greppable line printed for each violation. */
export const SCHEMA_VIOLATION_MARKER = "SCHEMA CONFORMANCE VIOLATION";

interface SchemaNode {
  $ref?: string;
  type?: string;
  properties?: Record<string, SchemaNode>;
  additionalProperties?: SchemaNode | boolean;
  items?: SchemaNode;
  required?: string[];
  "x-stateTree"?: {
    sync?: { policy?: string };
    optional?: boolean;
    innerType?: string;
    atomic?: boolean;
    /** Atomic types: the leaf paths in wire order; a positional value has one leaf per path. */
    leafOrder?: string[][];
  };
}

export interface ConformanceSchema {
  defs: Record<string, SchemaNode>;
  lands: Record<string, { stateType: string; events?: Record<string, SchemaNode> }>;
}

export interface ConformanceViolation {
  /** Client path, `/`-separated, with map keys and array indices as given. */
  path: string;
  /** The schema path with map keys and indices as `*` (e.g. `players.*.lastFireTick`). */
  schemaPath: string;
  reason: "not in schema" | "server-only" | "wrong type" | "event not in schema";
  /** For "wrong type": what the schema says and what arrived. */
  detail?: string;
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

/**
 * The value as the wire carried it: SDK classes (Position2, IVec2, ...) through `toJSON()`.
 * Unlike `normalizeForConvergence`, keys whose value is `null` are kept: this check is about
 * which fields a client received, and a server-only optional that is nil still leaked.
 */
function wireValue(value: unknown): unknown {
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const withJSON = value as { toJSON?: () => unknown };
    if (typeof withJSON.toJSON === "function") return withJSON.toJSON();
  }
  return value;
}

/**
 * For an atomic value sent positionally (an array at a node with `leafOrder`): `undefined` when
 * the node isn't atomic or the value isn't an array, else the violations (none when it has one
 * leaf per leaf path, each of its schema type). Only state updates carry this form: server
 * events stay keyed, so `checkTypedValue` reports an array there as a wrong type.
 */
function checkPositional(
  schema: ConformanceSchema,
  resolved: SchemaNode | undefined,
  value: unknown,
  at: { path: string; schemaPath: string }
): ConformanceViolation[] | undefined {
  const leafOrder = resolved?.["x-stateTree"]?.atomic ? resolved["x-stateTree"]?.leafOrder : undefined;
  if (!leafOrder || !Array.isArray(value)) return undefined;
  if (value.length !== leafOrder.length) {
    return [{ ...at, reason: "wrong type", detail: `schema ${leafOrder.length} leaves, received ${value.length}` }];
  }
  const out: ConformanceViolation[] = [];
  leafOrder.forEach((leafPath, i) => {
    const leaf = value[i];
    const name = leafPath.join(".");
    const actual = typeof leaf === "bigint" ? "integer" : jsonType(leaf);
    if (!["integer", "number", "string", "boolean"].includes(actual)) {
      out.push({ ...at, reason: "wrong type", detail: `leaf ${name} is ${actual}` });
      return;
    }
    let leafNode: SchemaNode | undefined = resolved;
    for (const key of leafPath) leafNode = resolve(schema, resolve(schema, leafNode)?.properties?.[key]);
    const expected = leafNode?.type;
    if (expected && !typeMatches(expected, actual)) {
      out.push({ ...at, reason: "wrong type", detail: `leaf ${name}: schema ${expected}, received ${actual}` });
    }
  });
  return out;
}

function checkValue(
  schema: ConformanceSchema,
  node: SchemaNode | undefined,
  value: unknown,
  path: string[],
  schemaPath: string[],
  out: ConformanceViolation[]
): void {
  value = wireValue(value);
  if (value === null || value === undefined || typeof value !== "object") return;
  const positional = checkPositional(schema, resolve(schema, node), value, {
    path: "/" + path.join("/"),
    schemaPath: schemaPath.join("."),
  });
  if (positional) {
    out.push(...positional);
    return;
  }
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
  // Empty segments are keys (`/m/` is the entry of `m` under the key ""); only the root has none.
  const segments = patch.path === "" || patch.path === "/" ? [] : patch.path.split("/").slice(1);
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
    checkValue(schema, node, patch.value, segments, [...schemaPath], out);
  }
  return out;
}

/** The JSON type of `value` as a schema would name it. */
function jsonType(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

/** Whether a value of JSON type `actual` is what a schema `type` allows. */
function typeMatches(expected: string, actual: string): boolean {
  if (expected === actual) return true;
  return expected === "number" && actual === "integer";
}

/** Whether `node` (or a def it refers to) is an optional wrapper, which allows `null`. */
function isOptional(schema: ConformanceSchema, node: SchemaNode | undefined): boolean {
  let current = node;
  for (let depth = 0; current && depth < 16; depth += 1) {
    if (current["x-stateTree"]?.optional) return true;
    if (!current.$ref) return false;
    current = schema.defs[current.$ref.replace("#/defs/", "")];
  }
  return false;
}

/** Value-type and key violations of `value` against `node`, recursively. */
function checkTypedValue(
  schema: ConformanceSchema,
  node: SchemaNode | undefined,
  value: unknown,
  path: string[],
  schemaPath: string[],
  out: ConformanceViolation[]
): void {
  value = wireValue(value);
  const resolved = resolve(schema, node);
  if (!resolved || value === null || value === undefined) return;
  const at = { path: "/" + path.join("/"), schemaPath: schemaPath.join(".") };
  const expected = resolved.type ?? (resolved.properties || resolved.additionalProperties ? "object" : undefined);
  const actual = jsonType(value);
  if (expected && !typeMatches(expected, actual)) {
    out.push({ ...at, reason: "wrong type", detail: `schema ${expected}, received ${actual}` });
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, i) => checkTypedValue(schema, resolved.items, item, [...path, String(i)], [...schemaPath, "*"], out));
    return;
  }
  if (actual !== "object") return;
  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    if (resolved.properties) {
      const property = resolved.properties[key];
      if (!property) {
        out.push({ path: at.path + "/" + key, schemaPath: [...schemaPath, key].join("."), reason: "not in schema" });
        continue;
      }
      // A null is only valid for an optional field: a Swift decoder rejects it for any other.
      if (child === null && resolved.required?.includes(key) && !isOptional(schema, property)) {
        const type = resolve(schema, property)?.type ?? "a value";
        out.push({
          path: at.path + "/" + key,
          schemaPath: [...schemaPath, key].join("."),
          reason: "wrong type",
          detail: `schema ${type}, received null`,
        });
        continue;
      }
      checkTypedValue(schema, property, child, [...path, key], [...schemaPath, key], out);
    } else if (resolved.additionalProperties && typeof resolved.additionalProperties === "object") {
      checkTypedValue(schema, resolved.additionalProperties, child, [...path, key], [...schemaPath, "*"], out);
    }
  }
}

/**
 * Violations in one server event payload (#154): the event must be declared for the land, and
 * every field must be declared and of its schema type. Paths start at `event:<type>`.
 */
export function checkEventPayload(
  schema: ConformanceSchema,
  landType: string,
  eventType: string,
  payload: unknown
): ConformanceViolation[] {
  const land = schema.lands[landType];
  if (!land) return [];
  const root = [`event:${eventType}`];
  const node = land.events?.[eventType];
  if (!node) {
    return [{ path: "/" + root.join("/"), schemaPath: `events.${eventType}`, reason: "event not in schema" }];
  }
  const out: ConformanceViolation[] = [];
  checkTypedValue(schema, node, payload, root, [`events.${eventType}`], out);
  return out;
}

/** Violations in a whole client state. */
export function checkState(schema: ConformanceSchema, landType: string, state: unknown): ConformanceViolation[] {
  const land = schema.lands[landType];
  if (!land) return [];
  const out: ConformanceViolation[] = [];
  checkValue(schema, schema.defs[land.stateType], state, [], [], out);
  return out;
}

/**
 * Checks every state update the view receives (firstSync and diffs) before it is applied, and
 * every server event payload (from event frames and from state updates with merged events)
 * before the SDK decodes it. Returns a function that reports the violations seen so far, once
 * per schema path.
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
  const record = (violation: ConformanceViolation) => {
    const key = `${violation.reason} ${violation.schemaPath}`;
    if (!seen.has(key)) seen.set(key, violation);
  };
  const events = view as unknown as { decodeEventPayload?: (eventType: string, payload: unknown) => unknown };
  const originalDecode = events.decodeEventPayload;
  if (typeof originalDecode !== "function") {
    throw new Error("schema conformance: StateTreeView.decodeEventPayload not found");
  }
  events.decodeEventPayload = function (this: unknown, eventType: string, payload: unknown) {
    checkEventPayload(schema, landType, eventType, payload).forEach(record);
    return originalDecode.call(this, eventType, payload);
  };
  target.handleStateUpdate = function (this: unknown, update: Update) {
    for (const patch of update.patches ?? []) {
      checkPatch(schema, landType, patch).forEach(record);
    }
    return original.call(this, update);
  };
  return () => [...seen.values()];
}

export function formatViolations(clientName: string, violations: ConformanceViolation[]): string[] {
  return violations.map(
    (v) => `${SCHEMA_VIOLATION_MARKER} ${clientName}: ${v.schemaPath} (${v.reason}${v.detail ? `: ${v.detail}` : ""}; first at ${v.path})`
  );
}
