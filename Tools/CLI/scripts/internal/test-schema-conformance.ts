/// <reference types="node" />
// Unit tests for the schema conformance check (#175): server-only and undeclared fields are
// caught in patch paths and in patch values, through maps, arrays, `$ref` and optionals.

import assert from "assert";
import { readFileSync } from "fs";
import { checkPatch, checkState, type ConformanceSchema } from "../../src/schema-conformance.js";

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
      },
    },
    Player: {
      properties: {
        name: { type: "string", "x-stateTree": { sync: { policy: "broadcast" } } },
        position: { $ref: "#/defs/Position2" },
        lastFireTick: { type: "integer", "x-stateTree": { sync: { policy: "serverOnly" } } },
      },
    },
    "Optional<Player>": { type: "object", "x-stateTree": { optional: true, innerType: "Player" } },
    Position2: { properties: { v: { $ref: "#/defs/IVec2" } } },
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

console.log("schema conformance unit tests passed");
