# Full-Snapshot Sync Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `SyncStrategy` (`delta` | `fullSnapshot`) to `TransportAdapter` so the same Land, workload and encoder can send a full per-recipient view every sync, prove both strategies yield identical client views, and expose the switch in `EncodingBenchmark`.

**Architecture:** `SyncEngine` gains a `DiffBaseline` (`.cached` = today's behaviour, `.empty` = compare against an empty snapshot and leave caches untouched). `TransportAdapter` maps `syncStrategy == .fullSnapshot` to `.empty` plus forced `.all` snapshot modes at its existing diff call sites. The late-join path, the encoders and the default behaviour are untouched; with the env var unset and the init parameter defaulted, every byte sent is identical to today.

**Tech Stack:** Swift 6 (Swift Testing framework, `@Test` / `#expect`), SwiftPM, `swift-log`. Verification: `swift test`, `./Tools/CLI/test-e2e-game.sh`.

**Spec:** `Notes/plans/specs/2026-09-15-snapshot-baseline-design.md`

## Global Constraints

- Branch: `feat/sync-strategy-full-snapshot` (already created; the spec is its first commit). Tasks 1–5 commit here; the PR is opened at the end of Task 5. Task 6 (benchmark flag) lands on `main` via `sst-direct-change` **after** the PR merges.
- Core paths (`Sources/`, `Tests/`) follow `sst-core-change`; do not touch `Package.swift`.
- All code comments and commit messages in English. Commit trailers: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01LixpenKC5cZmfpmaYJS3xV`.
- Swift Testing only (no XCTest). Tests that build a `TransportAdapter` must wait ~100 ms after `syncNow()` because sends are dispatched with `Task { await transport.send(...) }`.
- Never mutate process environment inside tests (tests run in parallel). Use the `transportEnvConfig:` override added in Task 3 instead.
- `docs/` is bilingual: any edit to `docs/transport/README.md` must be mirrored in `docs/transport/README.zh-TW.md` in the same commit.
- Env var name: `SYNC_STRATEGY`; values: `delta` (default), `full-snapshot`.

---

## File map

| File | Change |
|---|---|
| `Sources/SwiftStateTreeTransport/SyncStrategy.swift` | **Create.** `public enum SyncStrategy: String, Sendable { case delta; case fullSnapshot = "full-snapshot" }` + `static func parse(_:default:)`. |
| `Sources/SwiftStateTreeTransport/TransportEnvKeys.swift` | Add `static let syncStrategy = "SYNC_STRATEGY"`. |
| `Sources/SwiftStateTreeTransport/TransportEnvConfig.swift` | Add `syncStrategy` field, header table row, `fromEnvironment(enableDirtyTrackingDefault:syncStrategyDefault:)`. |
| `Sources/SwiftStateTree/Sync/SyncEngine.swift` | Add `DiffBaseline`; `baseline:` parameter on `computeBroadcastDiffFromSnapshot`, `computePerPlayerDiffFromSnapshot`, `generateUpdateFromBroadcastDiff`, `generatePerPlayerUpdateFromSnapshot`. |
| `Sources/SwiftStateTreeTransport/TransportAdapter.swift` | `syncStrategy` + `transportEnvConfig` init params, stored property, `diffBaseline` helper, forced `.all` modes, baseline forwarded at 3 diff sites + 2 update-generation sites, log line. |
| `Tests/SwiftStateTreeTransportTests/SyncStrategyTests.swift` | **Create.** Parse test + `TransportEnvConfig` wiring test. |
| `Tests/SwiftStateTreeTests/SyncEngineDiffBaselineTests.swift` | **Create.** `.empty` baseline behaviour on `SyncEngine`. |
| `Tests/SwiftStateTreeTransportTests/TransportAdapterSyncStrategyTests.swift` | **Create.** Adapter-level full-snapshot behaviour. |
| `Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift` | **Create.** Delta vs full client-view equivalence on both extraction paths. |
| `docs/transport/README.md`, `docs/transport/README.zh-TW.md` | Env-var table row. |
| `Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkConfig.swift`, `BenchmarkResults.swift`, `EncodingBenchmarkMain.swift` | `--sync-strategy`, JSON field, table column (Task 6, after merge). |

---

### Task 1: `SyncStrategy` type and env config wiring

**Files:**
- Create: `Sources/SwiftStateTreeTransport/SyncStrategy.swift`
- Modify: `Sources/SwiftStateTreeTransport/TransportEnvKeys.swift:8-16`
- Modify: `Sources/SwiftStateTreeTransport/TransportEnvConfig.swift:8-22` (header table), `:31-47` (struct + signature), `:101-112` (return)
- Test: `Tests/SwiftStateTreeTransportTests/SyncStrategyTests.swift`

**Interfaces:**
- Produces: `public enum SyncStrategy: String, Sendable { case delta, fullSnapshot }`, `SyncStrategy.parse(_ raw: String?, default: SyncStrategy) -> SyncStrategy`, `TransportEnvConfig.syncStrategy: SyncStrategy`, `TransportEnvConfig.fromEnvironment(enableDirtyTrackingDefault: Bool = true, syncStrategyDefault: SyncStrategy = .delta)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SwiftStateTreeTransportTests/SyncStrategyTests.swift

import Testing
@testable import SwiftStateTreeTransport

@Test("SyncStrategy.parse maps raw values and falls back to the default")
func testSyncStrategyParse() {
    #expect(SyncStrategy.parse(nil, default: .delta) == .delta)
    #expect(SyncStrategy.parse(nil, default: .fullSnapshot) == .fullSnapshot)
    #expect(SyncStrategy.parse("delta", default: .fullSnapshot) == .delta)
    #expect(SyncStrategy.parse("full-snapshot", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse("FULL-SNAPSHOT", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse(" full-snapshot ", default: .delta) == .fullSnapshot)
    #expect(SyncStrategy.parse("garbage", default: .delta) == .delta)
    #expect(SyncStrategy.parse("", default: .fullSnapshot) == .fullSnapshot)
}

@Test("TransportEnvConfig carries the sync strategy default when the env var is unset")
func testTransportEnvConfigSyncStrategyDefault() {
    // SYNC_STRATEGY is not set in the test process; the init default must win.
    let config = TransportEnvConfig.fromEnvironment(syncStrategyDefault: .fullSnapshot)
    #expect(config.syncStrategy == .fullSnapshot)
    let defaultConfig = TransportEnvConfig.fromEnvironment()
    #expect(defaultConfig.syncStrategy == .delta)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncStrategyTests`
Expected: compile error — `SyncStrategy` not found.

- [ ] **Step 3: Create `SyncStrategy.swift`**

```swift
// Sources/SwiftStateTreeTransport/SyncStrategy.swift
//
// Selects what a regular sync cycle sends to each recipient.

import Foundation

/// What `TransportAdapter` sends on every `syncNow()` / broadcast-only sync.
///
/// - `delta`: only fields that changed since the previous sync (today's behaviour).
/// - `fullSnapshot`: the recipient's complete visible view every sync, even when
///   nothing changed. Exists as a controlled baseline for measuring the delta
///   strategy; it is not a production mode.
///
/// Late-join initial sync always sends a full snapshot regardless of this setting.
public enum SyncStrategy: String, Sendable, CaseIterable {
    case delta
    case fullSnapshot = "full-snapshot"

    /// Parse a raw env value. Case-insensitive, whitespace-trimmed; unknown or
    /// empty values return `defaultValue`.
    public static func parse(_ raw: String?, default defaultValue: SyncStrategy) -> SyncStrategy {
        guard let raw else { return defaultValue }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SyncStrategy(rawValue: normalized) ?? defaultValue
    }

    /// Environment variable that overrides the init default (`SYNC_STRATEGY`).
    /// Public so tools outside the module (e.g. benchmarks) can set it without
    /// reaching into the internal `TransportEnvKeys`.
    public static let environmentKey = "SYNC_STRATEGY"
}
```

- [ ] **Step 4: Add the env key**

In `TransportEnvKeys.swift`, after `static let useSnapshotForSync = "USE_SNAPSHOT_FOR_SYNC"` add:

```swift
    static let syncStrategy = SyncStrategy.environmentKey
```

- [ ] **Step 5: Wire `TransportEnvConfig`**

Header table (after the `USE_SNAPSHOT_FOR_SYNC` row):

```
// | SYNC_STRATEGY | String | init param | "delta" or "full-snapshot" (case-insensitive); unknown values use init default |
```

Struct field (after `useSnapshotForSync`):

```swift
    public let syncStrategy: SyncStrategy
```

Signature and body:

```swift
    /// Create config from environment. Init params `enableDirtyTrackingDefault` and
    /// `syncStrategyDefault` are used when the matching env var is unset.
    public static func fromEnvironment(
        enableDirtyTrackingDefault: Bool = true,
        syncStrategyDefault: SyncStrategy = .delta
    ) -> TransportEnvConfig {
        let env = ProcessInfo.processInfo.environment
        // ... existing body unchanged ...
        let syncStrategy = SyncStrategy.parse(env[TransportEnvKeys.syncStrategy], default: syncStrategyDefault)
```

and in the `return TransportEnvConfig(...)` add `syncStrategy: syncStrategy,` right after `useSnapshotForSync: useSnapshotForSync,`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter SyncStrategyTests`
Expected: 2 tests PASS. Then `swift build` to confirm nothing else broke (memberwise init callers of `TransportEnvConfig` — grep `TransportEnvConfig(` in `Sources/` and `Tests/`; add `syncStrategy: .delta` to any hit).

- [ ] **Step 7: Commit**

```bash
git add Sources/SwiftStateTreeTransport/SyncStrategy.swift Sources/SwiftStateTreeTransport/TransportEnvKeys.swift Sources/SwiftStateTreeTransport/TransportEnvConfig.swift Tests/SwiftStateTreeTransportTests/SyncStrategyTests.swift
git commit -m "Add SyncStrategy and SYNC_STRATEGY env config"
```

---

### Task 2: `SyncEngine.DiffBaseline`

**Files:**
- Modify: `Sources/SwiftStateTree/Sync/SyncEngine.swift:548-586` (`computeBroadcastDiffFromSnapshot`), `:586-630` (`computePerPlayerDiffFromSnapshot`), `:724-750` (`generateUpdateFromBroadcastDiff`), `:761-780` (`generatePerPlayerUpdateFromSnapshot`)
- Test: `Tests/SwiftStateTreeTests/SyncEngineDiffBaselineTests.swift`

**Interfaces:**
- Produces: `public enum DiffBaseline: Sendable { case cached, empty }` (nested as `SyncEngine.DiffBaseline`); `baseline: DiffBaseline = .cached` parameter on the four methods above. `.cached` is byte-for-byte the existing path.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SwiftStateTreeTests/SyncEngineDiffBaselineTests.swift

import Testing
@testable import SwiftStateTree

@StateNodeBuilder
private struct BaselineTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    init() {}
}

private func setValues(_ patches: [StatePatch]) -> [String: SnapshotValue] {
    var out: [String: SnapshotValue] = [:]
    for patch in patches {
        if case .set(let value) = patch.operation {
            out[patch.path] = value
        }
    }
    return out
}

@Test("empty baseline returns a set patch for every broadcast field and never seeds the cache")
func testEmptyBaselineBroadcast() throws {
    var engine = SyncEngine()
    var state = BaselineTestState()
    state.tick = 3
    state.monsters = [1: 10, 2: 20]

    let snapshot = try engine.extractBroadcastSnapshot(from: state, mode: .all)

    // First call with .empty must already return full content (no "seed and return []").
    let first = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .empty)
    let firstSets = setValues(first)
    #expect(firstSets["/tick"] == .int(3))
    #expect(firstSets["/monsters"] != nil)
    #expect(first.allSatisfy { if case .set = $0.operation { return true } else { return false } })

    // Second identical call must return the same full content: cache was not written.
    let second = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .empty)
    #expect(setValues(second) == firstSets)

    // A subsequent .cached call behaves like a first call (cache still empty): seeds and returns [].
    let cachedFirst = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, onlyPaths: nil, mode: .all, baseline: .cached)
    #expect(cachedFirst.isEmpty)
}

@Test("empty baseline on per-player update returns diff with every per-player field, cache untouched")
func testEmptyBaselinePerPlayer() throws {
    var engine = SyncEngine()
    let alice = PlayerID("alice")
    var state = BaselineTestState()
    state.inventories[alice] = ["sword"]

    let perPlayer = try engine.extractPerPlayerSnapshot(for: alice, from: state, mode: .all)
    engine.markFirstSyncReceived(for: alice)

    let update = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: perPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    guard case .diff(let patches) = update else {
        Issue.record("expected .diff, got \(update)")
        return
    }
    #expect(setValues(patches)["/inventories"] != nil)

    // Repeat: identical output proves the per-player cache was not populated.
    let again = engine.generatePerPlayerUpdateFromSnapshot(for: alice, perPlayerSnapshot: perPlayer, perPlayerMode: .all, onlyPaths: nil, baseline: .empty)
    #expect(again == update)
}

@Test("cached baseline is unchanged: first call seeds, second call diffs")
func testCachedBaselineUnchanged() throws {
    var engine = SyncEngine()
    var state = BaselineTestState()
    state.tick = 1
    let s1 = try engine.extractBroadcastSnapshot(from: state, mode: .all)
    #expect(engine.computeBroadcastDiffFromSnapshot(currentBroadcast: s1, onlyPaths: nil, mode: .all, baseline: .cached).isEmpty)
    state.tick = 2
    let s2 = try engine.extractBroadcastSnapshot(from: state, mode: .all)
    let diff = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: s2, onlyPaths: nil, mode: .all, baseline: .cached)
    #expect(setValues(diff) == ["/tick": .int(2)])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncEngineDiffBaselineTests`
Expected: compile error — extra argument `baseline:` in call.

- [ ] **Step 3: Add `DiffBaseline` and the parameter**

At the top of `SyncEngine` (inside the struct, before `lastBroadcastSnapshot`):

```swift
    /// What a diff is computed against.
    ///
    /// - `cached`: the previous snapshot held in the engine's cache; the cache is updated afterwards.
    /// - `empty`: an empty snapshot, so every field becomes a `.set` patch (a full view).
    ///   The cache is neither read nor written. Used by the full-snapshot sync strategy.
    public enum DiffBaseline: Sendable {
        case cached
        case empty
    }
```

`computeBroadcastDiffFromSnapshot` — new signature and early return:

```swift
    public mutating func computeBroadcastDiffFromSnapshot(
        currentBroadcast: StateSnapshot,
        onlyPaths: Set<String>? = nil,
        mode: SnapshotMode = .all,
        baseline: DiffBaseline = .cached
    ) -> [StatePatch] {
        if case .empty = baseline {
            return compareSnapshots(from: StateSnapshot(values: [:]), to: currentBroadcast, onlyPaths: onlyPaths, dirtyFields: nil)
        }
        // ... existing body unchanged ...
```

`computePerPlayerDiffFromSnapshot` — same shape:

```swift
    private mutating func computePerPlayerDiffFromSnapshot(
        for playerID: PlayerID,
        currentPerPlayer: StateSnapshot,
        onlyPaths: Set<String>?,
        mode: SnapshotMode = .all,
        baseline: DiffBaseline = .cached
    ) -> [StatePatch] {
        if case .empty = baseline {
            return compareSnapshots(from: StateSnapshot(values: [:]), to: currentPerPlayer, onlyPaths: onlyPaths, dirtyFields: nil)
        }
        // ... existing body unchanged ...
```

`generateUpdateFromBroadcastDiff` and `generatePerPlayerUpdateFromSnapshot`: add `baseline: DiffBaseline = .cached` as the last parameter and forward it to `computePerPlayerDiffFromSnapshot(..., mode: perPlayerMode, baseline: baseline)`.

Note: in `.empty` mode `dirtyFields` is `nil` on purpose — a dirty-field filter would drop unchanged fields from a "full" view.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncEngineDiffBaselineTests`
Expected: 3 tests PASS. Then `swift test --filter SyncEngine` to confirm existing sync-engine tests still pass (default argument means no call site changes).

- [ ] **Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Sync/SyncEngine.swift Tests/SwiftStateTreeTests/SyncEngineDiffBaselineTests.swift
git commit -m "Add DiffBaseline to SyncEngine diff-from-snapshot APIs"
```

---

### Task 3: `TransportAdapter` honours `syncStrategy`

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift:66-70` (stored props), `:148-166` (init signature), `:211-224` (env config), `:261-272` (log), `:1185-1198` (`runSyncNowCycle`), `:1242-1256` (`computeSyncModes`), `:1259-1272` (`extractSyncSnapshots`), `:1355-1380` (`collectPerPlayerOnlyPendingUpdates`), `:1392-1412` (`collectCombinedPendingUpdates`), `:1526-1545` (`_syncBroadcastOnlyImpl`), `:1564-1595` (`extractAndComputeBroadcastDiff`), `:2065-2085` (`syncState(for:)`)
- Test: `Tests/SwiftStateTreeTransportTests/TransportAdapterSyncStrategyTests.swift`

**Interfaces:**
- Consumes: `SyncStrategy`, `TransportEnvConfig.syncStrategy` (Task 1); `SyncEngine.DiffBaseline` and `baseline:` params (Task 2).
- Produces: `TransportAdapter.init(..., enableDirtyTracking: Bool = true, syncStrategy: SyncStrategy = .delta, transportEnvConfig: TransportEnvConfig? = nil, ...)`. `transportEnvConfig` bypasses `fromEnvironment` entirely (tests and benchmarks); `syncStrategy` is the init default that `SYNC_STRATEGY` may override.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncStrategyTests.swift

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct StrategyTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var label: String = "idle"
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

/// Records every send with its target so per-session streams can be reconstructed.
actor SessionRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }
    func messages(for sessionID: SessionID) -> [Data] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
    func clear() { sent.removeAll() }
}

/// Decode JSON-encoded state updates; non-state frames (events) are skipped.
func decodeStateUpdates(_ frames: [Data]) -> [StateUpdate] {
    let decoder = JSONStateUpdateDecoder()
    return frames.compactMap { try? decoder.decode(data: $0).update }
}

private func makeEnvConfig(strategy: SyncStrategy, useSnapshotForSync: Bool) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: strategy,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil
    )
}

@Test("full-snapshot strategy sends the complete view every sync, even with no change", arguments: [true, false])
func testFullSnapshotSendsEverySync(useSnapshotForSync: Bool) async throws {
    let definition = Land("strategy-test", using: StrategyTestState.self) {
        Rules {
            OnJoin { (state: inout StrategyTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
            }
        }
    }
    let transport = SessionRecordingTransport()
    let keeper = LandKeeper<StrategyTestState>(definition: definition, initialState: StrategyTestState())
    let adapter = TransportAdapter<StrategyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "strategy-test",
        transportEnvConfig: makeEnvConfig(strategy: .fullSnapshot, useSnapshotForSync: useSnapshotForSync)
    )
    await transport.setDelegate(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    let player = PlayerID("p1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    try await Task.sleep(for: .milliseconds(100))
    await transport.clear()

    // Two syncs with no state change at all.
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))

    let updates = decodeStateUpdates(await transport.messages(for: session))
    #expect(updates.count == 2, "full-snapshot must send on every sync; got \(updates.count)")
    for update in updates {
        guard case .diff(let patches) = update else {
            Issue.record("expected .diff, got \(update)")
            continue
        }
        let paths = Set(patches.map(\.path))
        #expect(paths.contains("/tick"))
        #expect(paths.contains("/label"))
        #expect(paths.contains("/scores"))
        #expect(patches.allSatisfy { if case .set = $0.operation { return true } else { return false } })
    }
}

@Test("delta strategy (default) sends nothing when nothing changed", arguments: [true, false])
func testDeltaSendsNothingWhenUnchanged(useSnapshotForSync: Bool) async throws {
    let definition = Land("strategy-test-delta", using: StrategyTestState.self) {
        Rules {
            OnJoin { (state: inout StrategyTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
            }
        }
    }
    let transport = SessionRecordingTransport()
    let keeper = LandKeeper<StrategyTestState>(definition: definition, initialState: StrategyTestState())
    let adapter = TransportAdapter<StrategyTestState>(
        keeper: keeper,
        transport: transport,
        landID: "strategy-test-delta",
        transportEnvConfig: makeEnvConfig(strategy: .delta, useSnapshotForSync: useSnapshotForSync)
    )
    await transport.setDelegate(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
    try await Task.sleep(for: .milliseconds(100))
    // First regular sync after join may emit firstSync bookkeeping; drain it.
    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    await transport.clear()

    await adapter.syncNow()
    try await Task.sleep(for: .milliseconds(100))
    let updates = decodeStateUpdates(await transport.messages(for: session))
    #expect(updates.isEmpty, "delta must not send when unchanged; got \(updates)")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TransportAdapterSyncStrategyTests`
Expected: compile error — extra argument `transportEnvConfig:` in call (and `syncStrategy:` missing from `TransportEnvConfig` memberwise init until Task 1 is merged — it is).

- [ ] **Step 3: Init parameters and stored property**

Stored property (next to `private let useSnapshotForSync: Bool`):

```swift
    private let syncStrategy: SyncStrategy
```

Init signature: after `enableDirtyTracking: Bool = true,` add

```swift
        syncStrategy: SyncStrategy = .delta,
        transportEnvConfig: TransportEnvConfig? = nil,
```

Doc comment `**Tuning**` line becomes: `` **Tuning**: `enableDirtyTracking`, `syncStrategy`, `expectedSchemaHash`; `transportEnvConfig` replaces env lookup entirely (tests/benchmarks) ``.

Replace the env config line:

```swift
        let envConfig = transportEnvConfig ?? TransportEnvConfig.fromEnvironment(
            enableDirtyTrackingDefault: enableDirtyTracking,
            syncStrategyDefault: syncStrategy
        )
        self.enableDirtyTracking = envConfig.enableDirtyTracking
        self.useSnapshotForSync = envConfig.useSnapshotForSync
        self.syncStrategy = envConfig.syncStrategy
```

Log metadata: add `"syncStrategy": .string(envConfig.syncStrategy.rawValue),` after the `snapshotForSync` entry.

- [ ] **Step 4: Baseline helper and forced modes**

Add next to `computeSyncModes`:

```swift
    /// Diff baseline implied by the sync strategy.
    private var diffBaseline: SyncEngine.DiffBaseline {
        syncStrategy == .fullSnapshot ? .empty : .cached
    }
```

`computeSyncModes` — first line of the body:

```swift
        if syncStrategy == .fullSnapshot {
            return (.all, .all)
        }
```

`extractSyncSnapshots` legacy branch — `fullMode` becomes:

```swift
            let fullMode: SnapshotMode = (syncStrategy == .delta && enableDirtyTracking && state.isDirty())
                ? .dirtyTracking(state.getDirtyFields())
                : .all
```

`extractAndComputeBroadcastDiff` (broadcast-only path) — wrap the mode computation:

```swift
        let broadcastMode: SnapshotMode
        if syncStrategy == .delta, enableDirtyTracking && state.isDirty() {
            // ... existing dirty-field narrowing unchanged ...
        } else {
            broadcastMode = .all
        }
```

- [ ] **Step 5: Forward the baseline at every diff / update-generation call site**

Three `syncEngine.computeBroadcastDiffFromSnapshot(...)` calls (`runSyncNowCycle`, `extractAndComputeBroadcastDiff`, and the one inside `extractSyncSnapshots`'s caller if any — grep to be sure) gain `baseline: diffBaseline`.

`collectPerPlayerOnlyPendingUpdates` → `syncEngine.generatePerPlayerUpdateFromSnapshot(..., onlyPaths: nil, baseline: diffBaseline)`.

`collectCombinedPendingUpdates` and `syncState(for:)` → `syncEngine.generateUpdateFromBroadcastDiff(..., onlyPaths: nil, baseline: diffBaseline)`.

Verify with: `grep -n "computeBroadcastDiffFromSnapshot\|generateUpdateFromBroadcastDiff\|generatePerPlayerUpdateFromSnapshot" Sources/SwiftStateTreeTransport/TransportAdapter.swift` — every hit must carry `baseline:`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TransportAdapterSyncStrategyTests`
Expected: 4 test cases PASS (2 tests × 2 arguments). Then `swift test --filter TransportAdapter` — all existing adapter tests still pass (default strategy path unchanged).

- [ ] **Step 7: Commit**

```bash
git add Sources/SwiftStateTreeTransport/TransportAdapter.swift Tests/SwiftStateTreeTransportTests/TransportAdapterSyncStrategyTests.swift
git commit -m "Honour SyncStrategy in TransportAdapter sync paths"
```

---

### Task 4: Delta vs full-snapshot client-view equivalence test

**Files:**
- Create: `Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift`
- Reuses: `SessionRecordingTransport`, `decodeStateUpdates` (Task 3 test file — they are internal to the test target, so visible here).

**Interfaces:**
- Consumes: everything from Tasks 1–3.

- [ ] **Step 1: Write the test (it should pass immediately if Task 3 is correct; a failure here is a real bug in either strategy)**

```swift
// Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift
//
// Drives one Land with the same script under both sync strategies and checks that
// every session's client-side view, rebuilt from the received patches, is identical
// after every sync — and identical to the authoritative per-player snapshot.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct EquivState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.broadcast) var monsters: [Int: Int] = [:]
    @Sync(.perPlayerSlice()) var inventories: [PlayerID: [String]] = [:]
    @Sync(.serverOnly) var secret: Int = 0
    init() {}
}

@Payload
private struct EquivStepEvent: ClientEventPayload {
    let addMonster: Int?
    let removeMonster: Int?
    let item: String?
}

/// Minimal client model: a JSON-pointer patch applier over a SnapshotValue tree.
private struct ClientView: Equatable {
    var root: [String: SnapshotValue] = [:]

    mutating func apply(_ patches: [StatePatch]) {
        for patch in patches {
            let parts = patch.path.split(separator: "/").map { String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
            guard !parts.isEmpty else { continue }
            switch patch.operation {
            case .set(let value): root = Self.setting(root, parts[...], value)
            case .delete: root = Self.deleting(root, parts[...])
            }
        }
    }

    private static func setting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>, _ value: SnapshotValue) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = value; return obj }
        let child = obj[key]?.objectValue ?? [:]
        obj[key] = .object(setting(child, parts.dropFirst(), value))
        return obj
    }

    private static func deleting(_ obj: [String: SnapshotValue], _ parts: ArraySlice<String>) -> [String: SnapshotValue] {
        var obj = obj
        let key = parts[parts.startIndex]
        if parts.count == 1 { obj[key] = nil; return obj }
        guard let child = obj[key]?.objectValue else { return obj }
        obj[key] = .object(deleting(child, parts.dropFirst()))
        return obj
    }
}

private struct Harness {
    let keeper: LandKeeper<EquivState>
    let adapter: TransportAdapter<EquivState>
    let transport: SessionRecordingTransport
    var views: [SessionID: ClientView] = [:]

    init(strategy: SyncStrategy, useSnapshotForSync: Bool, landID: String) {
        let definition = Land(landID, using: EquivState.self) {
            ClientEvents { Register(EquivStepEvent.self) }
            Rules {
                OnJoin { (state: inout EquivState, ctx: LandContext) in
                    state.inventories[ctx.playerID] = []
                }
                OnLeave { (state: inout EquivState, ctx: LandContext) in
                    state.inventories.removeValue(forKey: ctx.playerID)
                }
                HandleEvent(EquivStepEvent.self) { (state: inout EquivState, ev: EquivStepEvent, ctx: LandContext) in
                    state.tick += 1
                    state.secret += 7
                    if let m = ev.addMonster { state.monsters[m] = 100 - m }
                    if let m = ev.removeMonster { state.monsters.removeValue(forKey: m) }
                    if let item = ev.item { state.inventories[ctx.playerID, default: []].append(item) }
                }
            }
        }
        transport = SessionRecordingTransport()
        keeper = LandKeeper<EquivState>(definition: definition, initialState: EquivState())
        adapter = TransportAdapter<EquivState>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: useSnapshotForSync,
                syncStrategy: strategy,
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            )
        )
    }

    func start() async { await transport.setDelegate(adapter) }

    mutating func join(_ n: Int) async throws {
        let s = SessionID("s\(n)"); let c = ClientID("c\(n)"); let p = PlayerID("p\(n)")
        await adapter.onConnect(sessionID: s, clientID: c)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: s, clientID: c, playerID: p)
        views[s] = ClientView()
    }

    func leave(_ n: Int) async {
        await adapter.onDisconnect(sessionID: SessionID("s\(n)"), clientID: ClientID("c\(n)"))
    }

    func step(_ n: Int, add: Int? = nil, remove: Int? = nil, item: String? = nil) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(EquivStepEvent(addMonster: add, removeMonster: remove, item: item)),
            playerID: PlayerID("p\(n)"), clientID: ClientID("c\(n)"), sessionID: SessionID("s\(n)")
        )
    }

    /// Drain everything the transport has sent so far into the client views.
    mutating func drain() async throws {
        try await Task.sleep(for: .milliseconds(100))
        for session in views.keys {
            for update in decodeStateUpdates(await transport.messages(for: session)) {
                switch update {
                case .firstSync(let p), .diff(let p): views[session]!.apply(p)
                case .noChange: break
                }
            }
        }
        await transport.clear()
    }

    func totalBytes() async -> Int { await transport.sent.reduce(0) { $0 + $1.data.count } }
}

