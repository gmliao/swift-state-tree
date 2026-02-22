# Generic Replay Land Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `HeroDefenseReplayLand.swift` with a framework-provided `GenericReplayLand` so that developers no longer need to write game-specific replay land boilerplate.

**Architecture:** Add `GenericReplayLand.makeLand(landType:stateType:)` to `SwiftStateTreeReevaluationMonitor` that auto-decodes projected state via `JSONDecoder` and forwards all server events. Provide `StandardReplayLifetime` / `StandardReplayServerEvents` free functions for developers who need custom actions. Update `registerWithReevaluationSameLand` to use `GenericReplayLand` instead of re-using `liveLand`. Delete `HeroDefenseReplayLand.swift`.

**Tech Stack:** Swift 6, SwiftStateTree DSL (`LandNode`, `LifetimeNode`, `ServerEventsNode`), `JSONDecoder`, `ReevaluationRunnerService`, `ReevaluationReplaySessionDescriptor`

---

## Key Architecture Notes (read before implementing)

### How the current same-land replay works
`registerWithReevaluationSameLand` currently registers the same `liveLand` `LandDefinition` for BOTH the live game and the replay. For the replay instance, `injectingReevaluationKeeperModeResolver` makes `LandKeeper` run in reevaluation mode (replaying from record file).

### How GenericReplayLand works (new approach)
`GenericReplayLand` is a DIFFERENT approach: `LandKeeper` runs in **normal mode**. A `Tick` loop inside the land polls `ReevaluationRunnerService` which runs verification in a background Task. When results arrive, the Tick decodes the state from `result.actualState` (full state JSON string) using `JSONDecoder` and forwards all server events from `result.emittedServerEvents`.

**Consequence:** `injectingReevaluationKeeperModeResolver` is NOT needed for `GenericReplayLand`. Remove it from the replay land config path in `registerWithReevaluationSameLand`.

### State JSON format
`result.actualState?.base` is a `String` containing the full state as JSON. It may have a `{"values": {...}}` wrapper (SwiftStateTree serialization artifact). The decode helper must handle both formats.

### Event forwarding
Use `result.emittedServerEvents` (type `[ReevaluationRecordedServerEvent]`) directly — each has `.typeIdentifier: String` and `.payload: AnyCodable`. Construct `AnyServerEvent(type: event.typeIdentifier, payload: event.payload)` and call `ctx.emitAnyServerEvent(event, to: .all)`.

### StandardReplayBehavior as DSL nodes
`LandBuilder.ingest` handles known `LandNode` subtypes. `LifetimeNode<State>` and `ServerEventsNode` are already handled. We provide two free functions:
- `StandardReplayLifetime<State>(landType:)` → `LifetimeNode<State>`
- `StandardReplayServerEvents()` → `ServerEventsNode`

These return existing types that `LandBuilder` already knows how to process. No changes to `LandBuilder` needed.

### Path resolution
`ctx.landID` is a `String` in format `"landType:instanceId"`. Parse with `LandID(ctx.landID).instanceId`, then call `ReevaluationReplaySessionDescriptor.decode(instanceId:landType:recordsDir:)` where `landType` is the **base** land type (e.g., `"hero-defense"`), not the replay type.

---

## Task 1: Add `ReplayTickEvent` and state decode helper

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift`

**Step 1: Write the failing test**

Add to `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift` (before the closing `}`):

```swift
@Test("ReplayTickEvent has correct fields")
func replayTickEventHasCorrectFields() {
    let event = ReplayTickEvent(
        tickId: 42,
        isMatch: true,
        expectedHash: "abc",
        actualHash: "abc"
    )
    #expect(event.tickId == 42)
    #expect(event.isMatch == true)
    #expect(event.expectedHash == "abc")
    #expect(event.actualHash == "abc")
}
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/guanmingliao/Documents/GitHub/swift-state-tree
swift test --filter "ReevaluationFeatureRegistrationTests/replayTickEventHasCorrectFields"
```
Expected: FAIL — `ReplayTickEvent` not found.

**Step 3: Create `GenericReplayLand.swift` with `ReplayTickEvent` and decode helper**

```swift
import Foundation
import SwiftStateTree

// MARK: - ReplayTickEvent

/// Generic replay tick result event emitted by GenericReplayLand on each processed tick.
/// Replaces game-specific tick events (e.g. HeroDefenseReplayTickEvent).
@Payload
public struct ReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

