# Server Replay Compatible Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Hero Defense replay stream fully client-compatible with live `hero-defense` protocol/state/event shapes, while keeping existing replay start API backward compatible.

**Architecture:** Add a replay projection layer on server that converts reevaluation replay results into standard Hero Defense state/event outputs and sends them through existing sync/transport encoders. Keep `/admin/reevaluation/replay/start` stable, add schema/compatibility guards, and deprecate replay-only state payloads. Enforce correctness with TDD-first unit/integration/E2E coverage focused on timing, ordering, and schema mismatch safety.

**Tech Stack:** Swift 6, Swift Testing (`@Test`, `#expect`), SwiftStateTree runtime/sync/transport, NIO admin routes, TypeScript CLI E2E runner.

### Task 1: Add failing tests for replay compatibility contract

**Files:**
- Modify: `Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift`
- Create: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: Write failing unit tests for state shape parity**

```swift
@Test("Replay projection emits HeroDefense-compatible state fields")
func replayProjectionStateShapeParity() async throws {
    // Arrange replay result with actualState payload
    // Act projector output
    // Assert expected live fields exist, replay-only fields do not exist
    #expect(projected["players"] != nil)
    #expect(projected["monsters"] != nil)
    #expect(projected["currentStateJSON"] == nil)
}
```

**Step 2: Write failing unit tests for event ordering and deterministic tick sequence**

```swift
@Test("Replay projection preserves tick order and event ordering")
func replayProjectionPreservesTickOrder() async throws {
    // Arrange results tick 1..N
    // Act consume projected frames/events
    // Assert strictly increasing tick IDs and deterministic event flush order
    #expect(observedTickIDs == [1, 2, 3, 4])
}
```

**Step 3: Write failing unit tests for schema mismatch guard**

```swift
@Test("Replay start rejects schema mismatch")
func replayStartRejectsSchemaMismatch() async throws {
    // Arrange record schema hash differs from server hash
    // Act start replay
    // Assert explicit mismatch error
    #expect(errorMessage.contains("schema"))
}
```

**Step 4: Run tests to verify they fail**

Run: `swift test --filter ReevaluationReplayCompatibilityTests`
Expected: FAIL with missing projector/guard behavior.

**Step 5: Commit test scaffold**

```bash
git add Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "test: add replay compatibility contract coverage"
```

### Task 2: Implement replay projection layer (minimal, test-driven)

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplayProjector.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift`
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Test: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: Implement minimal projector type and protocol**

```swift
protocol ReevaluationReplayProjecting {
    func project(_ result: ReevaluationTickResult) throws -> ProjectedReplayFrame
}

struct ProjectedReplayFrame: Sendable {
    let tickID: Int
    let stateObject: [String: AnyCodable]
    let serverEvents: [AnyCodable]
}
```

**Step 2: Implement Hero Defense projector mapping only required live fields**

```swift
// Map actualState -> HeroDefense-compatible object
// Keep YAGNI: only fields currently emitted in live state tree
```

**Step 3: Wire replay land to projector output (remove replay-only sync usage)**

```swift
// Before: state.currentStateJSON = ...
// After: apply projected state object to sync path used by live-compatible clients
```

**Step 4: Run targeted tests**

Run: `swift test --filter ReevaluationReplayCompatibilityTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplayProjector.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "feat: project replay output to hero-defense compatible frames"
```

### Task 3: Add schema/version guard on replay start path

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerImpl.swift`
- Test: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: Add explicit compatibility validation helper**

```swift
private func validateReplayCompatibility(...) throws {
    // Compare landType + schemaHash + replay mode support
    // Throw structured error for API response
}
```

**Step 2: Return clear API errors (409/422 style) for mismatch**

```swift
// Include actionable error payload:
// { code: "SCHEMA_MISMATCH", expectedSchemaHash: ..., recordSchemaHash: ... }
```

**Step 3: Run targeted tests**

Run: `swift test --filter replayStartRejectsSchemaMismatch`
Expected: PASS

**Step 4: Commit**

```bash
git add Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift Examples/GameDemo/Sources/GameServer/main.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerImpl.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "feat: enforce replay schema compatibility checks"
```

### Task 4: Add integration tests for replay tick/event flush ordering

**Files:**
- Create: `Tests/SwiftStateTreeTests/ReevaluationReplayIntegrationTests.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorLand.swift`
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`

**Step 1: Write failing integration test for monotonic tick stream**

```swift
@Test("Replay stream emits monotonic ticks until completion")
func replayStreamMonotonicTicks() async throws {
    #expect(observedTicks == observedTicks.sorted())
    #expect(observedTicks.count > 3)
}
```

**Step 2: Write failing integration test for event flush-at-tick behavior**

```swift
@Test("Replay events are flushed with corresponding tick")
func replayEventsFlushWithTick() async throws {
    #expect(eventTickPairs.allSatisfy { $0.eventTickID == $0.frameTickID })
}
```

**Step 3: Implement minimal ordering/flush fixes**

```swift
// Ensure consumeNextResult + emit frame + emit events happen in fixed order
```

**Step 4: Run tests**

Run: `swift test --filter ReevaluationReplayIntegrationTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Tests/SwiftStateTreeTests/ReevaluationReplayIntegrationTests.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorLand.swift Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift
git commit -m "test: enforce deterministic replay tick and event ordering"
```

### Task 5: Upgrade CLI E2E to verify live-compatible replay decoding

**Files:**
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts`
- Modify: `Tools/CLI/test-e2e-game.sh`
- Modify: `Tools/CLI/package.json`

