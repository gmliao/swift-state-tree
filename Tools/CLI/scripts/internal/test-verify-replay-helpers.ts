/**
 * Unit tests for verify-replay-helpers (replay verification position logic).
 * Run: npm run test:cli:unit (includes this file)
 */
import assert from "assert";
import {
  BASE_X,
  BASE_Y,
  NEAR_BASE_RADIUS,
  parseArgs,
  getPositionXY,
  distance,
  isBasePositionOk,
  isNearBase,
  analyzeReplayState,
  getEntityCounts,
  updateMaxEntityCounts,
  evaluateEntityThresholds,
} from "../../src/verify-replay-helpers";

// parseArgs
assert.deepStrictEqual(parseArgs([]), {}, "parseArgs empty");
assert.deepStrictEqual(parseArgs(["--admin-url=http://x"]), { "admin-url": "http://x" }, "parseArgs single");
assert.deepStrictEqual(
  parseArgs(["--a=1", "--b=2"]),
  { a: "1", b: "2" },
  "parseArgs multiple"
);
assert.deepStrictEqual(parseArgs(["x", "--record-path=/p"]), { "record-path": "/p" }, "parseArgs skips non-flag");

// getPositionXY
assert.strictEqual(getPositionXY(null), null, "getPositionXY null");
assert.strictEqual(getPositionXY(undefined), null, "getPositionXY undefined");
assert.strictEqual(getPositionXY({}), null, "getPositionXY empty object");
assert.deepStrictEqual(
  getPositionXY({ position: { v: { x: 64, y: 36 } } }),
  { x: 64, y: 36 },
  "getPositionXY position.v.x/y float"
);
assert.deepStrictEqual(
  getPositionXY({ position: { v: { x: 64000, y: 36000 } } }),
  { x: 64, y: 36 },
  "getPositionXY position.v fixed-point (÷1000)"
);
assert.deepStrictEqual(
  getPositionXY({ position: { x: 65, y: 37 } }),
  { x: 65, y: 37 },
  "getPositionXY position.x/y"
);
assert.deepStrictEqual(
  getPositionXY({ v: { x: 64, y: 36 } }),
  { x: 64, y: 36 },
  "getPositionXY v.x/y"
);

// distance
assert.strictEqual(distance(0, 0, 3, 4), 5, "distance 3-4-5");
assert.strictEqual(distance(64, 36, 64, 36), 0, "distance same point");
assert.ok(distance(64, 36, 70, 40) > 0 && distance(64, 36, 70, 40) < 10, "distance small delta");

// isBasePositionOk
assert.strictEqual(isBasePositionOk(null), false, "isBasePositionOk null");
assert.strictEqual(isBasePositionOk({ x: 64, y: 36 }), true, "isBasePositionOk exact");
assert.strictEqual(isBasePositionOk({ x: 64.5, y: 36.5 }), true, "isBasePositionOk within 1");
assert.strictEqual(isBasePositionOk({ x: 0, y: 0 }), false, "isBasePositionOk far");

// isNearBase
assert.strictEqual(isNearBase(64, 36), true, "isNearBase center");
assert.strictEqual(isNearBase(64 + 5, 36), true, "isNearBase within radius");
assert.strictEqual(isNearBase(64 + NEAR_BASE_RADIUS, 36), true, "isNearBase on radius");
assert.strictEqual(isNearBase(64 + NEAR_BASE_RADIUS + 1, 36), false, "isNearBase outside radius");

// analyzeReplayState
assert.deepStrictEqual(
  analyzeReplayState(undefined),
  { basePos: null, baseOk: false, playerEntries: [], nearBaseCount: 0, playersWithPosition: 0 },
  "analyzeReplayState undefined"
);
assert.deepStrictEqual(
  analyzeReplayState(null as any),
  { basePos: null, baseOk: false, playerEntries: [], nearBaseCount: 0, playersWithPosition: 0 },
  "analyzeReplayState null"
);

const stateWithBaseOnly = {
  base: { position: { v: { x: 64000, y: 36000 } } },
  players: {},
  monsters: {},
  turrets: {},
};
const a1 = analyzeReplayState(stateWithBaseOnly as any);
assert.ok(a1.basePos !== null && a1.basePos.x === 64 && a1.basePos.y === 36, "analyzeReplayState base decoded");
assert.strictEqual(a1.baseOk, true, "analyzeReplayState baseOk");
assert.strictEqual(a1.playerEntries.length, 0, "analyzeReplayState no players");
assert.strictEqual(a1.playersWithPosition, 0, "analyzeReplayState playersWithPosition 0");

const stateWithPlayerNearBase = {
  base: { position: { v: { x: 64, y: 36 } } },
  players: {
    "p1": { position: { v: { x: 66, y: 38 } } },
  },
  monsters: {},
  turrets: {},
};
const a2 = analyzeReplayState(stateWithPlayerNearBase as any);
assert.strictEqual(a2.baseOk, true, "analyzeReplayState with player baseOk");
assert.strictEqual(a2.playerEntries.length, 1, "analyzeReplayState one player");
assert.strictEqual(a2.playersWithPosition, 1, "analyzeReplayState playersWithPosition 1");
assert.strictEqual(a2.nearBaseCount, 1, "analyzeReplayState nearBaseCount 1");

const stateWithPlayerFar = {
  base: { position: { v: { x: 64, y: 36 } } },
  players: {
    "p1": { position: { v: { x: 100, y: 50 } } },
  },
  monsters: {},
  turrets: {},
};
const a3 = analyzeReplayState(stateWithPlayerFar as any);
assert.strictEqual(a3.nearBaseCount, 0, "analyzeReplayState player far from base");
assert.strictEqual(a3.playersWithPosition, 1, "analyzeReplayState playersWithPosition still 1");

// getEntityCounts
assert.deepStrictEqual(
  getEntityCounts({
    players: { p1: {} },
    monsters: { 1: {}, 2: {} },
    turrets: {},
  } as any),
  { players: 1, monsters: 2, turrets: 0 },
  "getEntityCounts counts entity collections"
);
assert.deepStrictEqual(
  getEntityCounts(undefined),
  { players: 0, monsters: 0, turrets: 0 },
  "getEntityCounts handles undefined"
);

// updateMaxEntityCounts
assert.deepStrictEqual(
  updateMaxEntityCounts(
    { players: 1, monsters: 0, turrets: 2 },
    { players: 2, monsters: 1, turrets: 1 }
  ),
  { players: 2, monsters: 1, turrets: 2 },
  "updateMaxEntityCounts tracks max seen values"
);

// evaluateEntityThresholds
const thresholdPass = evaluateEntityThresholds(
  { players: 1, monsters: 3, turrets: 0 },
  { minPlayers: 1, minMonsters: 1, minTurrets: 0 }
);
assert.strictEqual(thresholdPass.ok, true, "evaluateEntityThresholds pass");
assert.deepStrictEqual(thresholdPass.failures, [], "evaluateEntityThresholds no failures when pass");

const thresholdFail = evaluateEntityThresholds(
  { players: 0, monsters: 0, turrets: 0 },
  { minPlayers: 1, minMonsters: 1, minTurrets: 0 }
);
assert.strictEqual(thresholdFail.ok, false, "evaluateEntityThresholds fail");
assert.ok(
  thresholdFail.failures.some((f) => f.includes("players")),
  "evaluateEntityThresholds reports players failure"
);
assert.ok(
  thresholdFail.failures.some((f) => f.includes("monsters")),
  "evaluateEntityThresholds reports monsters failure"
);

console.log("All verify-replay-helpers tests passed.");
process.exit(0);