// MARK: - Internal state decode helper

/// Decodes a State from `result.actualState`.
///
/// `actualState?.base` is a JSON string. It may be a flat JSON object or wrapped in
/// `{"values": {...}}` (SwiftStateTree serialization artifact). Both formats are tried.
func decodeReplayState<State: Decodable>(_ type: State.Type, from actualState: AnyCodable?) -> State? {
    guard let jsonText = actualState?.base as? String,
          let data = jsonText.data(using: .utf8)
    else { return nil }

    // Try direct decode first (flat format)
    if let decoded = try? JSONDecoder().decode(type, from: data) {
        return decoded
    }

    // Try "values" wrapper format: {"values": {...}}
    guard let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let valuesRaw = rawJSON["values"],
          JSONSerialization.isValidJSONObject(valuesRaw),
          let valuesData = try? JSONSerialization.data(withJSONObject: valuesRaw),
          let decoded = try? JSONDecoder().decode(type, from: valuesData)
    else { return nil }

    return decoded
}
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests/replayTickEventHasCorrectFields"
```
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift
git add Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "feat: add ReplayTickEvent and state decode helper for GenericReplayLand"
```

---

## Task 2: Implement `GenericReplayLand.makeLand`

**Files:**
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift`

**Step 1: Write the failing test**

Add to `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`:

```swift
@Test("GenericReplayLand.makeLand produces a LandDefinition with the correct land ID")
func genericReplayLandMakeLandProducesValidDefinition() {
    let definition = GenericReplayLand.makeLand(
        landType: "hero-defense",
        stateType: FeatureLiveState.self
    )
    #expect(definition.id == "hero-defense-replay")
}
```

Note: `FeatureLiveState` is already defined in the test file. It must conform to `Decodable` — add `Decodable` to its conformance if it doesn't already have it via `@StateNodeBuilder` (check: `@StateNodeBuilder` generates `Codable` automatically, so this is already true).

**Step 2: Run test to verify it fails**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests/genericReplayLandMakeLandProducesValidDefinition"
```
Expected: FAIL — `GenericReplayLand` not found.

**Step 3: Add `GenericReplayLand` to `GenericReplayLand.swift`**

Append to the file:

```swift
// MARK: - GenericReplayLand

/// Zero-config generic replay land for any State conforming to StateNodeProtocol & Decodable.
///
/// Replaces hand-written game-specific replay lands (e.g. HeroDefenseReplayLand).
/// - Starts reevaluation verification automatically on first tick.
/// - Decodes projected state from `result.actualState` using JSONDecoder.
/// - Forwards ALL recorded server events without filtering.
/// - Emits ReplayTickEvent after each result.
///
/// For custom actions (fast-forward, reset, etc.), use
/// `StandardReplayLifetime` and `StandardReplayServerEvents` instead.
public enum GenericReplayLand {
    /// Creates a generic replay LandDefinition.
    ///
    /// - Parameters:
    ///   - landType: The BASE land type (e.g. "hero-defense"), NOT the replay suffix.
    ///     Used as the land ID suffix and passed to `startVerification(landType:)`.
    ///   - stateType: The State type. Must conform to StateNodeProtocol & Decodable.
    /// - Returns: A LandDefinition whose ID is "\(landType)-replay".
    public static func makeLand<State: StateNodeProtocol & Decodable>(
        landType: String,
        stateType: State.Type
    ) -> LandDefinition<State> {
        Land("\(landType)-replay", using: stateType) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(64)
            }

            StandardReplayLifetime(landType: landType)

            ServerEvents {
                Register(ReplayTickEvent.self)
            }
        }
    }
}
```

Note: `StandardReplayLifetime` will be implemented in Task 3. For now, add a placeholder:

```swift
// Temporary placeholder — will be replaced in Task 3
internal func StandardReplayLifetime<State: StateNodeProtocol & Decodable>(
    landType: String
) -> LifetimeNode<State> {
    Lifetime { _ in }
}
```

**Step 4: Run test to verify it passes**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests/genericReplayLandMakeLandProducesValidDefinition"
```
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift
git add Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "feat: add GenericReplayLand.makeLand scaffold"
```

---

## Task 3: Implement `StandardReplayLifetime` and `StandardReplayServerEvents`

