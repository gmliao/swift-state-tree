# Matchmaking Comprehensive E2E Test Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Establish a full matchmaking e2e test suite that verifies real GameServer, correct WebSocket assignment, multiple servers, multiple players, and integration paths.

**Architecture:** Extend Tools/CLI scenarios and scripts; add new JSON scenarios and shell/TypeScript runners. Tests start real Control Plane + GameServer(s), use CLI to enqueue/connect/assert.

**Tech Stack:** Bash, TypeScript (tsx), Tools/CLI, NestJS control plane, Swift GameServer, Redis.

---

## Current State

| Test | Stack | What it verifies |
|------|-------|------------------|
| `test:e2e:game:matchmaking:mvp` | CP + 1 GameServer | Single player: enqueue → poll → connect with token → run scenario |
| `test:e2e:game:matchmaking:full` | CP + 1 GameServer | Same as MVP, auto-starts stack |
| `test:e2e:game:matchmaking:two-players` | CP + GameServer (pre-started) | Group of 2: enqueue → both connect to same landId |
| `test:e2e:game:matchmaking:three-players` | CP + GameServer (pre-started) | Group of 3: enqueue → all connect to same landId |
| `test:e2e:game:matchmaking:multi-server` | CP + 2 GameServers | Single player: verify connectUrl port assignment |
| `test:e2e:game:matchmaking:nginx` | CP + GameServer + nginx | connectUrl goes through nginx (LB) |

**Fixed (Control Plane):** Sequential enqueue bug was addressed by calling `tryMatch(queueKey)` synchronously in `enqueue()` before adding the BullMQ job. This ensures immediate processing; the BullMQ job still runs but typically finds nothing to match.

**Gaps:**
- No test with **multiple GameServers** (round-robin allocation)
- No test for **correct server assignment** (connectUrl points to assigned server)
- Two-player uses `queueKey: "standard:asia"` but GameServer registers as `hero-defense` — may need `hero-defense:asia` or `hero-defense:2`
- No CI job that runs full matchmaking suite (Redis + stack)
- No encoding-mode coverage for matchmaking (jsonObject, opcodeJsonArray, messagepack)

---

## Test Scenarios to Add

### Scenario 1: Multi-Server Round-Robin Assignment

**Goal:** With 2+ GameServers registered, verify assignments are distributed (round-robin) and each connectUrl points to the correct server.

**Setup:**
- Control plane on 3000
- GameServer A on 8080 (serverId=game-a, landType=hero-defense)
- GameServer B on 8081 (serverId=game-b, landType=hero-defense)

**Steps:**
1. Enqueue player 1 → poll until assigned → extract connectUrl, serverId from assignment
2. Assert connectUrl contains correct host:port for assigned server
3. Enqueue player 2 → poll → assert different server (or same if round-robin wraps)
4. Both connect via WebSocket, run minimal scenario (assert score exists)

**Files:**
- Create: `Tools/CLI/scripts/internal/run-matchmaking-multi-server-e2e.sh`
- Create: `Tools/CLI/scenarios/game/test-multi-server-assignment.json` (minimal: connect, assert score)

---

### Scenario 2: Correct WebSocket Server Assignment

**Goal:** Verify connectUrl from assignment is reachable and game state is correct.

**Steps:**
1. Enqueue → get assignment (connectUrl, matchToken, landId)
2. Connect via WebSocket with token
3. Assert firstSync received, score field exists
4. Send PlayAction, assert score increments

**Note:** Partially covered by `test-matchmaking-assignment-flow.json`. Extend to assert connectUrl host/port matches a registered server.

---

### Scenario 3: Multiple Players Same Game (Fix queueKey)

**Goal:** Two players enqueue as group, both connect to same landId, both can play.

**Fix:** Change `run-matchmaking-two-players.sh` queueKey from `standard:asia` to `hero-defense:asia` (or `hero-defense:2` for groupSize 2). GameServer registers as `hero-defense`.

**Files:**
- Modify: `Tools/CLI/scripts/internal/run-matchmaking-two-players.sh`

---

### Scenario 4: Matchmaking Full Suite (All Encodings) ✅

**Goal:** Run matchmaking MVP across jsonObject, opcodeJsonArray, messagepack.

**Approach:** Script `run-matchmaking-full-encodings.sh`:
1. Starts CP once
2. For each encoding: start GameServer with TRANSPORT_ENCODING, run MVP with MATCHMAKING_STATE_UPDATE_ENCODING, stop GameServer
3. Cleanup

**Files:**
- `Tools/CLI/scripts/internal/run-matchmaking-full-encodings.sh`
- `Tools/CLI/package.json` — `test:e2e:game:matchmaking:all-encodings`

---

### Scenario 5: Three+ Players Same Game

**Goal:** Group of 3 enqueue, all connect to same landId, run scenario.

**Setup:** queueKey `hero-defense:3` or `hero-defense:3v3` (groupSize 3).

**Files:**
- Create: `Tools/CLI/scripts/internal/run-matchmaking-three-players.sh`
- Create: `Tools/CLI/scenarios/game/test-matchmaking-three-players.json`
- Modify: `Tools/CLI/package.json`

---

