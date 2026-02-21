/// <reference types="node" />

import assert from "assert";
import {
  deepEqual,
  evaluateAssertion,
  getNestedValue,
  normalizeForCompare,
} from "../../src/scenarioAssertions.js";

function expectThrows(fn: () => void, message: string): void {
  let thrown = false;
  try {
    fn();
  } catch {
    thrown = true;
  }
  assert.equal(thrown, true, message);
}

// getNestedValue
assert.equal(getNestedValue({ a: { b: 2 } }, "a.b"), 2, "Nested path value");
assert.deepEqual(
  getNestedValue({ a: 1 }, ""),
  { a: 1 },
  "Empty path returns input",
);
assert.equal(
  getNestedValue({ a: { b: 2 } }, "a.c"),
  undefined,
  "Missing path returns undefined",
);

// deepEqual
assert.equal(deepEqual({ a: 1, b: 2 }, { b: 2, a: 1 }), true, "Object order");
assert.equal(deepEqual([1, 2, 3], [1, 2, 3]), true, "Array equality");
assert.equal(deepEqual([1, 2], [1, 2, 3]), false, "Array length mismatch");

// normalizeForCompare
const withToJson = { toJSON: () => ({ a: 1 }) };
assert.deepEqual(
  normalizeForCompare(withToJson),
  { a: 1 },
  "toJSON normalization",
);
assert.deepEqual(
  normalizeForCompare([1, { a: 2 }]),
  [1, { a: 2 }],
  "Array normalization",
);

// evaluateAssertion - equals
evaluateAssertion({ value: 3 }, { path: "value", equals: 3 });
expectThrows(
  () => evaluateAssertion({ value: 3 }, { path: "value", equals: 4 }),
  "equals should fail when mismatch",
);

// evaluateAssertion - exists
evaluateAssertion({ value: null }, { path: "value", exists: true });
evaluateAssertion({ value: undefined }, { path: "value", exists: false });
expectThrows(
  () => evaluateAssertion({ value: undefined }, { path: "value", exists: true }),
  "exists should fail when missing",
);

// evaluateAssertion - greaterThanOrEqual
evaluateAssertion({ value: 5 }, { path: "value", greaterThanOrEqual: 5 });
evaluateAssertion({ value: 6 }, { path: "value", greaterThanOrEqual: 5 });
expectThrows(
  () =>
    evaluateAssertion({ value: 4 }, { path: "value", greaterThanOrEqual: 5 }),
  "greaterThanOrEqual should fail when below threshold",
);

console.log("✅ CLI assertion helpers tests passed");