**Files:**
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift`

This is the core replay tick logic. Replace the placeholder `StandardReplayLifetime` with the real implementation.

**Step 1: Read the existing `HeroDefenseReplayLand.swift` tick logic**

File: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift` (lines 30–70)
The Tick logic is the reference implementation. `StandardReplayLifetime` generalizes it.

**Step 2: Write the failing test**

Add to `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`:

```swift
@Test("StandardReplayLifetime returns a LifetimeNode")
func standardReplayLifetimeReturnsLifetimeNode() {
    let node: LifetimeNode<FeatureLiveState> = StandardReplayLifetime(landType: "test")
    // Just verify it compiles and produces a non-nil configure closure
    var config = LifetimeConfig<FeatureLiveState>()
    node.configure(&config)
    #expect(config.tickInterval != nil)
}
```

Note: `LifetimeConfig` is in `SwiftStateTree`. If it's not public, adjust the test to just verify the node is a `LandNode`.

Simpler fallback test (if `LifetimeConfig` is not accessible in tests):
```swift
@Test("StandardReplayLifetime is a LandNode")
func standardReplayLifetimeIsLandNode() {
    let node: any LandNode = StandardReplayLifetime<FeatureLiveState>(landType: "test")
    #expect(node is LifetimeNode<FeatureLiveState>)
}

@Test("StandardReplayServerEvents is a LandNode")
func standardReplayServerEventsIsLandNode() {
    let node: any LandNode = StandardReplayServerEvents()
    #expect(node is ServerEventsNode)
}
```

**Step 3: Run test to verify it fails**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests/standardReplayLifetimeIsLandNode"
```
Expected: FAIL

**Step 4: Replace placeholder with real `StandardReplayLifetime` implementation**

In `GenericReplayLand.swift`, replace the placeholder:

```swift
// MARK: - StandardReplayLifetime / StandardReplayServerEvents
//
// Use these to compose a custom replay land when you need extra Actions:
//
//   Land("my-game-replay", using: MyGameState.self) {
//       AccessControl { AllowPublic(true); MaxPlayers(64) }
//       StandardReplayLifetime<MyGameState>(landType: "my-game")
//       StandardReplayServerEvents()
//       Rules {
//           HandleAction(FastForwardAction.self) { state, ctx, action in
//               ctx.services.get(ReevaluationRunnerService.self)?.setSpeed(...)
//           }
//       }
//       ServerEvents { Register(FastForwardEvent.self) }
//   }

/// Returns a LifetimeNode that drives the standard replay tick loop.
///
/// On each tick (every 50ms):
/// - If service is idle: resolves record path from ctx.landID and calls startVerification.
/// - If result available: decodes full state via JSONDecoder, forwards all server events,
///   emits ReplayTickEvent, and requests immediate sync broadcast.
public func StandardReplayLifetime<State: StateNodeProtocol & Decodable>(
    landType: String
) -> LifetimeNode<State> {
    let captureLandType = landType
    return Lifetime {
        Tick(every: .milliseconds(50)) { (state: inout State, ctx: LandContext) in
            guard let service = ctx.services.get(ReevaluationRunnerService.self) else {
                return
            }

            let status = service.getStatus()

            if status.phase == .idle {
                let instanceId = LandID(ctx.landID).instanceId
                let recordsDir = ReevaluationEnvConfig.fromEnvironment().recordsDir
                guard let descriptor = ReevaluationReplaySessionDescriptor.decode(
                    instanceId: instanceId,
                    landType: captureLandType,
                    recordsDir: recordsDir
                ) else {
                    service.startVerification(
                        landType: captureLandType,
                        recordFilePath: "__invalid_replay_record_path__"
                    )
                    return
                }
                service.startVerification(
                    landType: captureLandType,
                    recordFilePath: descriptor.recordFilePath
                )
                return
            }

            guard let result = service.consumeNextResult() else { return }

            if let decoded = decodeReplayState(State.self, from: result.actualState) {
                state = decoded
                ctx.requestSyncBroadcastOnly()
            }

            for event in result.emittedServerEvents {
                ctx.emitAnyServerEvent(
                    AnyServerEvent(type: event.typeIdentifier, payload: event.payload),
                    to: .all
                )
            }

            ctx.emitEvent(
                ReplayTickEvent(
                    tickId: result.tickId,
                    isMatch: result.isMatch,
                    expectedHash: result.recordedHash ?? "?",
                    actualHash: result.stateHash
                ),
                to: .all
            )
        }
    }
}