### Scenario 6: CI Integration

**Goal:** GitHub Actions runs matchmaking e2e when Redis is available.

**Approach:** Extend `.github/workflows/e2e-tests.yml` (or create `matchmaking-e2e.yml`):
- Redis service
- Build control-plane, GameServer
- Run `test:e2e:game:matchmaking:full` and optionally `test:e2e:game:matchmaking:two-players`

**Files:**
- Modify: `.github/workflows/e2e-tests.yml` or create `matchmaking-e2e.yml`

---

## Task Breakdown

### Task 1: Fix two-player queueKey

**Files:** `Tools/CLI/scripts/internal/run-matchmaking-two-players.sh`

**Step 1:** Change queueKey from `standard:asia` to `hero-defense:asia` (or `hero-defense:2` if groupSize is parsed).

**Step 2:** Run `npm run test:e2e:game:matchmaking:full` (which runs MVP then two-players in nginx flow; for full flow use `run-matchmaking-full-with-test.sh` which only runs MVP). Check if two-players is invoked — from `run-matchmaking-full-with-test.sh` it only runs MVP. So we need to either extend full script to run two-players, or run two-players manually after full. For this task, just fix the queueKey so when two-players is run (e.g. from nginx script), it works.

**Step 3:** Run `test:e2e:game:matchmaking:nginx` (includes two-players) — requires Docker. Or run `run-matchmaking-full-with-test.sh` and then manually `run-matchmaking-two-players.sh` in another terminal. Simplify: add two-players to `run-matchmaking-full-with-test.sh` so full suite runs both MVP and two-players.

**Step 4:** Commit.

---

### Task 2: Add two-players to full stack script

**Files:** `Tools/CLI/scripts/internal/run-matchmaking-full-with-test.sh`

**Step 1:** After MVP test, add: `MATCHMAKING_CONTROL_PLANE_URL=$MATCHMAKING_CONTROL_PLANE_URL bash "$SCRIPT_DIR/run-matchmaking-two-players.sh"`

**Step 2:** Run full script, verify both pass.

**Step 3:** Commit.

---

### Task 3: Multi-server e2e script

**Files:**
- Create: `Tools/CLI/scripts/internal/run-matchmaking-multi-server-e2e.sh`
- Create: `Tools/CLI/scenarios/game/test-multi-server-assignment.json`

**Step 1:** Create scenario JSON (connect, assert score exists, optional PlayAction).

**Step 2:** Create shell script:
- Start CP
- Start GameServer A on 8080
- Start GameServer B on 8081 (different PORT)
- Enqueue 2 players (separate groups, groupSize 1)
- For each: poll assignment, assert connectUrl contains 8080 or 8081, connect and run scenario
- Cleanup

**Step 3:** Add npm script `test:e2e:game:matchmaking:multi-server`

**Step 4:** Run and verify.

**Step 5:** Commit.

---

### Task 4: Three-player scenario

**Files:**
- Create: `Tools/CLI/scripts/internal/run-matchmaking-three-players.sh`
- Create: `Tools/CLI/scenarios/game/test-matchmaking-three-players.json`

**Step 1:** Copy two-players script, adapt for 3 players (enqueue groupSize 3, start 3 CLI clients in parallel).

**Step 2:** Create scenario (same as two-players: assert score, PlayAction).

**Step 3:** Add npm script.

**Step 4:** Run (requires full stack).

**Step 5:** Commit.

---

### Task 5: Matchmaking all-encodings script

**Files:**
- Create: `Tools/CLI/scripts/internal/run-matchmaking-all-encodings.sh`
- Modify: `Tools/CLI/package.json`

**Step 1:** Script starts CP + GameServer, then for each of jsonObject, opcodeJsonArray, messagepack: run MVP with corresponding `--state-update-encoding`. Note: GameServer encoding is configured at startup. For messagepack, GameServer must be started with TRANSPORT_ENCODING=messagepack. So we need to either restart GameServer per encoding, or run 3 GameServers on different ports with different encodings. Simpler: run MVP 3 times with same server; change CLI's state-update-encoding. The server sends in its configured encoding. So we need 3 runs with 3 different GameServer encodings. That means 3 restarts. Complex. Alternative: run MVP once per encoding, restart GameServer each time. Script: start CP, for encoding in json, jsonOpcode, messagepack: start GameServer with TRANSPORT_ENCODING, run MVP, kill GameServer. Repeat.

**Step 2:** Implement.

**Step 3:** Commit.

---

### Task 6: CI workflow for matchmaking

**Files:** `.github/workflows/e2e-tests.yml` or new `matchmaking-e2e.yml`

**Step 1:** Add job with Redis service, Node, Swift. Run `test:e2e:game:matchmaking:full`.

**Step 2:** Ensure control-plane and GameServer build. Use REDIS_DB=1 or default for CI Redis.

**Step 3:** Commit.

---

## Execution Handoff

Plan saved to `docs/plans/2026-02-21-matchmaking-comprehensive-e2e-test-plan.md`.

**Execution options:**
1. **Subagent-Driven** — Dispatch subagent per task, review between tasks.
2. **Parallel Session** — Open new session with executing-plans.
