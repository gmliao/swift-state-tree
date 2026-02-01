# UWS Load Test for Hero Defense Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a new `ws` load test tool for `hero-defense` that runs real connections and outputs new JSON+HTML reports with client and server metrics.

**Architecture:** A Node.js orchestrator reads a scenario JSON with phases (preflight/steady/postflight), launches multiple worker processes, and aggregates metrics. Workers connect via `ws`, perform join, send actions at configured rates, track RTT and state update cadence, and report stats. A separate monitoring script collects server CPU/mem/load and is merged into the report.

**Tech Stack:** Node.js + TypeScript, `ws`, `@msgpack/msgpack`, `vitest`, Bash for monitoring/runner scripts.

---

### Task 1: Scaffold new tool and baseline scenario parser

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/package.json`
- Create: `Examples/GameDemo/uws-loadtest/tsconfig.json`
- Create: `Examples/GameDemo/uws-loadtest/vitest.config.ts`
- Create: `Examples/GameDemo/uws-loadtest/src/types.ts`
- Create: `Examples/GameDemo/uws-loadtest/src/scenario.ts`
- Create: `Examples/GameDemo/uws-loadtest/tests/scenario.test.ts`

**Step 1: Create tool config files**

`Examples/GameDemo/uws-loadtest/package.json`:
```json
{
  "name": "uws-loadtest",
  "private": true,
  "scripts": {
    "dev": "tsx src/cli.ts",
    "build": "tsc -p tsconfig.json",
    "start": "node dist/cli.js",
    "test": "vitest run",
    "lint": "tsc -p tsconfig.json --noEmit"
  },
  "dependencies": {
    "ws": "^8.17.0",
    "@msgpack/msgpack": "^3.0.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "tsx": "^4.7.0",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
```

`Examples/GameDemo/uws-loadtest/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "CommonJS",
    "moduleResolution": "Node",
    "strict": true,
    "esModuleInterop": true,
    "types": ["node"],
    "rootDir": "src",
    "outDir": "dist",
    "skipLibCheck": true
  },
  "include": ["src", "tests"]
}
```

`Examples/GameDemo/uws-loadtest/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";
export default defineConfig({ test: { environment: "node" } });
```

**Step 2: Install dependencies**

Run: `cd Examples/GameDemo/uws-loadtest && npm install`  
Expected: packages installed, no fatal errors

**Step 3: Write the failing tests for scenario defaults**

```ts
import { describe, it, expect } from "vitest";
import { parseScenario } from "../src/scenario";

describe("parseScenario", () => {
    it("fills defaults when rooms missing", () => {
        const scenario = parseScenario({ phases: { steady: { durationSeconds: 10 } } });
        expect(scenario.phases.steady.rooms).toBe(500);
    });
});
```

**Step 4: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL with "parseScenario is not defined"

**Step 5: Write minimal scenario parser**

```ts
// src/types.ts
export type PhaseName = "preflight" | "steady" | "postflight";
export interface Thresholds {
    errorRate: number;
    disconnectRate: number;
    rttP95: number;
    rttP99: number;
    updateP95: number;
    updateP99: number;
}
export interface PhaseConfig {
    durationSeconds: number;
    rooms: number;
    playersPerRoom: number;
    actionsPerSecond: number;
    verify: boolean;
    joinPayloadTemplate?: Record<string, unknown>;
    thresholds?: Thresholds;
}
export interface Scenario {
    name: string;
    serverUrl: string;
    phases: Record<PhaseName, PhaseConfig>;
    actions: Array<{ name: string; weight: number; payloadTemplate?: Record<string, unknown> }>;
}

// src/scenario.ts
import { Scenario, PhaseConfig } from "./types";
export function parseScenario(raw: unknown): Scenario {
    // Defaults:
    // serverUrl: "ws://localhost:8080/game/hero-defense"
    // rooms: 500
    // playersPerRoom: 5
    // actionsPerSecond: 1
    // preflight/steady/postflight durations: 10 / 60 / 10
    // verify: true for preflight/postflight, false for steady
}
```

**Step 6: Run test to verify it passes**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 7: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/package.json Examples/GameDemo/uws-loadtest/tsconfig.json Examples/GameDemo/uws-loadtest/vitest.config.ts Examples/GameDemo/uws-loadtest/src/types.ts Examples/GameDemo/uws-loadtest/src/scenario.ts Examples/GameDemo/uws-loadtest/tests/scenario.test.ts
git commit -m "feat: scaffold uws-loadtest and scenario defaults"
```

---

### Task 2: Template rendering for join/action payloads

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/src/template.ts`
- Create: `Examples/GameDemo/uws-loadtest/tests/template.test.ts`

**Step 1: Write failing tests**

```ts
import { describe, it, expect } from "vitest";
import { renderTemplate } from "../src/template";