/// Returns a ServerEventsNode that registers ReplayTickEvent.
/// Include alongside StandardReplayLifetime when building a custom replay land.
public func StandardReplayServerEvents() -> ServerEventsNode {
    ServerEvents {
        Register(ReplayTickEvent.self)
    }
}
```

**Step 5: Run tests to verify they pass**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests"
```
Expected: All pass including the two new tests.

**Step 6: Verify build succeeds**

```bash
swift build
```
Expected: No errors.

**Step 7: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift
git add Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "feat: implement StandardReplayLifetime and StandardReplayServerEvents"
```

---

## Task 4: Update `registerWithReevaluationSameLand`

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`

**Step 1: Write the failing test**

The existing test `replayRegisteredWithoutDedicatedReplayLand` verifies that `registerWithReevaluationSameLand` registers live, replay, and monitor lands. After this change it should still pass, but the replay land's `LandDefinition.id` should be the generic replay land's ID.

Add a new test:

```swift
@Test("registerWithReevaluationSameLand uses GenericReplayLand (not liveLand) for replay")
func registerWithReevaluationSameLandUsesGenericReplayLand() async throws {
    let host = NIOLandHost(configuration: NIOLandHostConfiguration(
        host: "localhost",
        port: 8080,
        adminAPIKey: "test-admin-key"
    ))

    let feature = ReevaluationFeatureConfiguration(
        enabled: true,
        runnerServiceFactory: {
            ReevaluationRunnerService(factory: MockReevaluationTargetFactory())
        }
    )

    try await host.registerWithReevaluationSameLand(
        landType: "feature-live",
        liveLand: FeatureLiveLand.makeLand(),
        liveInitialState: FeatureLiveState(),
        liveWebSocketPath: "/game/feature-live",
        configuration: NIOLandServerConfiguration(transportEncoding: .json),
        reevaluation: feature
    )

    let realm = await host.realm
    #expect(await realm.isRegistered(landType: "feature-live"))
    #expect(await realm.isRegistered(landType: "feature-live-replay"))
    #expect(await realm.isRegistered(landType: "reevaluation-monitor"))
}
```

