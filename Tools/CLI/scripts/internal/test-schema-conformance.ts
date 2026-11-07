/// <reference types="node" />
// Unit tests for the schema conformance check (#175): server-only and undeclared fields are
// caught in patch paths and in patch values, through maps, arrays, `$ref` and optionals.

import assert from "assert";
import { readFileSync } from "fs";
import { checkEventPayload, checkPatch, checkState, type ConformanceSchema } from "../../src/schema-conformance.js";
import { decodeMessage, pathHashReverseLookup, type StateUpdate, type TransportEncodingConfig } from "@swiftstatetree/sdk/core";

const schema: ConformanceSchema = {
  lands: { probe: { stateType: "Root" } },
  defs: {
    Root: {
      properties: {
        players: { type: "object", additionalProperties: { $ref: "#/defs/Player" } },
        list: { type: "array", items: { $ref: "#/defs/Player" } },
        maybe: { $ref: "#/defs/Optional<Player>" },
        counter: { type: "integer", "x-stateTree": { sync: { policy: "serverOnly" } } },
        score: { type: "integer", "x-stateTree": { sync: { policy: "broadcast" } } },
        paths: { type: "object", additionalProperties: { type: "array", items: { $ref: "#/defs/Position2" } } },
        maybePath: { $ref: "#/defs/Optional<Array<Position2>>" },
        maybePaths: { $ref: "#/defs/Optional<Dictionary<String, Array<Position2>>>" },
      },
    },
    "Optional<Array<Position2>>": { type: "object", "x-stateTree": { optional: true, innerType: "Array<Position2>" } },
    "Array<Position2>": { type: "array", items: { $ref: "#/defs/Position2" } },
    "Optional<Dictionary<String, Array<Position2>>>": {
      type: "object",
      "x-stateTree": { optional: true, innerType: "Dictionary<String, Array<Position2>>" },
    },
    "Dictionary<String, Array<Position2>>": {
      type: "object",
      additionalProperties: { type: "array", items: { $ref: "#/defs/Position2" } },
    },
    Player: {
      properties: {
        name: { type: "string", "x-stateTree": { sync: { policy: "broadcast" } } },
        position: { $ref: "#/defs/Position2" },
        lastFireTick: { type: "integer", "x-stateTree": { sync: { policy: "serverOnly" } } },
      },
    },
    "Optional<Player>": { type: "object", "x-stateTree": { optional: true, innerType: "Player" } },
    Position2: {
      properties: { v: { $ref: "#/defs/IVec2" } },
      "x-stateTree": { atomic: true, leafOrder: [["v", "x"], ["v", "y"]] },
    },
    IVec2: { properties: { x: { type: "integer" }, y: { type: "integer" } } },
  },
};

const found = (patch: { path: string; value?: unknown }) =>
  checkPatch(schema, "probe", patch).map((v) => `${v.reason} ${v.schemaPath}`);

// Clean patches.
assert.deepEqual(found({ path: "/score", value: 3 }), []);
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", position: { v: { x: 1, y: 2 } } } }), []);
assert.deepEqual(found({ path: "/players/alice/position/v/x", value: 4 }), []);
assert.deepEqual(found({ path: "/players/alice" }), [], "a removal carries no value");

// Atomic values sent positionally (one scalar per leaf path), also nested in a value.
assert.deepEqual(found({ path: "/players/alice/position", value: [1000, 2000] }), []);
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", position: [1000, 2000] } }), []);
assert.deepEqual(found({ path: "/players", value: { bob: { position: [1000, 2000] } } }), []);
assert.deepEqual(found({ path: "/list/0/position", value: [1, 2, 3] }), ["wrong type list.*.position"]);
assert.deepEqual(found({ path: "/players/alice", value: { position: [1000, { x: 1 }] } }), ["wrong type players.*.position"]);
// Arrays of atomic values in maps and optionals (#272), positional at every element.
assert.deepEqual(found({ path: "/paths/a", value: [[1000, 2000]] }), []);
assert.deepEqual(found({ path: "/paths/a/0", value: [1000, 2000] }), []);
assert.deepEqual(found({ path: "/maybePath", value: [[1000, 2000], [3000, 4000]] }), []);
assert.deepEqual(found({ path: "/maybePath", value: null }), []);
assert.deepEqual(found({ path: "/maybePath/1", value: [1000, 2000] }), []);
assert.deepEqual(found({ path: "/maybePaths", value: { a: [[1000, 2000]] } }), []);
assert.deepEqual(found({ path: "/maybePaths/a/0", value: [1000] }), ["wrong type maybePaths.*.*"]);
assert.deepEqual(found({ path: "/maybePath/0", value: [1000, true] }), ["wrong type maybePath.*"]);
// Each leaf is checked against its own schema type.
const foundDetail = (patch: { path: string; value?: unknown }) =>
  checkPatch(schema, "probe", patch).map((v) => `${v.reason} ${v.schemaPath} (${v.detail})`);
