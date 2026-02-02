# UWS Loadtest + Reevaluation Toggle Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure load tests can disable reevaluation cleanly and fix GameDemo build/test issues introduced by EncodingBenchmark refactor.

**Architecture:** Add a small env-flag helper in `GameContent`, wire it into `GameServer` to gate reevaluation services, and make loadtest scripts set the flag. Clean up the EncodingBenchmark executable so `@main` is valid and tests can build.

**Tech Stack:** Swift 6, Swift Testing, SwiftPM, bash scripts.

### Task 1: Add a failing test for env-flag parsing

**Files:**
- Modify: `Examples/GameDemo/Tests/GameHelpersTests.swift`

**Step 1: Write the failing test**

```swift
@Test("getEnvBool returns default when missing")
func testGetEnvBoolDefault() {
    #expect(getEnvBool(key: "MISSING_FLAG", defaultValue: true, environment: [:]) == true)
    #expect(getEnvBool(key: "MISSING_FLAG", defaultValue: false, environment: [:]) == false)
}
```

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: FAIL with "cannot find 'getEnvBool' in scope"

**Step 3: Write minimal implementation**

```swift
func getEnvBool(key: String, defaultValue: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
```

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/Tests/GameHelpersTests.swift Examples/GameDemo/Sources/GameContent/GameHelpers.swift
git commit -m "test: cover getEnvBool parsing"
```

### Task 2: Gate reevaluation services in GameServer

**Files:**
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`

**Step 1: Write failing test**

Add a test asserting `ENABLE_REEVALUATION=false` disables service registration (if feasible via unit test).

**Step 2: Run test to verify it fails**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: FAIL (service still created)

**Step 3: Implement minimal code**

```swift
let enableReevaluation = getEnvBool(key: "ENABLE_REEVALUATION", defaultValue: true)
if enableReevaluation { register ReevaluationRunnerService and monitor }
```

**Step 4: Run test to verify it passes**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameServer/main.swift
git commit -m "feat: gate reevaluation services by env flag"
```

### Task 3: Update loadtest scripts to disable reevaluation

**Files:**
- Modify: `Examples/GameDemo/ws-loadtest/scripts/run-ws-loadtest.sh`
- Modify: `Examples/GameDemo/scripts/server-loadtest/run-server-loadtest.sh` (only if it starts GameServer in the future)

**Step 1: Write failing test**

Add a shell-test or manual check to ensure the script exports `ENABLE_REEVALUATION=false` before launching GameServer.

**Step 2: Implement**

```bash
ENABLE_REEVALUATION=false swift run GameServer ...
```

**Step 3: Verify**

Run: `./Examples/GameDemo/ws-loadtest/scripts/run-ws-loadtest.sh`
Expected: GameServer logs show reevaluation disabled.

**Step 4: Commit**

```bash
git add Examples/GameDemo/ws-loadtest/scripts/run-ws-loadtest.sh
git commit -m "chore: disable reevaluation in loadtest script"
```

### Task 4: Fix EncodingBenchmark build error

**Files:**
- Rename: `Examples/GameDemo/Sources/EncodingBenchmark/main.swift` → `Examples/GameDemo/Sources/EncodingBenchmark/EncodingBenchmarkMain.swift`

**Step 1: Reproduce build failure**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: FAIL with "`@main` cannot be used in a module that contains top-level code"

**Step 2: Implement minimal fix**

Rename the file to remove `main.swift` special handling.

**Step 3: Verify**

Run: `cd Examples/GameDemo && swift test --filter GameContentTests.GameHelpersTests`
Expected: PASS

**Step 4: Commit**

```bash
git add Examples/GameDemo/Sources/EncodingBenchmark/EncodingBenchmarkMain.swift
git commit -m "fix: rename EncodingBenchmark main file"
```

### Task 5: Full verification

**Files:**
- None

**Step 1: Run GameDemo tests**

Run: `cd Examples/GameDemo && swift test`
Expected: PASS

**Step 2: Optional loadtest smoke**

Run: `Examples/GameDemo/ws-loadtest/scripts/run-ws-loadtest.sh`
Expected: completes without reevaluation warnings.

**Step 3: Commit any remaining changes**

```bash
git status
```