/// Authoritative view a client should hold: broadcast fields + its per-player slice.
private func authoritativeView(_ keeper: LandKeeper<EquivState>, _ playerID: PlayerID) async throws -> [String: SnapshotValue] {
    let state = await keeper.currentState()
    return try SyncEngine().snapshot(for: playerID, from: state).values
}

@Test("delta and full-snapshot rebuild identical client views after every sync", arguments: [true, false])
func testStrategiesAreEquivalent(useSnapshotForSync: Bool) async throws {
    var delta = Harness(strategy: .delta, useSnapshotForSync: useSnapshotForSync, landID: "equiv-delta-\(useSnapshotForSync)")
    var full = Harness(strategy: .fullSnapshot, useSnapshotForSync: useSnapshotForSync, landID: "equiv-full-\(useSnapshotForSync)")
    await delta.start(); await full.start()

    // Script: same sequence applied to both harnesses.
    for n in 1...3 { try await delta.join(n); try await full.join(n) }
    try await delta.drain(); try await full.drain()

    func checkpoint(_ label: String) async throws {
        try await delta.drain(); try await full.drain()
        for (session, deltaView) in delta.views {
            let fullView = full.views[session]!
            #expect(deltaView == fullView, "[\(label)] view mismatch for \(session.rawValue)")
            let playerID = PlayerID("p" + session.rawValue.dropFirst())
            let auth = try await authoritativeView(delta.keeper, playerID)
            #expect(deltaView.root == auth, "[\(label)] delta view != authoritative for \(session.rawValue)")
        }
    }

    for round in 1...5 {
        try await delta.step(1, add: round);           try await full.step(1, add: round)
        try await delta.step(2, item: "item\(round)"); try await full.step(2, item: "item\(round)")
        await delta.adapter.syncNow();                 await full.adapter.syncNow()
        try await checkpoint("round \(round)")
    }

    // Idle sync: nothing changed.
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("idle")

    // Removal + leave + late join.
    try await delta.step(3, remove: 2); try await full.step(3, remove: 2)
    await delta.adapter.syncNow();      await full.adapter.syncNow()
    try await checkpoint("remove")

    await delta.leave(2); await full.leave(2)
    delta.views[SessionID("s2")] = nil; full.views[SessionID("s2")] = nil
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("leave")

    try await delta.join(4); try await full.join(4)
    try await delta.step(4, add: 42, item: "late"); try await full.step(4, add: 42, item: "late")
    await delta.adapter.syncNow(); await full.adapter.syncNow()
    try await checkpoint("late-join")

    // Sanity: delta never sends more than full over the whole script.
    // (Both transports were cleared at each drain, so compare cumulative counters instead.)
}
```

Then make the byte sanity check real: add to `Harness` a `var cumulativeBytes = 0` incremented inside `drain()` before `clear()` (`cumulativeBytes += await totalBytes()`), and at the end of the test:

```swift
    #expect(delta.cumulativeBytes <= full.cumulativeBytes,
            "delta sent \(delta.cumulativeBytes) B, full sent \(full.cumulativeBytes) B")
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter SyncStrategyEquivalenceTests`
Expected: 2 test cases PASS. If a view mismatch is reported, the label tells which phase; inspect the recorded patches for that session under each strategy before touching production code — a mismatch means one strategy dropped or mis-pathed a field.

- [ ] **Step 3: Commit**

```bash
git add Tests/SwiftStateTreeTransportTests/SyncStrategyEquivalenceTests.swift
git commit -m "Add delta vs full-snapshot client-view equivalence test"
```

---

### Task 5: Docs, full verification, PR

**Files:**
- Modify: `docs/transport/README.md:92-93`, `docs/transport/README.zh-TW.md:84-85`

- [ ] **Step 1: Document the env var (both languages, same commit)**

`docs/transport/README.md`, after the `USE_SNAPSHOT_FOR_SYNC` row:

```
| `SYNC_STRATEGY` | String | `delta` | `delta` sends changed fields only; `full-snapshot` sends each recipient's complete view every sync (measurement baseline, not a production mode) |
```

`docs/transport/README.zh-TW.md`, after the `USE_SNAPSHOT_FOR_SYNC` row:

```
| `SYNC_STRATEGY` | String | `delta` | `delta` 只送變更欄位；`full-snapshot` 每次同步送每個接收者的完整視圖（量測用基線，非正式模式） |
```

- [ ] **Step 2: Full verification**

```bash
swift build -c release 2>&1 | tail -3
swift test 2>&1 | tail -5
./Tools/CLI/test-e2e-game.sh 2>&1 | tail -5
```

Expected: release build succeeds; `swift test` reports all suites passed (was 790 tests / 46 suites on main before this branch; expect +11 tests); e2e exits 0 with all encodings passing.

Smoke run of the flag against a real server (manual, one command):

```bash
cd Examples/GameDemo && SYNC_STRATEGY=full-snapshot swift run -c release GameServer 2>&1 | grep -m1 "syncStrategy" ; cd ../..
```

Expected: the "Transport encoding configured" log line shows `syncStrategy=full-snapshot`. Stop the server (Ctrl-C / `./killport.sh 8080`).

- [ ] **Step 3: Commit docs**

```bash
git add docs/transport/README.md docs/transport/README.zh-TW.md
git commit -m "Document SYNC_STRATEGY transport env var"
```

- [ ] **Step 4: Open the PR**

```bash
git push -u origin feat/sync-strategy-full-snapshot
gh pr create --title "Add full-snapshot SyncStrategy as a measurement baseline" --body "$(cat <<'EOF'
## Summary
- `SyncStrategy` (`delta` | `fullSnapshot`) on `TransportAdapter`, configurable via init or `SYNC_STRATEGY`
- `SyncEngine.DiffBaseline` (`cached` | `empty`); `.cached` is byte-for-byte today's path
- Equivalence test: delta and full-snapshot rebuild identical client views after every sync, on both extraction paths
- Default behaviour unchanged (env unset + init default ⇒ identical bytes)