assert.deepEqual(foundDetail({ path: "/players/alice/position", value: [true, "bad"] }), [
  "wrong type players.*.position (leaf v.x: schema integer, received boolean)",
  "wrong type players.*.position (leaf v.y: schema integer, received string)",
]);
assert.deepEqual(foundDetail({ path: "/players/alice/position", value: [1.5, 2] }), [
  "wrong type players.*.position (leaf v.x: schema integer, received number)",
]);
assert.deepEqual(found({ path: "/players/alice/position", value: [1000n, 2000] }), [], "a bigint leaf is an integer");
assert.deepEqual(foundDetail({ path: "/players/alice/position", value: [null, 2] }), [
  "wrong type players.*.position (leaf v.x is null)",
]);

// Server-only fields: in the path, in a value, in arrays, optionals and at the root.
assert.deepEqual(found({ path: "/counter", value: 1 }), ["server-only counter"]);
assert.deepEqual(found({ path: "/players/alice/lastFireTick", value: 9 }), ["server-only players.*.lastFireTick"]);
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", lastFireTick: 9 } }), ["server-only players.*.lastFireTick"]);
assert.deepEqual(found({ path: "/players", value: { bob: { lastFireTick: 1 } } }), ["server-only players.*.lastFireTick"]);
assert.deepEqual(found({ path: "/list/0", value: { lastFireTick: 1 } }), ["server-only list.*.lastFireTick"]);
assert.deepEqual(found({ path: "/maybe", value: { lastFireTick: 1 } }), ["server-only maybe.lastFireTick"]);
assert.deepEqual(found({ path: "", value: { counter: 1, score: 2 } }), ["server-only counter"], "a root firstSync value");

// A key sent with a null value was still sent: a nil server-only optional leaks too.
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", lastFireTick: null, extra: null } }), [
  "server-only players.*.lastFireTick",
  "not in schema players.*.extra",
]);
assert.deepEqual(
  checkState(schema, "probe", { players: { a: { lastFireTick: null } } }).map((v) => v.schemaPath),
  ["players.*.lastFireTick"],
);
// SDK classes are read through toJSON(), as on the wire.
const position = { toJSON: () => ({ v: { x: 1, y: 2 } }) };
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", position } }), []);
assert.deepEqual(found({ path: "/players/alice", value: { position: { toJSON: () => ({ v: { x: 1, z: 2 } }) } } }), [
  "not in schema players.*.position.v.z",
]);

// Fields the schema does not declare.
assert.deepEqual(found({ path: "/players/alice/extra", value: 1 }), ["not in schema players.*.extra"]);
assert.deepEqual(found({ path: "/players/alice", value: { name: "a", extra: { deep: 1 } } }), ["not in schema players.*.extra"]);
assert.deepEqual(found({ path: "/players/alice/position", value: { v: { x: 1, y: 2, z: 3 } } }), ["not in schema players.*.position.v.z"]);
assert.deepEqual(found({ path: "/unknown", value: 1 }), ["not in schema unknown"]);

// Whole state, and an unknown land is not checked.
assert.deepEqual(
  checkState(schema, "probe", { score: 1, players: { a: { name: "a", lastFireTick: 2 } } }).map((v) => v.schemaPath),
  ["players.*.lastFireTick"],
);
assert.deepEqual(checkPatch(schema, "other", { path: "/counter", value: 1 }), []);

// The GameDemo schema marks the fields #175 leaked as server-only.
const game = JSON.parse(readFileSync(new URL("../../../../Examples/GameDemo/schema.json", import.meta.url), "utf-8")) as ConformanceSchema;
const gameFound = (land: string, patch: { path: string; value?: unknown }) => checkPatch(game, land, patch).map((v) => v.schemaPath);
assert.deepEqual(gameFound("hero-defense", { path: "/players/p1", value: { health: 1, lastFireTick: 3 } }), ["players.*.lastFireTick"]);
assert.deepEqual(gameFound("visibility-test", { path: "/entities/e1", value: { id: "e1", step: { x: 1, y: 1 }, visibleTo: [] } }), [
  "entities.*.step",
  "entities.*.visibleTo",
]);
assert.deepEqual(gameFound("hero-defense", { path: "/monsters/1", value: { health: 1, reward: 5 } }), ["monsters.*.reward"]);

