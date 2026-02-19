# Hero Defense Replay Live-State Unification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `hero-defense-replay` stream the same gameplay state shape as live `hero-defense` (no replay-only wrapped state), while preserving hash-based correctness proof.

**Architecture:** Keep replay execution server-authoritative through `ReevaluationRunnerService` and projector pipeline, but change replay land state storage from `[String: AnyCodable]` wrappers to live typed broadcast fields (`players`, `monsters`, `turrets`, `base`, `score`). Keep replay transport and `/admin/reevaluation/replay/start` flow unchanged. Use tests + CLI E2E + Playwright CLI evidence to prove correctness.

**Tech Stack:** Swift 6 + Swift Testing, SwiftStateTree/NIO/ReevaluationMonitor, TypeScript SDK codegen, CLI E2E (`Tools/CLI`), Playwright CLI (`@playwright/cli`).

---

### Task 1: Add failing contracts for live-state replay shape

**Files:**
- Create: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Modify: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: Write failing GameContent test for replay state parity**

```swift
@Test("Replay state uses live HeroDefense broadcast field types")
func replayStateUsesLiveTypedFields() throws {
    var replay = HeroDefenseReplayState()
    var player = PlayerState()
    player.position = Position2(x: 10, y: 20)
    replay.players[PlayerID("p1")] = player

    let snap = try replay.broadcastSnapshot(dirtyFields: nil)
    let playersValue = snap.values["players"]
    #expect(playersValue != nil)
    // Red phase expectation: nested player should expose position fields directly,
    // not AnyCodable "base" wrappers.
}
```

**Step 2: Write failing compatibility test for replay projection semantic shape**

```swift
@Test("Replay projection keeps live semantic fields without wrapper objects")
func replayProjectionNoWrapperContract() throws {
    // Arrange: snapshot with players/monsters/turrets/base/score
    // Act: projector.project(...)
    // Assert: projected state contains live semantic objects; no replay-only wrapper key.
}
```

**Step 3: Run focused tests to verify RED**

Run: `cd Examples/GameDemo && swift test --filter HeroDefenseReplayStateParityTests`

Expected: FAIL (shape/wrapper mismatch)

Run: `swift test --filter ReevaluationReplayCompatibilityTests`

Expected: FAIL on new semantic-shape assertion

**Step 4: Commit red contracts**

```bash
git add Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "test: add failing replay live-state parity contracts"
```

---

### Task 2: Convert replay land state to live typed fields

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`

**Step 1: Replace replay state field types with live state types**

Use live broadcast types:

```swift
@Sync(.broadcast) var players: [PlayerID: PlayerState] = [:]
@Sync(.broadcast) var monsters: [Int: MonsterState] = [:]
@Sync(.broadcast) var turrets: [Int: TurretState] = [:]
@Sync(.broadcast) var base: BaseState = BaseState()
@Sync(.broadcast) var score: Int = 0
```

Keep replay control fields (`status`, `currentTickId`, `totalTicks`, `errorMessage`) unchanged.

**Step 2: Implement minimal typed projection application path**

- Decode projector output into typed snapshot model (players/monsters/turrets/base/score).
- Map dictionary keys (`String`) to typed keys (`PlayerID`, `Int`) deterministically.
- Ignore unknown fields (YAGNI).

**Step 3: Remove AnyCodable-only dictionary apply helpers no longer needed**

- Remove wrapper conversion helpers that create replay-only nested `base` wrappers.
- Keep parsing deterministic and strict enough to avoid silent corruption.

**Step 4: Run focused tests to verify GREEN**

Run: `cd Examples/GameDemo && swift test --filter HeroDefenseReplayStateParityTests`

Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift
git commit -m "feat: align replay land state with live hero-defense types"
```

---

### Task 3: Ensure schema/codegen always includes replay land

**Files:**
- Modify: `Examples/GameDemo/Sources/SchemaGen/main.swift`
- Regenerate: `Examples/GameDemo/WebClient/src/generated/**`

**Step 1: Add replay land definition to SchemaGen input list**

```swift
let landDefinitions = [
  AnyLandDefinition(HeroDefense.makeLand()),
  AnyLandDefinition(ReevaluationMonitor.makeLand()),
  AnyLandDefinition(HeroDefenseReplay.makeLand()),
]
```

