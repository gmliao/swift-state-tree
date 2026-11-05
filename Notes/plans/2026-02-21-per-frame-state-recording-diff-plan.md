# Per-Frame State Recording & Reevaluation Diff Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add optional per-frame state snapshot recording (debug-only) and integrate `--diff-with` into ReevaluationRunner to compare recorded vs computed state and output field-level differences.

**Architecture:** Env var `ENABLE_STATE_SNAPSHOT_RECORDING` gates recording; ReevaluationRecorder buffers snapshots and writes `{recordPath}-state.jsonl` on save; ReevaluationEngine.run accepts `diffWithPath`, loads recorded JSONL, and runs StateSnapshotDiff after each tick; ReevaluationRunner parses `--diff-with` and passes to engine.

**Tech Stack:** Swift 6, SwiftStateTree, existing reevaluation infrastructure.

---

## Task 1: Add StateSnapshotDiff utility

**Files:**
- Create: `Sources/SwiftStateTree/Support/StateSnapshotDiff.swift`
- Create: `Tests/SwiftStateTreeTests/StateSnapshotDiffTests.swift`

**Step 1: Write the failing test**

Add `Tests/SwiftStateTreeTests/StateSnapshotDiffTests.swift`:

```swift
import Testing
@testable import SwiftStateTree

@Test("StateSnapshotDiff returns empty when both are identical")
func testDiffIdentical() {
    let a: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 64000, "y": 36000]]]]]
    let b: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 64000, "y": 36000]]]]]
    let diffs = StateSnapshotDiff.compare(recorded: a, computed: b, pathPrefix: "")
    #expect(diffs.isEmpty)
}

@Test("StateSnapshotDiff returns path and values when different")
func testDiffSingleField() {
    let a: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 98100, "y": 35689]]]]]
    let b: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 0, "y": 0]]]]]
    let diffs = StateSnapshotDiff.compare(recorded: a, computed: b, pathPrefix: "")
    #expect(diffs.count == 2)
    let paths = Set(diffs.map { $0.path })
    #expect(paths.contains("players.p1.position.v.x"))
    #expect(paths.contains("players.p1.position.v.y"))
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter StateSnapshotDiffTests`
Expected: FAIL (StateSnapshotDiff not found)

**Step 3: Implement StateSnapshotDiff**

Create `Sources/SwiftStateTree/Support/StateSnapshotDiff.swift`:

```swift
import Foundation

/// Recursive JSON diff for state snapshot comparison (debugging reevaluation mismatches).
public enum StateSnapshotDiff: Sendable {
    public struct Difference: Sendable {
        public let path: String
        public let recorded: String
        public let computed: String
    }

    /// Compare two JSON-like dictionaries recursively.
    /// - Parameters:
    ///   - recorded: Ground truth from live recording
    ///   - computed: Result from reevaluation
    ///   - pathPrefix: Current path for nested reporting (e.g. "players.p1")
    /// - Returns: List of differences with path and both values
    public static func compare(
        recorded: [String: Any],
        computed: [String: Any],
        pathPrefix: String = ""
    ) -> [Difference] {
        var diffs: [Difference] = []
        let allKeys = Set(recorded.keys).union(Set(computed.keys))
        for key in allKeys.sorted() {
            let path = pathPrefix.isEmpty ? key : "\(pathPrefix).\(key)"
            let r = recorded[key]
            let c = computed[key]
            if r == nil, c == nil { continue }
            if let rDict = r as? [String: Any], let cDict = c as? [String: Any] {
                diffs.append(contentsOf: compare(recorded: rDict, computed: cDict, pathPrefix: path))
            } else if let rArr = r as? [Any], let cArr = c as? [Any] {
                if rArr.count != cArr.count {
                    diffs.append(Difference(path: path, recorded: "\(rArr.count) items", computed: "\(cArr.count) items"))
                } else {
                    for (i, (rv, cv)) in zip(rArr, cArr).enumerated() {
                        let p = "\(path)[\(i)]"
                        if let rd = rv as? [String: Any], let cd = cv as? [String: Any] {
                            diffs.append(contentsOf: compare(recorded: rd, computed: cd, pathPrefix: p))
                        } else if !isEqual(rv, cv) {
                            diffs.append(Difference(path: p, recorded: "\(rv)", computed: "\(cv)"))
                        }
                    }
                }
            } else if !isEqual(r, c) {
                diffs.append(Difference(
                    path: path,
                    recorded: r.map { "\($0)" } ?? "nil",
                    computed: c.map { "\($0)" } ?? "nil"
                ))
            }
        }
        return diffs
    }

    private static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if let ad = a as? [String: Any], let bd = b as? [String: Any] {
            return compare(recorded: ad, computed: bd, pathPrefix: "").isEmpty
        }
        return "\(a)" == "\(b)"
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter StateSnapshotDiffTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Support/StateSnapshotDiff.swift Tests/SwiftStateTreeTests/StateSnapshotDiffTests.swift
git commit -m "feat(reevaluation): add StateSnapshotDiff utility for field-level comparison"
```

