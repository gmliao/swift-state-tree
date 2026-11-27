# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
# Build
swift build                          # debug build
swift build -c release               # release build (exposes concurrency bugs not visible in debug)

# Test
swift test                           # run all Swift tests
swift test --filter "SuiteName/TestName"  # run a single test
swift test list                      # list all available tests

# TypeScript SDK
cd sdk/ts && npm test                # run vitest tests (158 tests)
cd sdk/ts && npm run build           # compile TypeScript to dist/

# E2E tests (requires DemoServer running)
cd Tools/CLI && ./test-e2e-ci.sh     # recommended: auto-handles server lifecycle
cd Tools/CLI && npm test             # manual: assumes DemoServer already running

# Demo server
cd Examples/Demo && swift run DemoServer      # localhost:8080
cd Examples/GameDemo && swift run GameServer  # localhost:8080

# Schema + client codegen
cd Examples/Demo && swift run SchemaGen --output schema.json
cd Examples/Demo/WebClient && npm run codegen
```

## Module Architecture

The dependency chain flows: `SwiftStateTurns` → `SwiftStateTree` → `SwiftStateTreeTransport` → `SwiftStateTreeNIO` (Transport also depends on `SwiftStateTurns` directly)

| Module | Role |
|--------|------|
| **SwiftStateTree** | Core DSL: `Land`, `@Sync`, `StateTree`, `Runtime`, `SchemaGen`, macros (`@StateNodeBuilder`, `@Payload`) |
| **SwiftStateTurns** | Turn core: `TurnActor`, `TurnCore`, `@PlainData` (its macros in `SwiftStateTurnsMacros`); a dependency of SwiftStateTree, its MessagePack target and Transport |
| **SwiftStateTreeTransport** | Framework-agnostic layer: `WebSocketTransport`, `TransportAdapter`, `LandManager`, `LandRouter`, `LandTypeRegistry`, `LandRealm` |
| **SwiftStateTreeNIO** | NIO hosting: `NIOLandHost` (actor), `NIOLandServer`, `NIOWebSocketServer`, `NIOAdminRoutes`, `ReevaluationFeature` |
| **SwiftStateTreeNIOProvisioning** | Optional middleware for control-plane registration (`ProvisioningHTTPClient`) |
| **SwiftStateTreeDeterministicMath** | Fixed-point math for server-authoritative games (`FixedPoint`, `IVec2`, `Position2`, `Velocity2`, `Angle`) |
| **SwiftStateTreeReevaluationMonitor** | Built-in Land for monitoring reevaluation/replay verification |
| **SwiftStateTreeMacros** | Compile-time macro expansions (separate macro target) |

### Key Architectural Flows

**Hosting a land type:**
`NIOLandHost.register(landType:land:...)` → creates `NIOLandServer<State>` (owns `LandManager` + `LandTypeRegistry` + `LandRouter`) → registers with `LandRealm` → maps WebSocket path to transport

**Reevaluation/Replay:**
`NIOLandHost.registerWithGenericReplay(...)` registers a live land, a replay land (`GenericReplayLand`, a live land that shows the replay runner's results) and the reevaluation monitor land. Every keeper a `LandManager` creates is live; a replay runs in a headless reevaluation keeper, never behind a transport adapter. The replay land type is `"\(landType)\(replayLandSuffix)"` (default `"-replay"`). `NIOAdminRoutes` `/admin/reevaluation/replay/start` checks for the registered replay land type using the same suffix. `LandTypeRegistry` validates that `definition.id` matches `landType` or is the replay alias.

**Transport encoding:** Three modes configurable via `TRANSPORT_ENCODING` env var or `NIOLandServerConfiguration.transportEncoding`: `json`, `opcodeJsonArray`, `messagepack` (default recommended for production).

**Admin routes:** Enabled when `NIOLandHostConfiguration.adminAPIKey` is set. Registered at `/admin/*`. Auth via `NIOAdminAuth` checking API key in request header.

### Testing Structure

- **Swift Testing framework** (not XCTest). Use `@Test("description")` and `#expect()`.
- Test modules: `SwiftStateTreeTests`, `SwiftStateTreeTransportTests`, `SwiftStateTreeNIOTests`, `SwiftStateTreeMacrosTests`, `SwiftStateTreeDeterministicMathTests`
- E2E scenarios live in `Tools/CLI/scenarios/{land-type}/` as JSON files
- Before submitting PRs: `swift test` must pass + E2E tests must pass

## Coding Conventions

**Language:** All code comments (`///` and `//`) must be in English. Respond to user in their language.

**Concurrency:** Always use `safeTaskSleep(for: Duration)` (in `Sources/SwiftStateTree/Support/SafeTaskSleep.swift`) instead of `Task.sleep(for:)`, and `safeTaskSleep(until:)` for deadline sleeps instead of `Task.sleep(until:)`, in library code — `Task.sleep(for:)` has a Swift runtime crash bug on macOS release builds under load, and `Task.sleep(until:)` was not shown safe.

**String formatting:** Never use `%s` with Swift `String` in `String(format:)` — it expects a C string pointer and crashes in release builds. Use string interpolation or `%@` instead.

**DeterministicMath:** Never use `cos/sin/atan2/sqrt/pow` from `Darwin`/`Glibc` in game logic. Use `SwiftStateTreeDeterministicMath` types (`IVec2`, `Position2`, etc.) exclusively. Never manually divide/multiply by the fixed-point scale (`1000`).

**DTOs over dictionaries:** Use `Codable` structs for HTTP request/response bodies. Avoid `[String: Any]` for API payloads.

**Reentrancy: keeper state changes only in turns.** Every `await` inside an actor lets other calls run, so state checked before it (a lookup, `isEmpty`, `isRunning`, "already joined", "session still connected") may be stale after it. The rule (the target; see `Notes/plans/2026-11-05-reentrancy-helpers.md`):
- **Keeper state is mutated only inside synchronous turns.** Async work is a request that goes out; its result comes back as a turn input, whose handler re-reads the current state and validates a ticket captured when the request went out (Elm's `Cmd`/`Msg`, Erlang's `gen_server`). A suspended keeper function never resumes to mutate keeper state. Not yet true for the join/leave resolvers and the freeze drain (#129: `debugFreeze` re-checks its generation and registers its waiter after each await); those paths still re-check by hand until they move. Re-evaluation keepers keep their non-turn replay path until #612, including the initialization's replay-header check and its replay before tick zero. The reevaluation monitor land is a further exception: its tick reads the runner service's results (a run ticket guards them) instead of receiving them as turn inputs, until server-originated turn inputs (#387) replace that read. After an action's resolvers no land state is mutated, but its frame still does keeper bookkeeping: the freeze accounting in `debugEndWork` and, on a tickless land, the turn waiter registration (`awaitInputTurn`).
- **Outside turns** (adapter, transport, router, host, NIO, admin), use the helpers in `Sources/SwiftStateTree/Support`: a `GenerationTable` ticket captured before the `await` and checked with `ifCurrent` (its closure can't await) in the same segment as the act; `SingleFlight` for create/destroy once; `Lifecycle` for start/stop. Never remove or overwrite keyed state by key alone from a callback that can outlive its instance.
- Mail that the keeper must see before its next step (a failure found while closing the output gate) is posted to the core's mailbox (`post`, nonisolated, no await), which the next step takes first; an awaited submit can't promise that, because the keeper may run a step before the hop lands. Until #700 moves the keeper onto the turn core, #732's `LandFailureMailbox` stands in for the core's mailbox: a set-once mailbox on the keeper, written in the segment that finds the failure and read at the keeper's step boundaries, so the async submit only wakes the keeper.
- Order-sensitive per-session or per-player work goes through one serial queue (the adapter's membership queue), not independent Tasks.
- Tests force the interleaving with a hold at the `await` (`HoldPoints`, `TestGate`), never timing. TSan does not catch this class.

**Cross-platform:** Avoid `#if os(macOS)` / `#if os(Linux)` unless unavoidable. Prefer Foundation APIs that work on both platforms.

**Lessons:** Before designing a fix, search `Notes/solutions/` for the symptom or bug class. When a fix carries a reusable lesson (a cause that could recur elsewhere, a trap that took more than one attempt, a review finding that names a rule), add an entry in the same change and run `scripts/solutions-index.py`, which writes the index from the entry's `title:`. Format in `Notes/solutions/README.md`.

**EnvConfig pattern:** Use `getEnvString`/`getEnvBool`/`getEnvUInt16` helpers (in `Sources/SwiftStateTree/Support/EnvHelpers.swift`) and named constants from `*EnvKeys` enums instead of `ProcessInfo.processInfo.environment["KEY"]` directly.

## Git Conventions

- Commit messages: short imperative English summaries (`Add room snapshot hook`, `Fix attack damage clamp`)
- All git operations and CLI command outputs from AI agents must be in English
- Keep library changes (`Sources/`) separate from demo changes (`Examples/`) when possible

## Key File Locations

- `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` — `registerWithGenericReplay` extension on `NIOLandHost`
- `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift` — admin HTTP routes including replay start
- `Sources/SwiftStateTree/Support/SafeTaskSleep.swift` — safe sleep wrapper
- `Sources/SwiftStateTree/Support/EnvHelpers.swift` — env config helpers
- `Notes/plans/` — task-specific implementation plans (AI agents should store plans here; naming, the status index and when to update it are in AGENTS.md § Documentation)
- `Notes/solutions/` — reusable lessons from solved problems (bug classes, traps, measurement pitfalls), with an index; search it before designing a fix
- `Notes/guides/DEBUGGING_TECHNIQUES.md` — debugging guide for complex issues
- `Tools/CLI/scenarios/` — E2E test scenario JSON files

## Claude Code Specifics

### Local setup (`.claude/` is gitignored)

`.claude/` is not tracked. The maintainer keeps workflow skills in a private, gitignored workbench directory and points `.claude/skills` at it with a symlink; that workbench links the public knowledge skills back from `.agent/skills/SwiftStateTree/`. On a clone without that workbench, symlink the public skills directly:

```bash
mkdir -p .claude/skills && cd .claude/skills
for d in ../../.agent/skills/SwiftStateTree/*/; do ln -sfn "../../.agent/skills/SwiftStateTree/$(basename "$d")" "$(basename "$d")"; done
```

**Edit knowledge skills under `.agent/skills/SwiftStateTree/`** (shared with Cursor/Codex), never as real files in `.claude/skills/`. Superpowers/SpecKit skills are not symlinked: Claude Code gets them from the global plugin, which is newer than the snapshot in `.agent/skills/Superpowers/`.

### LSP

Enable `swift-lsp` and `typescript-lsp` in your local `.claude/settings.json` (or globally). Prefer the `LSP` tool for symbol navigation and diagnostics in Swift and in the TS packages (`sdk/ts`, `Tools/CLI`, `Examples/*/WebClient`). If LSP does not respond, tell the user instead of silently falling back to grep.

### Troubleshooting

- **E2E fails to start / port 8080 busy** — DemoServer and GameServer both bind 8080. Run `./killport.sh 8080` from the repo root, then re-run `./Tools/CLI/test-e2e-ci.sh` or `./Tools/CLI/test-e2e-game.sh`.
- **Reevaluation E2E is skipped** — GameServer only mounts reevaluation routes when `ENABLE_REEVALUATION=true`. `test-e2e-game.sh` sets it; set it yourself when starting the server manually.
- **Benchmark numbers look wrong** — `EncodingBenchmark` and `ServerLoadTest` must run with `swift run -c release`. Debug-build numbers are not comparable and must not be written into docs.
- **Pinned toolchain** — CI, the devcontainer and every Dockerfile (`.github/docker/`, `docker/` for the DemoServer/GameServer images and the build image) use `swift:6.4.3-noble` for their build stages (Swift 6.4.3, pinned by digest in the workflows and in every Swift `FROM` line; the DemoServer/GameServer runtime stages use `ubuntu:24.04` by tag); CI on that image is the gate. A local macOS toolchain is fine for development. From 6.4, SwiftPM builds with the swift-build system by default. On Linux, products land in `.build/out/Products/<Config>-linux-<arch>` (`x86_64` in CI; an arm64 devcontainer gets `aarch64`; `.build/debug` and `.build/release` are symlinks to it), and a test target is an executable `<target>-test-runner` there instead of a `.xctest` bundle; macOS has no `-linux-<arch>` suffix and keeps the `.xctest` bundle. Take paths from `swift build --show-bin-path`. Performance comparisons must build both sides with the same toolchain: rebuild base and change in one container from the pinned image, and check the recorded `swift --version` (`metadata.build.swiftVersion` in EncodingBenchmark / ServerLoadTest results, `toolchain.txt` next to ws-loadtest reports, which also holds the load client's `node --version`) before comparing numbers. Changing the pinned version is its own change and re-establishes the performance baseline.
- **Toolchain drift** — the last full verification on record (2026-02-18: 714 tests, all three encodings E2E, replay 0 mismatch) used Swift 6.2.3. CI's floating `swift:6.2` moved to 6.2.4 on 2026-10-27; since #117, CI was pinned to 6.2.4, and since #775 (2026-11-24) to 6.4.3; performance numbers from 6.2.4 are not comparable with 6.4.3 ones (compiler and build system both changed); the 6.4.3 baseline is a new one. On 2026-08-29 `swift test` passed 790 tests / 46 suites on Swift 6.3.2. `Package.swift` takes `swift-syntax` in `"602.0.0"..<"605.0.0"`, and `Package.resolved` pins 602.0.0. CI's 6.2.4 used its prebuilt; in `swift:6.4.3-noble` on x86_64 Linux, SwiftPM used no prebuilt for either 602.0.0 or 604.0.0, and both build from source. 604.0.0 on macOS with Swift 6.4.2: SwiftPM downloads the prebuilt but doesn't use it. Check `deep-research/` notes before bumping macro dependencies.

### Research Notes

`deep-research/` holds experiment data with a README per experiment (question, environment, commands, results, `regenerate.py`), not in `docs/`. Keep that data and its READMEs neutral and technical; drafts, plans and strategy notes for publications don't belong in this repository. `docs/` is the official bilingual documentation and is bound by the bilingual-sync rule in AGENTS.md. Repository prose (CLAUDE.md, README, code comments, commit messages) is English; Chinese is reserved for design documents and `.zh-TW.md` translations.
