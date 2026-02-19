/// <reference types="node" />

import assert from "assert";
import { parseReplayE2EConfig } from "../../src/reevaluation-replay-config.js";

const defaults = parseReplayE2EConfig({});
assert.equal(defaults.timeoutMs, 60000, "default replay timeout should be 60s");
assert.equal(defaults.replayIdleMs, 1500, "default replay idle should remain 1500ms");

const custom = parseReplayE2EConfig({
  "timeout-ms": "45000",
  "replay-idle-ms": "2200",
});
assert.equal(custom.timeoutMs, 45000, "timeout-ms should honor explicit positive value");
assert.equal(custom.replayIdleMs, 2200, "replay-idle-ms should honor explicit positive value");

const fallback = parseReplayE2EConfig({
  "timeout-ms": "0",
  "replay-idle-ms": "-1",
});
assert.equal(fallback.timeoutMs, 60000, "non-positive timeout should fall back to default");
assert.equal(fallback.replayIdleMs, 1500, "non-positive replay-idle should fall back to default");

console.log("✅ Replay E2E config parsing tests passed");