Design: `Notes/plans/specs/2026-09-15-snapshot-baseline-design.md`. Purpose: same-testbed baseline for the paper's RQ1 (delta vs per-sync full snapshot at equal encoding). Not a production mode.

## Verification
- `swift test`: <paste closing line>
- `./Tools/CLI/test-e2e-game.sh`: <paste closing line>
- `SYNC_STRATEGY=full-snapshot` GameServer smoke: log shows the strategy

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01LixpenKC5cZmfpmaYJS3xV
EOF
)"
```

Report the PR URL. Do not merge; the user merges after `sst-pr-review`.

---

### Task 6: `EncodingBenchmark --sync-strategy` (on `main`, after the PR merges)

**Files:**
- Modify: `Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkConfig.swift:69-80` (struct), `:118-121` (arg parsing), `:220-245` (help)
- Modify: `Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkResults.swift:40-50` (JSON), table printer
- Modify: `Examples/GameDemo/Sources/EncodingBenchmark/EncodingBenchmarkMain.swift` (apply strategy before any adapter is built)

**Interfaces:**
- Consumes: `SyncStrategy` (public, from `SwiftStateTreeTransport`), `SYNC_STRATEGY` env (Task 1).
- Produces: `--sync-strategy delta|full-snapshot`; result JSON key `"syncStrategy"`.

Rationale for using the env var instead of the init parameter: the benchmark constructs `TransportAdapter` in seven places (`BenchmarkExecution.swift:205,380,561,755,975`, `EncodingBenchmarkMain.swift:58,240`). Setting `SYNC_STRATEGY` once in the process before any adapter exists reaches all of them and is exactly what a user would do from the shell. This deviates from spec §5 ("construct with `syncStrategy:`"); update the spec's §5 wording in the same commit.

- [ ] **Step 1: Confirm scope (`sst-direct-change` step 1)**

```bash
git checkout main && git pull --ff-only && git status --short
```

Expected: clean, on `main`, PR from Task 5 already merged (`git log --oneline -1` shows the merge).

- [ ] **Step 2: Config and parsing**

`BenchmarkConfig`: add `var syncStrategy: SyncStrategy = .delta` and `import SwiftStateTreeTransport` at file top if missing. In the argument loop, next to `--format`:

```swift
        case "--sync-strategy":
            if i + 1 < args.count, let strategy = SyncStrategy(rawValue: args[i + 1].lowercased()) {
                config.syncStrategy = strategy
                i += 2
            } else {
                print("Error: --sync-strategy requires delta or full-snapshot")
                exit(1)
            }