---

## Task 2: Add recordStateSnapshot to ReevaluationRecorder

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`

**Step 1: Add state snapshot buffer and recordStateSnapshot**

In `ReevaluationRecorder` actor, add:
- `private var stateSnapshotsByTick: [Int64: StateSnapshot] = [:]`
- `public func recordStateSnapshot(tickId: Int64, stateSnapshot: StateSnapshot)`

Implementation: store `stateSnapshotsByTick[tickId] = stateSnapshot`.

**Step 2: In save(to:), write state JSONL when buffer non-empty**

After writing main JSON file, if `!stateSnapshotsByTick.isEmpty`:
- Derive state path: `filePath.replacingOccurrences(of: ".json", with: "-state.jsonl")` (handle edge case: if no ".json", append "-state.jsonl")
- Create FileHandle, encoder (JSONEncoder, sortedKeys)
- For each tickId in sorted order, encode `{"tickId": tickId, "stateSnapshot": snapshot}` (StateSnapshot is Codable), write line + newline
- Close handle
- Clear `stateSnapshotsByTick` after write

Use same structure as `ReevaluationJsonlExporter.TickLine` but we only need tickId + stateSnapshot for the recorded file. Create a small struct `RecordedStateLine: Codable { let tickId: Int64; let stateSnapshot: StateSnapshot }`.

**Step 3: Run tests**

Run: `swift test --filter ReevaluationReplayCompatibilityTests`
Expected: PASS (no behavior change when recordStateSnapshot not called)

**Step 4: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ActionRecorder.swift
git commit -m "feat(reevaluation): add recordStateSnapshot and write state JSONL in save"
```

---

## Task 3: Add env key and LandKeeper integration