Run this — it should already PASS (since we're testing registration, not land internals). Keep it as a regression guard.

**Step 2: Modify `registerWithReevaluationSameLand`**

In `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`, change the function signature and replay registration:

```swift
// BEFORE:
func registerWithReevaluationSameLand<State: StateNodeProtocol>(

// AFTER:
func registerWithReevaluationSameLand<State: StateNodeProtocol & Decodable>(
```

Then change the replay land registration block (lines ~76–94). Replace:

```swift
let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(replayLandType)
let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir

var replayConfig = effectiveConfiguration.injectingReevaluationKeeperModeResolver(
    replayLandType: replayLandType,
    recordsDir: recordsDir
)
replayConfig.replayLandSuffix = reevaluation.replayLandSuffix

replayLandSuffix = reevaluation.replayLandSuffix

try await register(
    landType: replayLandType,
    land: liveLand,
    initialState: liveInitialState(),
    webSocketPath: replayWebSocketPath,
    configuration: replayConfig
)
```

With:

```swift
let replayLandType = "\(landType)\(reevaluation.replayLandSuffix)"
let replayWebSocketPath = reevaluation.replayWebSocketPathResolver(replayLandType)

var replayConfig = effectiveConfiguration
replayConfig.replayLandSuffix = reevaluation.replayLandSuffix

replayLandSuffix = reevaluation.replayLandSuffix

try await register(
    landType: replayLandType,
    land: GenericReplayLand.makeLand(landType: landType, stateType: State.self),
    initialState: liveInitialState(),
    webSocketPath: replayWebSocketPath,
    configuration: replayConfig
)
```

Key changes:
1. Removed `injectingReevaluationKeeperModeResolver` (not needed: GenericReplayLand handles path resolution via Tick)
2. Removed `recordsDir` / `NIOEnvConfig` lookup (no longer needed here)
3. Changed `land: liveLand` → `land: GenericReplayLand.makeLand(landType: landType, stateType: State.self)`
4. Added `& Decodable` to State constraint

**Step 3: Run build to check for constraint failures**

```bash
swift build
```

If `HeroDefenseState` already conforms to `Decodable` (it should via `@StateNodeBuilder`), this compiles cleanly. If not, you'll see a constraint error in `GameServer/main.swift` — resolve by checking `HeroDefenseState`'s conformances.

**Step 4: Run registration tests**

```bash
swift test --filter "ReevaluationFeatureRegistrationTests"
```
Expected: All pass.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeNIO/ReevaluationFeature.swift
git add Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "feat: use GenericReplayLand in registerWithReevaluationSameLand"
```

---

## Task 5: Delete `HeroDefenseReplayLand.swift` and clean up

**Files:**
- Delete: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Check: anything referencing `HeroDefenseReplayTickEvent` or `HeroDefenseReplay`

**Step 1: Search for usages**

```bash
grep -r "HeroDefenseReplay\|HeroDefenseReplayTickEvent" \
    /Users/guanmingliao/Documents/GitHub/swift-state-tree \
    --include="*.swift" -l
```

Expected: Only `HeroDefenseReplayLand.swift` itself. If other files appear, address them first.

**Step 2: Delete the file**

```bash
rm Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift
```

**Step 3: Build to confirm no orphaned references**

```bash
swift build
```
Expected: No errors. If any "use of unresolved identifier" errors appear for `HeroDefenseReplayTickEvent`, find the file and remove or replace the reference with `ReplayTickEvent`.

**Step 4: Run full test suite**

```bash
swift test
```
Expected: All tests pass.

**Step 5: Commit**

```bash
git add -u
git commit -m "feat: delete HeroDefenseReplayLand — replaced by GenericReplayLand"
```

---

## Task 6: Update schema in `GameServer/main.swift`

`GenericReplayLand.makeLand()` registers `ReplayTickEvent` instead of the old `HeroDefenseReplayTickEvent`. Update the server's schema generation to include the generic replay land definition.

**Files:**
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`

**Step 1: Find schema generation code (around line 73–81)**

Current:
```swift
var schemaLandDefinitions: [AnyLandDefinition] = [AnyLandDefinition(landDef)]
if enableReevaluation {
    schemaLandDefinitions.append(AnyLandDefinition(ReevaluationMonitor.makeLand()))
}
let schema = SchemaGenCLI.generateSchema(
    landDefinitions: schemaLandDefinitions,
    replayLandTypes: enableReevaluation ? ["hero-defense"] : nil
)
```

**Step 2: Add GenericReplayLand to schema definitions**

```swift
var schemaLandDefinitions: [AnyLandDefinition] = [AnyLandDefinition(landDef)]
if enableReevaluation {
    schemaLandDefinitions.append(AnyLandDefinition(ReevaluationMonitor.makeLand()))
    schemaLandDefinitions.append(
        AnyLandDefinition(GenericReplayLand.makeLand(landType: "hero-defense", stateType: HeroDefenseState.self))
    )
}
let schema = SchemaGenCLI.generateSchema(
    landDefinitions: schemaLandDefinitions,
    replayLandTypes: nil  // GenericReplayLand is already in schemaLandDefinitions
)
```

Note: If `replayLandTypes: nil` causes issues with schema generation (e.g. missing replay alias), revert to `replayLandTypes: enableReevaluation ? ["hero-defense"] : nil` and keep both in schemaLandDefinitions.

**Step 3: Build and verify**

```bash
swift build
```
Expected: No errors.

**Step 4: Commit**

```bash
git add Examples/GameDemo/Sources/GameServer/main.swift
git commit -m "feat: update schema gen to use GenericReplayLand for hero-defense replay"
```

---

## Task 7: Final verification

**Step 1: Run full test suite**

```bash
swift test
```
Expected: All tests pass, no regressions.

**Step 2: Release build (catches Swift 6 concurrency issues)**

```bash
swift build -c release
```
Expected: No errors or warnings.

**Step 3: Verify `HeroDefenseReplayLand.swift` is gone**

```bash
ls Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift 2>&1
```
Expected: `No such file or directory`

**Step 4: Verify `GenericReplayLand.swift` exists with correct types**

```bash
grep -n "ReplayTickEvent\|GenericReplayLand\|StandardReplayLifetime\|StandardReplayServerEvents" \
    Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift
```

**Step 5: Final commit if any cleanup needed, then summarize**

```bash
git log --oneline feature/generic-replay-land ^main
```

---

## Summary of file changes

| Action | File |
|--------|------|
| Create | `Sources/SwiftStateTreeReevaluationMonitor/GenericReplayLand.swift` |
| Modify | `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` |
| Modify | `Examples/GameDemo/Sources/GameServer/main.swift` |
| Delete | `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift` |
| Modify (tests) | `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift` |
