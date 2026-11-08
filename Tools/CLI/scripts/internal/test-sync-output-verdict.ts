/**
 * Unit tests for sync-output-verdict (the E2E "compared > 0" check).
 * Run: npm run test:cli:unit (includes this file)
 */
import assert from "assert";
import { assertSyncOutputCompared, inTurnSyncEnabled, parseSyncOutput } from "../../src/sync-output-verdict";

const passed =
  "   Sync Stream: recorded (7 outputs, 2 markers)\n" +
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 7/0/0, per-player 7/0/0, events 7/0/0, seed 1/0/0, apply 15/0/0]\n";
const parsed = parseSyncOutput(passed);
assert.ok(parsed, "parses a passed line");
assert.strictEqual(parsed.verdict, "passed");
assert.deepStrictEqual(parsed.scopes["per-player"], { compared: 7, unverifiable: 0, skipped: 0 });
assert.deepStrictEqual(parsed.scopes["apply"], { compared: 15, unverifiable: 0, skipped: 0 });
assert.doesNotThrow(() => assertSyncOutputCompared(passed, true), "passed with every scope compared");

assert.strictEqual(parsed.tailEventsNotSynced, 0);

// A live copy whose last event comes after its last output passes, with the tail counted.
const tail =
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 32/0/0, per-player 88/0/0, events 32/0/0, seed 5/0/0, apply 124/0/0]; 4 key scope resets; 1 tail events not yet synced (incomplete record)\n";
assert.strictEqual(assertSyncOutputCompared(tail, true).tailEventsNotSynced, 1, "the tail count is read");

const partial =
  "   Sync Output: partial [compared/unverifiable/skipped: broadcast 3/0/0, per-player 3/2/0, seed 1/1/0, apply 6/0/0]; 2 events after the last output\n";
assert.throws(() => assertSyncOutputCompared(partial, true), /not verified: partial/, "partial fails even when every scope compared");

const nothingCompared =
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 0/0/0, per-player 0/0/0, seed 0/0/0, apply 0/0/0]\n";
assert.throws(() => assertSyncOutputCompared(nothingCompared, true), /compared nothing/, "0 compared fails");

const noEvents =
  "   Sync Output: passed [compared/unverifiable/skipped: broadcast 2/0/0, per-player 2/0/0, events 0/0/1, seed 1/0/0, apply 4/0/0]\n";
assert.throws(() => assertSyncOutputCompared(noEvents, true), /"events" compared nothing/, "events present but never compared fails");

const failed =
  "   Sync Output: FAILED: sync output mismatch at tick 3, output 0 (tick, sequence 12), check: hash, scope: broadcast [compared/unverifiable/skipped: broadcast 3/0/0, per-player 3/0/0, seed 1/0/0, apply 5/0/0]\n";
assert.strictEqual(parseSyncOutput(failed)?.verdict, "failed");
assert.throws(() => assertSyncOutputCompared(failed, true), /not verified/, "failed fails");

assert.throws(() => assertSyncOutputCompared("   Sync Output: skipped (record 2.1 predates syncConfig)\n", true), /not verified/, "skipped fails");
assert.throws(() => assertSyncOutputCompared("no verdict here\n", true), /no "Sync Output:" line/, "missing line fails");

// In-turn sync off: the record has no sync stream, and only that skip is accepted.
const inTurnOff = "   Sync Output: skipped (no sync stream: recorded with in-turn sync off)\n";
assert.strictEqual(assertSyncOutputCompared(inTurnOff, false).verdict, "skipped", "in-turn off accepts its skip");
assert.throws(() => assertSyncOutputCompared(inTurnOff, true), /not verified/, "the skip fails with in-turn on");
assert.throws(() => assertSyncOutputCompared(passed, false), /with in-turn sync off/, "in-turn off expects the skip");
assert.throws(() => assertSyncOutputCompared("   Sync Output: skipped (record 2.1 predates syncConfig)\n", false), /with in-turn sync off/, "another skip fails with in-turn off");

assert.strictEqual(inTurnSyncEnabled({}), true, "default on");
assert.strictEqual(inTurnSyncEnabled({ IN_TURN_SYNC: "false" }), false);
assert.strictEqual(inTurnSyncEnabled({ IN_TURN_SYNC: " OFF " }), false);
assert.strictEqual(inTurnSyncEnabled({ IN_TURN_SYNC: "0" }), false);
assert.strictEqual(inTurnSyncEnabled({ IN_TURN_SYNC: "true" }), true);
assert.strictEqual(inTurnSyncEnabled({ IN_TURN_SYNC: "garbage" }), true, "unrecognized keeps the default, like EnvHelpers");

console.log("✅ sync-output-verdict tests passed");