**Files:**
- Modify: `Sources/SwiftStateTree/Support/EnvHelpers.swift` (add key constant if needed)
- Modify: `Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift` (add calculateStateHashAndSnapshot)
- Modify: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`

**Step 1: Add calculateStateHashAndSnapshot to ReevaluationEngine**

```swift
public static func calculateStateHashAndSnapshot<State: StateNodeProtocol>(_ state: State) -> (hash: String, snapshot: StateSnapshot) {
    let syncEngine = SyncEngine()
    let snapshot: StateSnapshot
    do {
        snapshot = try syncEngine.snapshot(from: state, mode: .all)
    } catch {
        return ("error", StateSnapshot())
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(snapshot) else {
        return ("error", snapshot)
    }
    return (DeterministicHash.toHex64(DeterministicHash.fnv1a64(data)), snapshot)
}
```

**Step 2: In LandKeeper tick completion, use new method when state snapshot recording on**

Add env check: `EnvHelpers.getEnvBool(key: "ENABLE_STATE_SNAPSHOT_RECORDING", defaultValue: false)`.

When `enableLiveStateHashRecording` and `reevaluationRecorder` exist:
- If state snapshot recording env is true: call `ReevaluationEngine.calculateStateHashAndSnapshot(state)`, use `.hash` for `setStateHash`, and `await recorder.recordStateSnapshot(tickId: tickId, stateSnapshot: snapshot)`
- Else: keep current `ReevaluationEngine.calculateStateHash(state)` and `setStateHash`

**Step 3: Run tests**

Run: `swift test`
Expected: PASS

**Step 4: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift Sources/SwiftStateTree/Runtime/LandKeeper.swift
git commit -m "feat(reevaluation): integrate state snapshot recording in LandKeeper via env"
```

---

## Task 4: Add diffWithPath to ReevaluationEngine.run

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift`

**Step 1: Add diffWithPath parameter and load recorded state**

In `ReevaluationEngine.run`, add parameter `diffWithPath: String? = nil`.

When `diffWithPath != nil`:
- Check file exists; if not, throw or return error (design: exit 1 from runner, so we can throw)
- Read file line by line, parse each line as JSON `{"tickId": Int64, "stateSnapshot": ...}`. StateSnapshot is Codable. Build `[Int64: StateSnapshot]` or `[Int64: [String: Any]]` for comparison. For diff we need `[String: Any]` - encode StateSnapshot to JSON then decode to [String: Any] for flexibility.
- Store as `recordedStatesByTick: [Int64: [String: Any]]`

**Step 2: After each tick, run diff when both recorded and computed exist**

After `let snapshot = try syncEngine.snapshot(...)`:
- If diffWithPath was provided and `recordedStatesByTick[tickId]` exists:
  - Encode snapshot to JSON, decode to `[String: Any]` (use JSONSerialization)
  - Call `StateSnapshotDiff.compare(recorded: recorded, computed: computed, pathPrefix: "")`
  - If diffs not empty: print to stderr, e.g. `[tick \(tickId)] DIFF at \(d.path): recorded=\(d.recorded) computed=\(d.computed)` for each

**Step 3: RunResult and output**

RunResult does not need to change. Diff output goes to stderr. Caller (ReevaluationRunner) does not need to handle it.

**Step 4: Run tests**

Run: `swift test --filter ReevaluationEngineTests`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/ReevaluationEngine.swift
git commit -m "feat(reevaluation): add diffWithPath to ReevaluationEngine.run for state diff"
```

---

## Task 5: Add --diff-with to ReevaluationRunner (GameDemo)

**Files:**
- Modify: `Examples/GameDemo/Sources/ReevaluationRunner/main.swift`

**Step 1: Parse --diff-with**

Add `var diffWithPath: String?` and in the argument loop:
```swift
case "--diff-with":
    diffWithPath = (i + 1 < args.count) ? args[i + 1] : nil
    i += 2
```

**Step 2: Pass to ReevaluationEngine.run**

Add `diffWithPath: diffWithPath` to the `ReevaluationEngine.run` call.

**Step 3: Update help**

Add to help text: `--diff-with <path>  Compare with recorded state JSONL (output field-level diffs)`

**Step 4: Verify file exists before run**

If `diffWithPath != nil` and file does not exist: `print("Error: --diff-with file not found: \(path)"); exit(1)`.

**Step 5: Run manually**

```bash
cd Examples/GameDemo && swift run ReevaluationRunner --input reevaluation-records/3-hero-defense.json --help
```
Expected: help shows --diff-with

**Step 6: Commit**

```bash
git add Examples/GameDemo/Sources/ReevaluationRunner/main.swift
git commit -m "feat(reevaluation): add --diff-with to GameDemo ReevaluationRunner"
```

---

## Task 6: Integration test and documentation

**Files:**
- Modify: `Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift` or add new test
- Modify: `docs/core/reevaluation.zh-TW.md` and `docs/core/reevaluation.md`

**Step 1: Add integration test for state recording**

Create a test that:
1. Runs LandKeeper in live mode with `enableLiveStateHashRecording: true` and `ENABLE_STATE_SNAPSHOT_RECORDING=true`
2. Executes a few ticks
3. Saves record via recorder.save(to:)
4. Asserts that `{path}-state.jsonl` exists and has lines

**Step 2: Update reevaluation docs**

Add section:
- When `ENABLE_STATE_SNAPSHOT_RECORDING=true`, live recording also writes `*-state.jsonl`
- Use `--diff-with <path>` to compare recorded vs computed state and see field-level diffs

**Step 3: Run full test suite**

Run: `swift test`
Expected: PASS

**Step 4: Commit**

```bash
git add Tests/SwiftStateTreeTests/ReevaluationEngineTests.swift docs/core/reevaluation.md docs/core/reevaluation.zh-TW.md
git commit -m "docs(reevaluation): document state snapshot recording and --diff-with"
```

---

## Verification Checklist

- [ ] `ENABLE_STATE_SNAPSHOT_RECORDING=true` produces `*-state.jsonl` alongside main record
- [ ] `ReevaluationRunner --input X.json --diff-with X-state.jsonl` runs and outputs diffs on mismatch
- [ ] StateSnapshotDiff unit tests pass
- [ ] All `swift test` pass