it("replaces simple placeholders", () => {
    const out = renderTemplate("p-{playerId}", { playerId: "abc" });
    expect(out).toBe("p-abc");
});

it("supports randInt", () => {
    const out = renderTemplate("r-{randInt:1:2}", {});
    expect(["r-1", "r-2"]).toContain(out);
});
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL with "renderTemplate is not defined"

**Step 3: Implement minimal template renderer**

```ts
export function renderTemplate(value: string, ctx: Record<string, string>): string { /* regex replace */ }
```

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/src/template.ts Examples/GameDemo/uws-loadtest/tests/template.test.ts
git commit -m "feat: add payload template renderer"
```

---

### Task 3: Metrics aggregation and threshold evaluation

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/src/metrics.ts`
- Create: `Examples/GameDemo/uws-loadtest/tests/metrics.test.ts`

**Step 1: Write failing tests**

```ts
import { describe, it, expect } from "vitest";
import { percentile, evaluateThresholds } from "../src/metrics";

it("computes percentiles", () => {
    expect(percentile([1, 2, 3, 4, 5], 0.95)).toBe(5);
});

it("evaluates thresholds", () => {
    const result = evaluateThresholds(
        { errorRate: 0.01, disconnectRate: 0.01, rttP95: 80, rttP99: 200, updateP95: 90, updateP99: 220 },
        { errorRate: 0.1, disconnectRate: 0.1, rttP95: 100, rttP99: 250, updateP95: 100, updateP99: 250 }
    );
    expect(result.passed).toBe(true);
});
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL

**Step 3: Implement metrics helpers**

```ts
export function percentile(values: number[], p: number): number { /* sort + index */ }
export function evaluateThresholds(actual: Metrics, thresholds: Thresholds): ThresholdResult { /* compare */ }
```

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/src/metrics.ts Examples/GameDemo/uws-loadtest/tests/metrics.test.ts
git commit -m "feat: add metrics aggregation and thresholds"
```

---

### Task 4: Worker process with ws connections and message handling

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/src/worker.ts`
- Create: `Examples/GameDemo/uws-loadtest/src/protocol.ts`
- Create: `Examples/GameDemo/uws-loadtest/tests/protocol.test.ts`

**Step 1: Write failing tests for message decoding**

```ts
import { decodeMessage } from "../src/protocol";
import { encode } from "@msgpack/msgpack";
import { describe, it, expect } from "vitest";

it("decodes messagepack transport messages", () => {
    const buf = encode({ kind: "joinResponse", payload: { joinResponse: { success: true } } });
    const msg = decodeMessage(buf);
    expect(msg.kind).toBe("joinResponse");
});
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL

**Step 3: Implement minimal decoder and worker skeleton**

```ts
export function decodeMessage(buf: Uint8Array): any { /* @msgpack/msgpack decode */ }
```

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 5: Implement worker core**

- Connect using `ws` WebSocket client.
- Start with **JSON join handshake** (per SDK: join messages always JSON).
- After `joinResponse` with `encoding: "messagepack"`, send **messagepack opcode arrays** for actions.
- Copy minimal `encodeMessageToFormat` and `decodeMessage` helpers from `sdk/ts/src/core/protocol.ts` into `src/protocol.ts`.
- Track request IDs and RTT by mapping `requestID -> sentAt`.
- Record state update cadence when decoded message is:
  - `StateUpdate` (object with `type` + `patches`)
  - `StateUpdateOpcode` array (0-2)
  - `MessageKindOpcode.stateUpdateWithEvents` (107)

**Step 6: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/src/worker.ts Examples/GameDemo/uws-loadtest/src/protocol.ts Examples/GameDemo/uws-loadtest/tests/protocol.test.ts
git commit -m "feat: add uws worker and protocol decoder"
```

---

### Task 5: Orchestrator, CLI, and phase scheduling

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/src/cli.ts`
- Create: `Examples/GameDemo/uws-loadtest/src/orchestrator.ts`
- Modify: `Examples/GameDemo/uws-loadtest/src/scenario.ts`
- Create: `Examples/GameDemo/uws-loadtest/tests/orchestrator.test.ts`

**Step 1: Write failing tests for phase defaults**

