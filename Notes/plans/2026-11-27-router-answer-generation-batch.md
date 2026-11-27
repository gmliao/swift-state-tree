# One PR for #941, #945 and #947: the router's and the adapter's answers to a connection they decided about

Revision 0 (2026-11-27). This is the job text for a cloud worker. It is one small PR with one commit per issue, each test-first.

**Start after #940 merges:** #947 uses the `close:` parameter that #940 adds to `sendFinalFrameAndClose`, and the line numbers below are at #940's head 7b2dda84 (`LR` is `Sources/SwiftStateTreeTransport/LandRouter.swift`, `TA` is `TransportAdapter.swift`). Re-find each site by its text, not by the number.

The rule behind all three is "never remove or overwrite keyed state by key alone from a callback that can outlive its instance" (CLAUDE.md, Reentrancy). A frame, close or undo for a connection carries the generation read in the segment that decided about that connection. The lessons are `2026-11-05-callback-outlives-its-instance-clears-by-key` and `2026-11-27-a-new-terminal-answer-goes-through-every-path-that-can-answer`. The second lands with #940, so it isn't on main until #940 merges.

## 1. #941: the flip-stage JOIN_DENIED carries the connection's generation

**Edit:**
- In the flip-failure switch (LR:1468 `case .superseded:` and LR:1472 `case .landClosed:`), pass the `connectionGeneration` read at LR:1444 into `sendJoinError`.
- `sendJoinError` (LR:1723) gains `generation: UInt64? = nil` and hands it to `deliver` (LR:1805).
- `deliver` gains the same parameter and uses it in its transport branch, `SessionFrame(..., connectionGeneration: generation, ...)` (LR:1819).
- Callers that don't pass a generation keep `nil` (today's behavior).
- After `endAttempt`, the session is back in the handshake, so the frame takes the transport branch. Pin that in the test.

**Test:** add it to the suite "LandRouter: a failed join's final frame carries its connection (#911)" (`LandRouterJoinAttemptTests.swift:580`), whose harness already reconnects a session under the same ID.
1. Fail a routed in-turn join at its flip with `.superseded` (a direct keeper join of the same player while the flip waits; see `RoutedJoinSupersededTests`).
2. Hold at `.flipFailed` (`holds.on(.flipFailed, arrival: 1)`). The hold is after the generation is read and `endAttempt` runs, before the switch.
3. While it is held, reconnect the session ID (a new connection generation).
4. Release.
- **Expected:** the new connection's raw log has no JOIN_DENIED, and the old connection's has it.
- **Failing first:** before the fix, the error is sent with `connectionGeneration: nil` and reaches the new connection.
- **Second row:** the same test with `.landClosed` (the land drains while the flip waits).

## 2. #945: the stale-attempt undo at `.afterAdmit` names its connection

**Edit:** at LR:1114, replace `adapter.onDisconnect(sessionID: sessionID, clientID: clientID)` with the generation-aware overload. Pass the `connectionGeneration` captured at LR:1047, as the flip path does at LR:1494.

The adapter's `handleDisconnectQueued` already returns early when the generation isn't current (TA, `if let generation, let current = connectionGenerations[sessionID], current != generation { return }`).

**Test:** in `LandRouterJoinAttemptTests`, next to the `.afterAdmit` cases (`h.holdCounting(at: .afterAdmit)`, :437).
1. A routed join of session S is held at `.afterAdmit`.
2. Disconnect S, so the attempt is stale.
3. Reconnect S under a new generation, and complete a second join of S (the first is still held, so let only arrival 1 hold).
4. Release the first attempt.
- **Expected:** the second join's admission survives. The adapter still has S as a member of its player, and a later action from S is applied.
- **Failing first:** before the fix, the undo removes the new connection's membership.

## 3. #947: the standalone legacy join answers `.superseded` with the 4017 close

**Edit:** in `TransportAdapter.finalizeJoinRequest` (TA:5982), the `catch` maps every error through `sendJoinError` (TA:6078), which sends the error frame and leaves the connection open.
- For `JoinError.superseded`, send the JOIN_DENIED frame as the final frame and close with 4017: `sendFinalFrameAndClose(errorData, kind:, to: sessionID, generation: connectionGeneration, close: .superseded)`.
- The generation is `connectionGenerations[sessionID]`, read at the top of `finalizeJoinRequest`, before `performJoin`'s await.
- Factor the error frame's encoding out of `sendJoinError` so that both use it.
- Other errors are unchanged.

**Test:** a new case beside `RoutedJoinSupersededTests`, in the standalone adapter's join tests. Hosted joins of one player are serialized by the adapter's membership queue, so a direct keeper join makes the newer join, as `RoutedJoinSupersededTests` explains.

Two stages, one row each:
- **Pending OnJoin:** hold the adapter's join in its OnJoin resolver (a gate keyed by session), then make a direct keeper join of the same player.
- **The kick's fence (#940's J2c):**
  1. A is joined directly, and its OnLeave resolver is held.
  2. The adapter's join kicks A.
  3. A direct join arrives later.
  4. Release A's OnLeave resolver.
- **Expected in both rows:** the adapter session's raw log is exactly `[error JOIN_DENIED "Join superseded by a newer join of the player", close 4017]`, and nothing follows it.
- **Failing first:** before the fix, the log is `[error JOIN_DENIED]`, and no close is sent.

## Verification

- On the build host:
  - `swift build --build-tests`;
  - `swift test --filter "LandRouterJoinAttemptTests|RoutedJoinSupersededTests|SupersedeCloseOrderTests|TransportAdapter"`;
  - the full `swift test`.
- Each commit's test fails first without its edit. Quote the failing line.
- `bash scripts/pre-push-checks.sh origin/main`.
- Mutants, one per edit, for the PR body: put `nil` back at each site; each new test must fail.
- The PR closes only the issues it fixes: "Closes #941", "Closes #945", and "Closes #947" only once the #947 commit is in the PR. If #947 lands in a later PR, this one says "#947 stays open".

## Probes

None run. Each edit threads a value that is already read at the site into an existing parameter, or swaps in an existing overload (`onDisconnect(…, generation:)`, `sendFinalFrameAndClose(…, close:)`). The behavior each one changes is pinned by its failing-first test, which is the evidence.