// Server event payloads (#154): declared fields, of their schema type.
const eventSchema: ConformanceSchema = {
  lands: { probe: { stateType: "Root", events: { Shot: { $ref: "#/defs/ShotEvent" } } } },
  defs: {
    Root: { properties: {} },
    PlayerID: { type: "string" },
    ShotEvent: {
      type: "object",
      properties: {
        playerID: { $ref: "#/defs/PlayerID" },
        owners: { type: "array", items: { $ref: "#/defs/PlayerID" } },
        hits: { type: "object", additionalProperties: { type: "integer" } },
        from: { $ref: "#/defs/Position2" },
        ratio: { type: "number" },
        assist: { $ref: "#/defs/Optional<PlayerID>" },
        note: { type: "string" },
      },
      required: ["playerID", "owners", "hits", "from", "ratio", "assist"],
    },
    "Optional<PlayerID>": { type: "object", "x-stateTree": { optional: true, innerType: "PlayerID" } },
    Position2: {
      properties: { v: { $ref: "#/defs/IVec2" } },
      "x-stateTree": { atomic: true, leafOrder: [["v", "x"], ["v", "y"]] },
    },
    IVec2: { properties: { x: { type: "integer" }, y: { type: "integer" } } },
  },
};
const eventFound = (type: string, payload: unknown) =>
  checkEventPayload(eventSchema, "probe", type, payload).map((v) => `${v.reason} ${v.schemaPath}${v.detail ? ` (${v.detail})` : ""}`);
const shot = { playerID: "p1", owners: ["p2"], hits: { p3: 2 }, from: { v: { x: 1, y: 2 } }, ratio: 1 };
assert.deepEqual(eventFound("Shot", shot), [], "every field in its schema shape");
assert.deepEqual(eventFound("Shot", { ...shot, ratio: 0.5 }), [], "an integer or a fraction is a number");
// The pre-#154 identifier shape is the wrong type, wherever it appears.
assert.deepEqual(eventFound("Shot", { ...shot, playerID: { rawValue: "p1" } }), [
  "wrong type events.Shot.playerID (schema string, received object)",
]);
assert.deepEqual(eventFound("Shot", { ...shot, owners: [{ rawValue: "p2" }] }), [
  "wrong type events.Shot.owners.* (schema string, received object)",
]);
// The old key/value array form of an identifier-keyed map.
assert.deepEqual(eventFound("Shot", { ...shot, hits: [{ rawValue: "p3" }, 2] }), [
  "wrong type events.Shot.hits (schema object, received array)",
]);
assert.deepEqual(eventFound("Shot", { ...shot, from: { v: { x: "1", y: 2 } } }), [
  "wrong type events.Shot.from.v.x (schema integer, received string)",
]);
assert.deepEqual(eventFound("Shot", { ...shot, extra: 1 }), ["not in schema events.Shot.extra"]);
// Events stay keyed: an atomic value in the positional form is the wrong type there.
assert.deepEqual(eventFound("Shot", { ...shot, from: [1000, 2000] }), [
  "wrong type events.Shot.from (schema object, received array)",
]);
// A null is only valid for an optional field.
assert.deepEqual(eventFound("Shot", { ...shot, playerID: null }), ["wrong type events.Shot.playerID (schema string, received null)"]);
assert.deepEqual(eventFound("Shot", { ...shot, assist: null }), [], "an optional field may be null");
assert.deepEqual(eventFound("Shot", { ...shot, assist: "p4" }), [], "and holds its inner type");
assert.deepEqual(eventFound("Shot", { ...shot, note: null }), [], "a field not in required may be null");
assert.deepEqual(eventFound("Unknown", {}), ["event not in schema events.Unknown"]);
assert.deepEqual(checkEventPayload(eventSchema, "other", "Shot", { playerID: {} }), [], "an unknown land is not checked");

// The GameDemo schema: PlayerShoot's playerID is a string.
const gameEvent = (payload: unknown) => checkEventPayload(game, "hero-defense", "PlayerShoot", payload).map((v) => `${v.reason} ${v.schemaPath}`);
const shotPosition = { v: { x: 1000, y: 2000 } };
assert.deepEqual(gameEvent({ playerID: "p1", from: shotPosition, to: shotPosition }), []);
assert.deepEqual(gameEvent({ playerID: { rawValue: "p1" }, from: shotPosition, to: shotPosition }), ["wrong type events.PlayerShoot.playerID"]);