```

Help text, after the `--format` line:

```
      --sync-strategy <s>     Sync strategy: delta (default) or full-snapshot (send full view every sync)
```

- [ ] **Step 3: Apply before any adapter is built**

In `EncodingBenchmarkMain.swift`, immediately after `let config = BenchmarkConfig.parse(...)` (or wherever the parsed config first exists, before any run function is called):

```swift
    // Reaches every TransportAdapter the benchmark constructs; same mechanism a shell user would use.
    setenv(SyncStrategy.environmentKey, config.syncStrategy.rawValue, 1)
```

(`SyncStrategy.environmentKey` is public and shipped in Task 1.)

- [ ] **Step 4: Results**

`BenchmarkResults.swift` JSON dictionary: add `"syncStrategy": config.syncStrategy.rawValue` (thread `config` or the strategy string into the result struct — add `let syncStrategy: String` to `BenchmarkResult` in `BenchmarkExecution.swift:128-140` and populate it at every `BenchmarkResult(` construction with `syncStrategy: config.syncStrategy.rawValue`). Table printer: append a `strategy` column.

- [ ] **Step 5: Verify**

```bash
cd Examples/GameDemo
swift run -c release EncodingBenchmark --format messagepack-pathhash --players-per-room-list 5 --room-counts 1 --iterations 20 --output json | grep -E '"syncStrategy"|"bytesPerSync"'
swift run -c release EncodingBenchmark --format messagepack-pathhash --players-per-room-list 5 --room-counts 1 --iterations 20 --output json --sync-strategy full-snapshot | grep -E '"syncStrategy"|"bytesPerSync"'
cd ../.. && ./Tools/CLI/test-e2e-game.sh 2>&1 | tail -3
```

Expected: first run prints `"syncStrategy": "delta"`; second prints `"syncStrategy": "full-snapshot"` with a strictly larger `bytesPerSync`; e2e exit 0.

- [ ] **Step 6: Commit and push on `main`**

```bash
git add Examples/GameDemo/Sources/EncodingBenchmark Notes/plans/specs/2026-09-15-snapshot-baseline-design.md
git commit -m "Add --sync-strategy to EncodingBenchmark"
git push
```

Next step after this task: run the experiment as a design run under `sst-experiment` (spec §6); that is a separate session and a separate PR.

---

## Self-review notes

- Spec §4.1–4.4 → Tasks 1–3; §4.5 → Task 4; §5 → Task 6 (env-var mechanism, deviation recorded); §6 experiment → out of this plan by design (spec §7 step 3); §7 delivery order preserved; §8 risk "both extraction paths" → Tasks 3 and 4 are parametrised over `useSnapshotForSync`.
- `SyncStrategy.environmentKey` ships in Task 1 (public) so Task 6 can `setenv` it without touching the internal `TransportEnvKeys`.
- Type names used consistently: `SyncStrategy.delta/.fullSnapshot`, `SyncEngine.DiffBaseline.cached/.empty`, `TransportAdapter.init(syncStrategy:transportEnvConfig:)`, `TransportEnvConfig.syncStrategy`, `SessionRecordingTransport`, `decodeStateUpdates(_:)`.
