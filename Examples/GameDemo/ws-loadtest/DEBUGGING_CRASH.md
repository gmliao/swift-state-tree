# Debugging GameServer crash during ws-loadtest / GameServer E2E

## Observed failure

GameServer (release) crashes with:

```
freed pointer was not the last allocation
Abort trap: 6 (SIGABRT)
```

- **When**: Reproduced with **single client, single room** (GameServer E2E scenario). Also with ws-loadtest (multi-room). So **not** limited to multi-room.
- **lldb**: Crash in **thread #15** (`Task 65`, queue `com.apple.root.default-qos.cooperative`), stop reason **signal SIGABRT**. Last server log lines: TransportAdapter handling action-7 and MoveTo; crash occurs during or right after normal game loop (often after scenario completes on client).
- **E2E**: `E2E_BUILD_MODE=release ./test-e2e-game.sh` fails (GameServer crashes during messagepack game scenario).

## What this error usually means

- **"freed pointer was not the last allocation"**: macOS libmalloc LIFO check failed — e.g. double free, or free in wrong order.
- In this repo it was previously linked to **unsafe `String(format: "%s", Swift String)`** (see `MESSAGEPACK_INVESTIGATION.md`). Those usages were fixed; remaining `%-27s` in EncodingBenchmark were changed to `%@`. GameServer does not run EncodingBenchmark, so if the crash persists the cause may be elsewhere (Hummingbird/NIO, Swift runtime, or another code path).

## How to get a stack trace

### Option 1: Automated (TRIGGER=1)

```bash
cd /path/to/swift-state-tree
TRIGGER=1 bash Examples/GameDemo/scripts/run-gameserver-lldb-backtrace.sh
```

Builds GameServer (release), runs it under lldb, and after 45s runs the E2E game scenario to trigger the crash. Backtrace is written to `Examples/GameDemo/tmp/lldb-backtrace.txt`. If `bt` in batch mode only shows frame #0, run Option 2 and type `bt` manually.

### Option 2: Run under lldb (interactive, full backtrace)

```bash
cd Examples/GameDemo
ENABLE_REEVALUATION=false TRANSPORT_ENCODING=messagepack LOG_LEVEL=info NO_COLOR=1 lldb -- .build/release/GameServer
# In lldb:
(lldb) run
# When crash happens (freed pointer / SIGABRT), type:
(lldb) bt 50
(lldb) thread backtrace all
(lldb) quit
```

In another terminal, run the E2E scenario or ws-loadtest to trigger the crash.

### Option 2: MallocStackLogging (macOS)

```bash
cd Examples/GameDemo
MallocStackLogging=1 MallocScribble=1 ENABLE_REEVALUATION=false LOG_LEVEL=error NO_COLOR=1 swift run -c release GameServer 2>&1 | tee /tmp/ws-loadtest-gameserver.log
```

Run the load test from another terminal. When the crash occurs, the log may include allocation history; `malloc_history` or the crash report can give stacks.

### Option 3: Address Sanitizer (may not hit this bug)

```bash
cd Examples/GameDemo
swift build -c release -Xswiftc -sanitize=address --product GameServer
ENABLE_REEVALUATION=false LOG_LEVEL=error NO_COLOR=1 .build/release/GameServer
```

ASAN often catches use-after-free/double-free but not all libmalloc LIFO failures; the doc notes ASAN passed while plain Release failed on macOS multi-room.

## Reducing load to avoid crash

- **Tested:** 1 room × 5 players (steady) still crashes. So the crash is **not** limited to multi-room; it occurs with hero-defense land under any load (E2E single client and ws-loadtest 1 room both crash).

## References

- `Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md` — previous "freed pointer was not the last allocation" investigation and String(format:) fixes.
- `AGENTS.md` — "Safe String Formatting" and debugging sections.