// Every collection shape from the Swift fixture (#272): each wire value conforms.
const shapes: { schema: ConformanceSchema; landType: string; cases: { name: string; path: string; wire: unknown }[] } = JSON.parse(
  readFileSync(new URL("../../../../Tests/SwiftStateTreeTransportTests/Fixtures/AtomicArrayShapes/atomic-array-shapes.json", import.meta.url), "utf-8"),
);
assert.ok(shapes.cases.length >= 13, "a case for every shape");
for (const c of shapes.cases) {
  assert.deepEqual(checkPatch(shapes.schema, shapes.landType, { path: c.path, value: c.wire }), [], c.name);
}

// The shape matrix (#284): every raw frame Swift encoded, in both opcode formats, decodes to a
// patch whose path and value are the fixture's, and that patch conforms.
const matrix: {
  schema: ConformanceSchema & { lands: Record<string, { pathHashes?: Record<string, number> }> };
  landType: string;
  cases: { name: string; path: string; wire: unknown; jsonFrame: string; messagePackFrame: string; knownIssue: number | null }[];
} = JSON.parse(
  readFileSync(new URL("../../../../Tests/SwiftStateTreeTransportTests/Fixtures/ShapeMatrix/shape-matrix.json", import.meta.url), "utf-8"),
);
pathHashReverseLookup.clear();
for (const [pattern, hash] of Object.entries(matrix.schema.lands[matrix.landType].pathHashes ?? {})) {
  pathHashReverseLookup.set(hash, pattern);
}
// The one failure each open issue causes here, and the step it happens in (as in sdk/ts
// view-shape-matrix.test.ts); any other failure is a real one.
const knownFailures: Record<number, { step: "decode" | "path"; message: RegExp }> = {
  289: { step: "path", message: /: decoded path$/ },
};

function expectKnownFailure(issue: number, label: string, step: () => void): void {
  let failure: unknown;
  try {
    step();
  } catch (error) {
    failure = error;
  }
  if (failure === undefined) throw new Error(`${label}: known issue #${issue} passes now; remove its marker`);
  const text = failure instanceof Error ? failure.message : String(failure);
  if (!knownFailures[issue]?.message.test(text)) throw failure;
}

for (const [message, frame] of [
  ["opcodeJsonArray", (c: (typeof matrix.cases)[number]) => c.jsonFrame],
  ["messagepack", (c: (typeof matrix.cases)[number]) => new Uint8Array(Buffer.from(c.messagePackFrame, "base64"))],
] as const) {
  const keys = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>() };
  for (const c of matrix.cases) {
    const config = { message, stateUpdate: "opcodeJsonArray" } as TransportEncodingConfig;
    const known = c.knownIssue == null ? undefined : knownFailures[c.knownIssue];
    if (c.knownIssue != null && !known) throw new Error(`${c.name}: no known failure for #${c.knownIssue}`);
    let update: StateUpdate | undefined;
    const decode = () => {
      update = decodeMessage(frame(c), config, keys) as StateUpdate;
    };
    if (known?.step === "decode") {
      expectKnownFailure(c.knownIssue!, `${message} ${c.name}`, decode);
      continue;
    }
    decode();
    const path = () => assert.deepEqual(update!.patches.map((p) => p.path), [c.path], `${message} ${c.name}: decoded path`);
    assert.deepEqual(update!.patches.map((p) => p.value), [c.wire], `${message} ${c.name}: wire value`);
    assert.deepEqual(checkPatch(matrix.schema, matrix.landType, { path: c.path, value: update!.patches[0].value }), [], `${message} ${c.name}`);
    if (known?.step === "path") {
      expectKnownFailure(c.knownIssue!, `${message} ${c.name}`, path);
      continue;
    }
    path();
  }
}

// A mutant: a different failure in a known-issue case is not taken as that issue.
assert.throws(
  () => expectKnownFailure(289, "mutant", () => { throw new Error("Dynamic key slot 3 used before definition"); }),
  (error: Error) => error.message === "Dynamic key slot 3 used before definition",
);
assert.throws(() => expectKnownFailure(289, "mutant", () => assert.equal(1, 2, "mutant: wire value")), /mutant: wire value/);
assert.throws(() => expectKnownFailure(289, "mutant", () => {}), /known issue #289 passes now/);
expectKnownFailure(289, "own", () => { throw new Error("c: decoded path"); });

// An empty map key is a key (`/players/` is the entry under ""), not the map itself.
const emptyKey = (path: string, value: unknown) => checkPatch(schema, "probe", { path, value }).map((v) => `${v.reason} ${v.schemaPath}`);
assert.deepEqual(emptyKey("/players/", { name: "n", position: { v: { x: 1, y: 2 } } }), []);
assert.deepEqual(emptyKey("/players//lastFireTick", 3), ["server-only players.*.lastFireTick"]);

console.log("schema conformance unit tests passed");
