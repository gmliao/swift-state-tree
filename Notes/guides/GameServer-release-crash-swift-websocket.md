# GameServer release crash (macOS) - swift-websocket Task.sleep(for:) issue

## Summary
GameServer E2E in **release** on macOS crashed with:

```
freed pointer was not the last allocation
Abort trap: 6 (SIGABRT)
```

Root cause is a **Swift Concurrency runtime bug** on macOS release builds when using `Task.sleep(for:)`.
The crash stack shows `swift_task_dealloc` -> `Task.sleep(for:)` inside `WebSocketHandler.runAutoPingLoop()`
from the `swift-websocket` dependency.

## Reproduction

```bash
E2E_BUILD_MODE=release Tools/CLI/test-e2e-game.sh
```

Crash happened after the Hero Defense scenario completed.

## Evidence (Crash Report)
Crash report shows the faulting thread stack (paraphrased):

- `swift_task_dealloc`
- `Task<>.sleep(for:tolerance:clock:)`
- `WebSocketHandler.runAutoPingLoop()`
- `WebSocketHandler.handle(...)`

This maps to `swift-websocket`:
`Sources/WSCore/WebSocketHandler.swift`.

## Temporary Fix (Local Patch)
Replace **all** `Task.sleep(for:)` calls in `WebSocketHandler.swift` with a safe helper that converts
`Duration` to nanoseconds and uses `Task.sleep(nanoseconds:)`.

**Patched file (used by GameDemo):**
- `Examples/GameDemo/Packages/swift-websocket/Sources/WSCore/WebSocketHandler.swift`

**Change summary:**
- `Task.sleep(for: configuration.closeTimeout)` -> `wsSafeTaskSleep(for: ...)`
- `Task.sleep(for: period)` -> `wsSafeTaskSleep(for: ...)`
- `Task.sleep(for: time)` -> `wsSafeTaskSleep(for: ...)`

**Helper added (same file):**
```swift
private func wsSafeTaskSleep(for duration: Duration) async throws {
    let comps = duration.components
    let seconds = comps.seconds
    let attoseconds = comps.attoseconds

    guard seconds >= 0, attoseconds >= 0 else { return }

    let nanosFromAttos = UInt64(attoseconds / 1_000_000_000)
    guard let sec = UInt64(exactly: seconds) else { return }

    let mul = sec.multipliedReportingOverflow(by: 1_000_000_000)
    guard !mul.overflow else { return }

    let add = mul.partialValue.addingReportingOverflow(nanosFromAttos)
    guard !add.overflow else { return }

    try await Task.sleep(nanoseconds: add.partialValue)
}
```

## Verification
After the patch, the same command passed fully:

```bash
E2E_BUILD_MODE=release Tools/CLI/test-e2e-game.sh
```

- Hero Defense E2E scenario completed
- Re-evaluation record + verify completed
- No crash

## Recommended Long-Term Fix
1. **Fork** `swift-websocket` and apply the patch.
2. Point `Package.swift` to the fork (pin to a commit or tag).
3. Open an upstream issue/PR describing the macOS release crash in `Task.sleep(for:)`.

## Notes
- Upgrading `swift-websocket` to the latest release did **not** mention this fix in release notes.
- This crash aligns with the known Swift Concurrency runtime bug on macOS release builds.