**Step 1: Write failing E2E assertions for live-shape decoding**

```ts
// Assert replay state can be read through normal hero-defense fields
assert(typeof state.score === "number");
assert(state.players && Object.keys(state.players).length >= 0);
// Assert no replay-only field is required
assert(!("currentStateJSON" in state));
```

**Step 2: Run replay E2E in one encoding to fail fast**

Run: `cd Tools/CLI && npx tsx src/reevaluation-replay-e2e-game.ts --state-update-encoding jsonObject ...`
Expected: FAIL before server fix is complete.

**Step 3: Adjust E2E harness to verify all encodings remain compatible**

```ts
// Keep observedTicks threshold and add shape assertions per encoding
```

**Step 4: Run full game E2E matrix**

Run: `./Tools/CLI/test-e2e-game.sh`
Expected: PASS with replay checks in `json`, `jsonOpcode`, `messagepack`.

**Step 5: Commit**

```bash
git add Tools/CLI/src/reevaluation-replay-e2e-game.ts Tools/CLI/test-e2e-game.sh Tools/CLI/package.json
git commit -m "test: validate replay stream with live-compatible decoding"
```

### Task 6: Minimize and harden WebClient replay path (no data-model branch)

**Files:**
- Modify: `Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue`
- Modify: `Examples/GameDemo/WebClient/src/views/GameView.vue`
- Modify: `Examples/GameDemo/WebClient/src/scenes/GameScene.ts`
- Modify: `Examples/GameDemo/WebClient/src/utils/gameClient.ts`

**Step 1: Remove any replay-only state dependency from UI logic**

```ts
// Replay uses same useGameClient()/HeroDefenseStateTree data path
// Keep only UX mode flag for disabling inputs
```

**Step 2: Keep interaction lock in replay mode without touching rendering path**

```ts
if (isReplayMode.value) return; // action/event send guards only
```

**Step 3: Run WebClient build**

Run: `cd Examples/GameDemo/WebClient && npm run build`
Expected: PASS

**Step 4: Commit**

```bash
git add Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue Examples/GameDemo/WebClient/src/views/GameView.vue Examples/GameDemo/WebClient/src/scenes/GameScene.ts Examples/GameDemo/WebClient/src/utils/gameClient.ts
git commit -m "refactor: keep replay client path protocol-compatible with live mode"
```

### Task 7: Full verification gate (must pass before claiming complete)

**Files:**
- Modify: `docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md`
- Modify: `Examples/GameDemo/WebClient/README.md`

**Step 1: Run full Swift test suite**

Run: `swift test`
Expected: PASS (0 failures)

**Step 2: Run replay-inclusive E2E matrix**

Run: `./Tools/CLI/test-e2e-game.sh`
Expected: PASS all encodings

**Step 3: Run WebClient production build**

Run: `cd Examples/GameDemo/WebClient && npm run build`
Expected: PASS

**Step 4: Update verification docs with exact outputs and date**

```md
- swift test: PASS (XXX tests)
- game E2E matrix: PASS (json/jsonOpcode/messagepack)
- web client build: PASS
```

**Step 5: Commit**

```bash
git add docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md Examples/GameDemo/WebClient/README.md
git commit -m "docs: record replay compatible-mode verification results"
```

### Task 8: Compatibility cleanup (no legacy fallback) and deprecation note

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift`
- Modify: `docs/plans/2026-02-15-server-reevaluation-replay-stream.md`

**Step 1: Remove legacy replay-only fields with no compatibility fallback**

```swift
// No legacy replay-only payload fallback in compatible mode.
// Replay output is live-compatible fields only.
```

**Step 2: Add deprecation note and removal timeline**

```md
 Legacy replay-only payload fields are deprecated and removed in compatible mode.
```

**Step 3: Run targeted tests for both flag paths**

Run: `swift test --filter ReevaluationReplayCompatibilityTests`
Expected: PASS

**Step 4: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift docs/plans/2026-02-15-server-reevaluation-replay-stream.md
git commit -m "chore: deprecate legacy replay-only payload path"
```

## Risk Controls (Non-Negotiable)

- **Tick pacing risk:** Integration test must prove monotonic and sufficient tick progression (`>3`) for replay stream.
- **Event ordering risk:** Integration test must prove event emission stays aligned with frame tick.
- **Schema drift risk:** Replay start must hard-fail on schema mismatch with explicit API error payload.
- **Transport parity risk:** CLI E2E must pass in all three encoding modes with live-compatible assertions.
- **Client regression risk:** WebClient build plus replay smoke path must pass without replay-only data dependencies.

## Final Verification Checklist

- [ ] `swift test`
- [ ] `./Tools/CLI/test-e2e-game.sh`
- [ ] `cd Examples/GameDemo/WebClient && npm run build`
- [ ] Updated verification doc with fresh outputs
- [ ] No replay-only client dependency in main rendering/sync path