```ts
import { buildPhases } from "../src/orchestrator";
import { describe, it, expect } from "vitest";

it("builds phases with default ordering", () => {
    const phases = buildPhases({ phases: { steady: { durationSeconds: 10 } } });
    expect(phases[0].name).toBe("preflight");
});
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL

**Step 3: Implement orchestrator**

- Parse scenario, compute total connections.
- Launch workers (child processes) and distribute connection counts.
- Schedule phases sequentially and collect metrics.
- Prefer running compiled JS (`dist/worker.js`) when spawning workers.

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/src/cli.ts Examples/GameDemo/uws-loadtest/src/orchestrator.ts Examples/GameDemo/uws-loadtest/src/scenario.ts Examples/GameDemo/uws-loadtest/tests/orchestrator.test.ts
git commit -m "feat: add orchestrator and phase scheduling"
```

---

### Task 6: Monitoring + report generation + default scenario

**Files:**
- Create: `Examples/GameDemo/uws-loadtest/monitoring/collect-system-metrics.sh`
- Create: `Examples/GameDemo/uws-loadtest/scripts/run-uws-loadtest.sh`
- Create: `Examples/GameDemo/uws-loadtest/src/report/render-html.ts`
- Create: `Examples/GameDemo/uws-loadtest/scenarios/hero-defense/default.json`
- Create: `Examples/GameDemo/uws-loadtest/results/.gitkeep`
- Create: `Examples/GameDemo/uws-loadtest/README.md`

**Step 1: Write failing test for report JSON shape**

```ts
import { buildReport } from "../src/report/render-html";
import { describe, it, expect } from "vitest";

it("includes thresholds and phase summary", () => {
    const report = buildReport({ phases: [] }, { system: [] });
    expect(report).toHaveProperty("phases");
});
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: FAIL

**Step 3: Implement report generator**

- JSON output includes run config, per-phase metrics, thresholds results.
- HTML embeds JSON and renders basic charts (SVG or canvas).

**Step 4: Add monitoring script**

- Copy logic from `Examples/GameDemo/scripts/server-loadtest/run-server-loadtest.sh` for ps/vmstat/pidstat sampling.
- Integrate with `run-uws-loadtest.sh` to auto-start `GameServer`, wait for readiness, and enforce timeout.

**Step 5: Add default scenario**

`Examples/GameDemo/uws-loadtest/scenarios/hero-defense/default.json`:
```json
{
  "name": "hero-defense-baseline",
  "serverUrl": "ws://localhost:8080/game/hero-defense",
  "actions": [
    { "name": "PlayAction", "weight": 1, "payloadTemplate": {} }
  ],
  "phases": {
    "preflight": {
      "durationSeconds": 10,
      "rooms": 50,
      "playersPerRoom": 2,
      "actionsPerSecond": 1,
      "verify": true,
      "thresholds": {
        "errorRate": 0.001,
        "disconnectRate": 0.001,
        "rttP95": 100,
        "rttP99": 250,
        "updateP95": 100,
        "updateP99": 250
      }
    },
    "steady": {
      "durationSeconds": 60,
      "rooms": 500,
      "playersPerRoom": 5,
      "actionsPerSecond": 1,
      "verify": false,
      "thresholds": {
        "errorRate": 0.001,
        "disconnectRate": 0.001,
        "rttP95": 100,
        "rttP99": 250,
        "updateP95": 100,
        "updateP99": 250
      }
    },
    "postflight": {
      "durationSeconds": 10,
      "rooms": 50,
      "playersPerRoom": 2,
      "actionsPerSecond": 1,
      "verify": true,
      "thresholds": {
        "errorRate": 0.001,
        "disconnectRate": 0.001,
        "rttP95": 100,
        "rttP99": 250,
        "updateP95": 100,
        "updateP99": 250
      }
    }
  }
}
```

**Step 6: Run tests**

Run: `cd Examples/GameDemo/uws-loadtest && npm test`  
Expected: PASS

**Step 7: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/monitoring/collect-system-metrics.sh Examples/GameDemo/uws-loadtest/scripts/run-uws-loadtest.sh Examples/GameDemo/uws-loadtest/src/report/render-html.ts Examples/GameDemo/uws-loadtest/scenarios/hero-defense/default.json Examples/GameDemo/uws-loadtest/README.md
git commit -m "feat: add monitoring, reporting, and default scenario"
```

---

### Task 7: Manual validation run

**Step 1: Build and run**

Run:
```
cd Examples/GameDemo/uws-loadtest
npm install
npm run build
bash scripts/run-uws-loadtest.sh --scenario scenarios/hero-defense/default.json
```
Expected: JSON+HTML report in `Examples/GameDemo/uws-loadtest/results/`.

**Step 2: Sanity check**
- Verify report marks pass/fail using scenario thresholds.
- Confirm server metrics merged.

**Step 3: Commit**

```bash
git add Examples/GameDemo/uws-loadtest/results/.gitkeep
git commit -m "chore: document uws-loadtest manual run"
```
