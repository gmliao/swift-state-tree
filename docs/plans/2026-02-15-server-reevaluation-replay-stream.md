# Server-Side Reevaluation Replay Stream Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a server-driven replay mode that simulates Hero Defense on the server and streams live-like broadcast events and continuous state updates to clients, with minimal client logic changes.

**Architecture:** Add a dedicated read-only replay WebSocket endpoint and land type for Hero Defense replay sessions. Replay data loading, stepping, and tick progression happen on the server via reevaluation record source + runner service, while clients subscribe like normal live game views. Admin APIs create replay sessions and return land IDs so clients only switch endpoint/land ID, not replay reconstruction logic.

**Tech Stack:** Swift 6, SwiftStateTree/SwiftStateTreeNIO/SwiftStateTreeReevaluationMonitor, TypeScript CLI E2E, Playwright smoke tests.

### Task 1: Define replay session contract (server API + service interface)

**Files:**
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift`
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionService.swift`
- Test: `Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift`

**Step 1: Write the failing test**

```swift
@Test("Replay session service allocates session and returns metadata")
func replaySessionServiceCreatesSession() async throws {
    let service = ReevaluationReplaySessionService()
    let session = try service.createSession(landType: "hero-defense", recordFilePath: "/tmp/test.json")
    #expect(session.landType == "hero-defense")
    #expect(session.recordFilePath == "/tmp/test.json")
    #expect(!session.landID.stringValue.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter replaySessionServiceCreatesSession`
Expected: FAIL with missing `ReevaluationReplaySessionService`.

**Step 3: Write minimal implementation**

```swift
public struct ReevaluationReplaySession: Sendable { ... }
public final class ReevaluationReplaySessionService: @unchecked Sendable {
    public func createSession(...) throws -> ReevaluationReplaySession { ... }
    public func getSession(landID: LandID) -> ReevaluationReplaySession? { ... }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter replaySessionServiceCreatesSession`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionService.swift Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift
git commit -m "feat: add replay session service contract"
```

### Task 2: Add admin API to create replay sessions

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Test: `Tools/CLI/src/reevaluation-e2e-game.ts`

**Step 1: Write the failing test**

Add CLI assertion that `POST /admin/reevaluation/replay/start` returns `{ replayLandID, webSocketPath }`.

**Step 2: Run test to verify it fails**

Run: `cd Tools/CLI && npx tsx src/reevaluation-e2e-game.ts --admin-url http://localhost:8080`
Expected: FAIL with HTTP 404 for replay start endpoint.

**Step 3: Write minimal implementation**

```swift
await router.post("/admin/reevaluation/replay/start") { request in
    // auth
    // parse landType + recordFilePath
    // create session in ReevaluationReplaySessionService
    // return replayLandID + webSocketPath (/game/hero-defense-replay)
}
```

Register `ReevaluationReplaySessionService` in GameServer services factory.

**Step 4: Run test to verify it passes**

Run: `cd Tools/CLI && npx tsx src/reevaluation-e2e-game.ts --admin-url http://localhost:8080`
Expected: PASS API contract check for replay start endpoint.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift Examples/GameDemo/Sources/GameServer/main.swift Tools/CLI/src/reevaluation-e2e-game.ts
git commit -m "feat: add admin replay session start endpoint"
```

### Task 3: Implement read-only replay land stream (server simulation)

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplayLand.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerImpl.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Test: `Tools/CLI/src/reevaluation-e2e-game.ts`

**Step 1: Write the failing test**

In CLI E2E, after session start + join replay WS, assert:
1) receives continuous state updates (`>= 3` ticks)
2) receives broadcast server events in replay stream
3) stream completes without client-side frame reconstruction.

**Step 2: Run test to verify it fails**

Run: `cd Tools/CLI && npx tsx src/reevaluation-e2e-game.ts --state-update-encoding messagepack`
Expected: FAIL because `/game/hero-defense-replay` is unavailable or emits no replay stream.

**Step 3: Write minimal implementation**

Implement replay land that:
- loads session config by `landID`
- starts reevaluation runner on first join
- advances tick in `Lifetime.Tick`
- pushes current replay state into sync fields every tick
- emits replay events to `.all`
- marks completion/failed state.

Keep it read-only by rejecting gameplay actions in replay mode.

**Step 4: Run test to verify it passes**

Run: `cd Tools/CLI && npx tsx src/reevaluation-e2e-game.ts --state-update-encoding messagepack`
Expected: PASS with replay stream updates/events observed.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplayLand.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerImpl.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift Examples/GameDemo/Sources/GameServer/main.swift Tools/CLI/src/reevaluation-e2e-game.ts
git commit -m "feat: add server-driven replay websocket stream"
```

### Task 4: Keep client changes minimal (endpoint switch only)

**Files:**
- Modify: `Examples/GameDemo/WebClient/src/state-source/LiveStateSource.ts`
- Modify: `Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue`
- Modify: `Examples/GameDemo/WebClient/src/utils/gameClient.ts`
- Test: `Examples/GameDemo/WebClient/playwright.config.ts`

**Step 1: Write the failing test**

Playwright smoke test:
1) create replay session via admin API
2) open GameView using replay endpoint/landID
3) assert scene receives state updates without client record reconstruction path.

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo/WebClient && npx playwright test`
Expected: FAIL because client still depends on local record/frame reconstruction.

**Step 3: Write minimal implementation**

Client only:
- consume `replayLandID` + replay `wsUrl`
- connect through existing game source path
- disable local replay frame conversion path for this mode.

No replay sync logic in client.

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo/WebClient && npx playwright test`
Expected: PASS for replay smoke flow.

**Step 5: Commit**

```bash
git add Examples/GameDemo/WebClient/src/state-source/LiveStateSource.ts Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue Examples/GameDemo/WebClient/src/utils/gameClient.ts Examples/GameDemo/WebClient/playwright.config.ts
git commit -m "refactor: switch replay mode to server stream endpoint"
```

### Task 5: End-to-end verification matrix and docs

**Files:**
- Modify: `Tools/CLI/test-e2e-game.sh`
- Modify: `Tools/CLI/package.json`
- Modify: `Examples/GameDemo/WebClient/README.md`
- Create: `docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md`

**Step 1: Write the failing verification script update**

Add replay stream checks into game E2E script for all encodings: `jsonObject`, `opcodeJsonArray`, `messagepack`.

**Step 2: Run to verify it fails first**

Run: `cd Tools/CLI && ./test-e2e-game.sh`
Expected: FAIL on missing replay stream checks.

**Step 3: Write minimal implementation**

Update script + npm command wiring + README verification instructions.

**Step 4: Run full verification**

Run:
- `swift test`
- `cd Tools/CLI && ./test-e2e-game.sh`
- `cd Examples/GameDemo/WebClient && npm test`

Expected: PASS all commands.

**Step 5: Commit**

```bash
git add Tools/CLI/test-e2e-game.sh Tools/CLI/package.json Examples/GameDemo/WebClient/README.md docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md
git commit -m "test: add replay stream verification coverage"
```

## Notes

- Keep YAGNI: no seek/scrub/multi-view controls in first server-stream milestone.
- Keep replay endpoint read-only: gameplay actions must be rejected explicitly.
- Keep deterministic verification server-side: compare per-tick hashes and expose status for diagnostics.
- Preserve compatibility with existing live endpoint and clients.
