/**
 * Unit tests for sync-output-verdict (the E2E "compared > 0" check).
 * Run: npm run test:cli:unit (includes this file)
 */
import assert from "assert";
import { assertSyncOutputCompared, parseSyncOutput } from "../../src/sync-output-verdict";

const passed =
  "   Sync Stream: recorded (7 outputs, 2 markers)\n" +
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 7/0/0, per-player 7/0/0, events 7/0/0, seed 1/0/0, apply 15/0/0]\n";
const parsed = parseSyncOutput(passed);
assert.ok(parsed, "parses a passed line");
assert.strictEqual(parsed.verdict, "passed");
assert.deepStrictEqual(parsed.scopes["per-player"], { compared: 7, unverifiable: 0, skipped: 0 });
assert.deepStrictEqual(parsed.scopes["apply"], { compared: 15, unverifiable: 0, skipped: 0 });
assert.doesNotThrow(() => assertSyncOutputCompared(passed), "passed with every scope compared");

const partial =
  "   Sync Output: partial [compared/unverifiable/skipped: broadcast 3/0/0, per-player 3/2/0, seed 1/1/0, apply 6/0/0]; 2 events after the last output\n";
assert.strictEqual(assertSyncOutputCompared(partial).verdict, "partial", "partial is allowed when everything compared");

const nothingCompared =
  "   Sync Output: partial [compared/unverifiable/skipped: broadcast 0/0/0, per-player 0/0/0, seed 0/0/0, apply 0/0/0]\n";
assert.throws(() => assertSyncOutputCompared(nothingCompared), /compared nothing/, "0 compared fails");

const noEvents =
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 2/0/0, per-player 2/0/0, events 0/0/1, seed 1/0/0, apply 4/0/0]\n";
assert.throws(() => assertSyncOutputCompared(noEvents), /"events" compared nothing/, "events present but never compared fails");

const failed =
  "   Sync Output: FAILED: sync output mismatch at tick 3, output 0 (tick, sequence 12), check: hash, scope: broadcast [compared/unverifiable/skipped: broadcast 3/0/0, per-player 3/0/0, seed 1/0/0, apply 5/0/0]\n";
assert.strictEqual(parseSyncOutput(failed)?.verdict, "failed");
assert.throws(() => assertSyncOutputCompared(failed), /not verified/, "failed fails");

assert.throws(() => assertSyncOutputCompared("   Sync Output: skipped (record 2.1 predates syncConfig)\n"), /not verified/, "skipped fails");
assert.throws(() => assertSyncOutputCompared("no verdict here\n"), /no "Sync Output:" line/, "missing line fails");

console.log("✅ sync-output-verdict tests passed");
