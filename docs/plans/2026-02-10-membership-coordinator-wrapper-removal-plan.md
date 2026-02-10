# MembershipCoordinator Wrapper Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove `TransportAdapter` transitional `sessionTo*` wrappers entirely and route all membership reads/writes through `MembershipCoordinator` APIs without behavior regressions.

**Architecture:** Keep `TransportAdapter` as orchestrator and make `MembershipCoordinator` the single source of truth for session/player/client/auth mappings, membership stamps, and player-slot lookups. Replace dictionary-style reads with explicit query APIs and add iterator-friendly helpers for sync hot paths. Keep public `TransportAdapter` API unchanged and avoid extra actor hops.

**Tech Stack:** Swift 6, Swift Testing (`@Test`, `#expect`), `swift build`, `swift test`, CLI E2E (`Tools/CLI/test-e2e-ci.sh`).

### Task 1: Add regression tests before refactor

**Files:**
- Modify: `Tests/SwiftStateTreeTransportTests/TransportAdapterMembershipTests.swift`
- Modify: `Tests/SwiftStateTreeTransportTests/TransportAdapterStateManagementTests.swift`
- Test: `Tests/SwiftStateTreeTransportTests/TransportAdapterMembershipTests.swift`

**Step 1: Write failing test for duplicate login + leave ordering safety**

Add a test that performs: connect/join A -> queue targeted event -> duplicate login B with same playerID -> sync. Assert stale targeted event is not delivered and old session is disconnected.

```swift
@Test("Duplicate login invalidates old session targeted events")
func testDuplicateLoginInvalidatesOldSessionTargetedEvents() async throws {
    // Arrange two sessions using same playerID
    // Act: queue targeted event before second join, then sync
    // Assert: stale event is dropped, only active session gets current updates
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter TransportAdapterMembershipTests/testDuplicateLoginInvalidatesOldSessionTargetedEvents`

Expected: FAIL (current assertions not satisfied until full refactor is done).

**Step 3: Write failing test for state query methods after reconnect**

Add a focused test in `TransportAdapterStateManagementTests.swift` that validates:
- `isConnected(sessionID:)`
- `isJoined(sessionID:)`
- `getPlayerID(for:)`
- `getSessions(for:)`

across connect -> join -> disconnect -> reconnect.

**Step 4: Run test to verify it fails**

Run: `swift test --filter TransportAdapterStateManagementTests`

Expected: At least one new test fails before implementation.

**Step 5: Commit**

```bash
git add Tests/SwiftStateTreeTransportTests/TransportAdapterMembershipTests.swift Tests/SwiftStateTreeTransportTests/TransportAdapterStateManagementTests.swift
git commit -m "test(transport): add membership regression coverage for wrapper removal"
```

### Task 2: Extend MembershipCoordinator API for wrapper-free read paths

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/MembershipCoordinator.swift`
- Test: `Tests/SwiftStateTreeTransportTests/TransportAdapterMembershipTests.swift`

**Step 1: Add iterator/query helpers replacing dictionary-style usage**

Add minimal helpers needed by sync/join/event paths:

```swift
func allJoinedEntries() -> [(sessionID: SessionID, playerID: PlayerID)]
func joinedPlayerIDs() -> [PlayerID]
func joinedCount() -> Int
func firstJoined(where predicate: (SessionID, PlayerID) -> Bool) -> (SessionID, PlayerID)?
```

Keep implementation simple (derived from internal maps); do not expose snapshots.

**Step 2: Add helper for duplicate-login lookup efficiency**

If needed, add:

```swift
func firstSession(for playerID: PlayerID) -> SessionID?
```

**Step 3: Run focused tests**

Run: `swift test --filter TransportAdapterMembershipTests`

Expected: PASS (or unchanged failures only from Task 1 expectations).

**Step 4: Commit**

```bash
git add Sources/SwiftStateTreeTransport/MembershipCoordinator.swift
git commit -m "refactor(transport): add membership query helpers for wrapper-free access"
```

### Task 3: Remove TransportAdapter transitional wrappers and migrate call sites

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter+Membership.swift`
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter+Sync.swift`
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter+MessageHandling.swift`