**Step 2: Regenerate schema + client code**

Run:
- `cd Examples/GameDemo/WebClient && npm run schema:generate`
- `cd Examples/GameDemo/WebClient && npm run codegen`

Expected:
- `src/generated/schema.ts` includes `hero-defense-replay`
- `src/generated/hero-defense-replay/` exists

**Step 3: Verify build**

Run: `cd Examples/GameDemo/WebClient && npm run build`

Expected: PASS

**Step 4: Commit**

```bash
git add Examples/GameDemo/Sources/SchemaGen/main.swift Examples/GameDemo/WebClient/src/generated
git commit -m "fix: include replay land in GameDemo schema codegen"
```

---

### Task 4: Strengthen replay E2E assertions to prove live-state semantics

**Files:**
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts`

**Step 1: Write failing semantic assertion checks (RED)**

Add strict checks that replay state objects use live semantics:
- At least one player/monster/turret sample has expected nested live fields (e.g. `position.x` numeric)
- Explicitly reject replay-wrapper artifacts (e.g. nested `.base` wrapper at entity level)

**Step 2: Run focused E2E once to confirm failure**

Run: `cd Tools/CLI && npx tsx src/reevaluation-replay-e2e-game.ts --ws-url ws://localhost:8080/game/hero-defense --admin-url http://localhost:8080 --state-update-encoding messagepack`

Expected: FAIL before typed-state fix is complete

**Step 3: Apply minimal assertion logic needed for the new typed shape (GREEN)**

- Keep existing completion and score progression checks.
- Add semantic-shape checks without overfitting to one exact scenario.

**Step 4: Re-run focused E2E**

Expected: PASS

**Step 5: Commit**

```bash
git add Tools/CLI/src/reevaluation-replay-e2e-game.ts
git commit -m "test: enforce live-state semantic assertions for replay e2e"
```

---

### Task 5: Prove hash correctness and replay correctness end-to-end

**Files:**
- Modify: `docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md`
- (Optional note update) `docs/plans/2026-02-15-server-reevaluation-replay-stream.md`

**Step 1: Run Swift regression suites**

Run:
- `swift test --filter ReevaluationReplayCompatibilityTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`

Expected: PASS

**Step 2: Run full replay matrix E2E**

Run: `./Tools/CLI/test-e2e-game.sh`

Expected: all encoding modes PASS

**Step 3: Capture hash-proof evidence via monitor flow (A-option proof)**

Run Playwright CLI monitor verification:
- Start `GameServer` with `ENABLE_REEVALUATION=true`
- Start WebClient dev server
- Use `@playwright/cli` to trigger `Start Verification` and extract summary

Required evidence to record:
- `Total Ticks = N`
- `Correct = N`
- `Mismatches = 0`
- proof screenshot path (for example `/tmp/verification-proof.png`)

**Step 4: Update verification doc with exact command outputs**

Add:
- command list
- key output lines
- date/time snapshot

**Step 5: Commit**

```bash
git add docs/plans/2026-02-15-server-reevaluation-replay-stream-verification.md docs/plans/2026-02-15-server-reevaluation-replay-stream.md
git commit -m "docs: record replay hash-proof verification evidence"
```

---

### Task 6: Final full verification gate

**Files:**
- No new files (verification only)

**Step 1: Run root Swift tests**

Run: `swift test`

Expected: PASS

**Step 2: Run GameDemo package tests**

Run: `cd Examples/GameDemo && swift test`

Expected: PASS

**Step 3: Run WebClient build**

Run: `cd Examples/GameDemo/WebClient && npm run build`

Expected: PASS

**Step 4: Re-run replay E2E**

Run: `./Tools/CLI/test-e2e-game.sh`

Expected: PASS (json/jsonOpcode/messagepack)

**Step 5: Commit verification touchpoint (if any generated/docs changed)**

```bash
git add <changed-files>
git commit -m "chore: finalize replay live-state verification"
```

---

## Notes / Guardrails

- Keep `/admin/reevaluation/replay/start` backward compatible (request shape unchanged).
- Do not introduce replay fallback wrappers (`currentStateJSON` or nested `base` value wrappers for entity objects).
- Keep replay deterministic behavior and terminal failure semantics unchanged.
- Prefer minimal changes: DRY, YAGNI.
