# Report: 827-followups-a

**Branch:** `fix/827-followups-close-ping`  
**PR:** https://github.com/gmliao/swift-state-tree/pull/841  
**Base:** `1d1bdae9` (origin/main at job start; main had moved from `06da2283`)

## Commits

| Commit | Item | Summary |
|--------|------|---------|
| `10e74d48` | F5 | Pin failure-path disconnect before trailing frames in `expectFailure` |
| `f9029bbc` | F1 | Route `handleClose` validation through `failConnection`; test `closeCause` |
| `f9654049` | F3 | Answer pings in the close grace (RFC 6455 §5.5.2) |
| `13bbc6db` | F4 | Update solutions note: `handleClose` branches now also use `failConnection` |

## Changes

### F5 — `expectFailure` helper fix
- `Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerProtocolTests.swift`
- Moved trailing orphan frames (ping, continuation, binary) to after the early
  hold-check assertion. The assertion now runs between the main failure frames
  and the trailing frames, so it pins that the disconnect came from the specific
  failure under test, not from a secondary orphan continuation.
- Mutant M7 (`delete failConnection(.messageTooLarge)`) now fails at the first
  `#expect(recorder.events == [.message(before), .disconnect])` instead of
  surviving through the orphan's 1002.

### F1 — `handleClose` validation
- `Sources/SwiftStateTreeNIO/WebSocketSessionHandler.swift` — three branches
  changed from `closeOnLoop(code:) + enqueueDisconnect()` to `failConnection(code:)`:
  - 1-byte payload (RFC 6455 §5.5.1) → 1002
  - Invalid close code (RFC 6455 §7.4.2) → 1002
  - Non-UTF-8 reason (RFC 6455 §8.1) → 1007
- `Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerProtocolTests.swift` — added:
  - `expectCloseValidationFailure` private helper (FlushHold, asserts `closeCause == .error`)
  - `oneByteClosePayloadCausesError` test
  - `invalidCloseCodeCausesError` test
  - `invalidUTF8CloseReasonCausesError` test

### F3 — Ping in close grace
- `Sources/SwiftStateTreeNIO/WebSocketSessionHandler.swift` — added `.ping` case
  to `handleFrameInCloseGrace` with `guard !channelCloseRequested; handlePing(frame, context:)`
- `Tests/SwiftStateTreeNIOTests/WebSocketSessionHandlerCloseGraceTests.swift`:
  - Added `pingInCloseGrace` test (pong carries payload; no pong after peer's close)
  - Updated `clientCloseEndsGrace`: ping in grace now asserts pong, not empty frames

### F4 — Solutions file
- `Notes/solutions/2026-11-25-a-drop-and-reset-error-path-makes-the-next-legal-frame-a-violation.md`
  — Fix section now lists `handleClose`'s three branches alongside the other failures
  that share `failConnection`.

## Test results

```
✔ Test run with 359 tests in 58 suites passed
```

Pre-push checks: passed (`lint-turns`, `pre-push-checks`; `check-must-not-compile` not changed by this PR).