**Step 1: Remove transitional wrapper properties/functions**

Delete these from `TransportAdapter.swift`:
- `sessionToPlayer`, `sessionToClient`, `sessionToAuthInfo`
- `connectedSessions`, `joinedSessions`
- pass-through wrappers for `currentMembershipStamp`, `isSessionCurrent`, `isPlayerCurrent`, `sessionID(for:)`

**Step 2: Replace all `sessionTo*` reads with coordinator APIs**

Examples:

```swift
// before
if sessionToPlayer[sessionID] != nil { ... }

// after
if membershipCoordinator.hasPlayer(sessionID: sessionID) { ... }
```

```swift
// before
for (sessionID, playerID) in sessionToPlayer { ... }

// after
for (sessionID, playerID) in membershipCoordinator.allJoinedEntries() { ... }
```

**Step 3: Update join/state query helpers**

Use:
- `membershipCoordinator.clientID(for:)`
- `membershipCoordinator.authInfo(for:)`
- `membershipCoordinator.sessionIDs(for:)`
- `membershipCoordinator.hasClient(sessionID:)`
- `membershipCoordinator.hasPlayer(sessionID:)`

**Step 4: Run build**

Run: `swift build`

Expected: PASS.

**Step 5: Run targeted tests**

Run: `swift test --filter TransportAdapter`

Expected: PASS (92 tests).

**Step 6: Commit**

```bash
git add Sources/SwiftStateTreeTransport/TransportAdapter.swift Sources/SwiftStateTreeTransport/TransportAdapter+Membership.swift Sources/SwiftStateTreeTransport/TransportAdapter+Sync.swift Sources/SwiftStateTreeTransport/TransportAdapter+MessageHandling.swift
git commit -m "refactor(transport): remove session wrapper reads in TransportAdapter"
```

### Task 4: Decompose large sync/join flows with shared helpers

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter.swift`
- Modify: `Sources/SwiftStateTreeTransport/TransportAdapter+Sync.swift`

**Step 1: Extract sync lock template**

Create private helper:

```swift
private func withSyncState(_ body: (State) async throws -> Void) async
```

It should encapsulate `keeper.beginSync()` / `keeper.endSync(clearDirtyFlags:)` and shared error handling.

**Step 2: Extract `_syncNowImpl` subroutines**

Split into 2-5 minute pieces:
- snapshot-mode computation
- snapshot extraction
- broadcast update send path
- per-player diff/update pipeline
- pending event-body flush

**Step 3: Extract join flow subroutines**

From `handleJoinRequest`, extract:
- precondition validation
- session preparation
- duplicate-login handling
- join response + initial sync path

Keep logic/ordering unchanged.

**Step 4: Run tests**

Run:
- `swift test --filter TransportAdapterMembershipTests`
- `swift test --filter TransportAdapterSyncConcurrencyTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/TransportAdapter.swift Sources/SwiftStateTreeTransport/TransportAdapter+Sync.swift
git commit -m "refactor(transport): split sync and join flows into smaller units"
```

### Task 5: Full verification and integration safety

**Files:**
- Verify only (no new code unless failures found)

**Step 1: Run full Swift tests**

Run: `swift test`

Expected: PASS (all suites).

**Step 2: Run CLI E2E matrix**

Run: `cd Tools/CLI && ./test-e2e-ci.sh`

Expected: PASS in `jsonObject`, `opcodeJsonArray`, `messagepack`.

**Step 3: Check git status and scope**

Run: `git status --short`

Expected: only transport-related files (plus any pre-existing unrelated user changes).

**Step 4: Final commit (if needed)**

```bash
git add Sources/SwiftStateTreeTransport/ Tests/SwiftStateTreeTransportTests/
git commit -m "refactor(transport): finalize membership-coordinator-only access paths"
```

**Step 5: Prepare PR notes**

Document:
- transitional wrappers removed
- membership source of truth consolidated
- no public API changes
- tests and E2E evidence
