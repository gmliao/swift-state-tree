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

The dependency chain flows: `SwiftStateTree` → `SwiftStateTreeTransport` → `SwiftStateTreeNIO`

| Module | Role |
|--------|------|
| **SwiftStateTree** | Core DSL: `Land`, `@Sync`, `StateTree`, `Runtime`, `SchemaGen`, macros (`@StateNodeBuilder`, `@Payload`) |
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
`NIOLandHost.registerWithReevaluationSameLand(...)` registers both a live land and a replay land (using the same `LandDefinition`). The replay land type is `"\(landType)\(replayLandSuffix)"` (default `"-replay"`). `NIOAdminRoutes` `/admin/reevaluation/replay/start` checks for the registered replay land type using the same suffix. `LandTypeRegistry` validates that `definition.id` matches `landType` or is the replay alias.

**Transport encoding:** Three modes configurable via `TRANSPORT_ENCODING` env var or `NIOLandServerConfiguration.transportEncoding`: `json`, `opcodeJsonArray`, `messagepack` (default recommended for production).

**Admin routes:** Enabled when `NIOLandHostConfiguration.adminAPIKey` is set. Registered at `/admin/*`. Auth via `NIOAdminAuth` checking API key in request header.

### Testing Structure

- **Swift Testing framework** (not XCTest). Use `@Test("description")` and `#expect()`.
- Test modules: `SwiftStateTreeTests`, `SwiftStateTreeTransportTests`, `SwiftStateTreeNIOTests`, `SwiftStateTreeMacrosTests`, `SwiftStateTreeDeterministicMathTests`
- E2E scenarios live in `Tools/CLI/scenarios/{land-type}/` as JSON files
- Before submitting PRs: `swift test` must pass + E2E tests must pass

## Coding Conventions

**Language:** All code comments (`///` and `//`) must be in English. Respond to user in their language.

**Concurrency:** Always use `safeTaskSleep(for: Duration)` (in `Sources/SwiftStateTree/Support/SafeTaskSleep.swift`) instead of `Task.sleep(for:)` in library code — the latter has a Swift runtime crash bug on macOS release builds under load.

**String formatting:** Never use `%s` with Swift `String` in `String(format:)` — it expects a C string pointer and crashes in release builds. Use string interpolation or `%@` instead.

**DeterministicMath:** Never use `cos/sin/atan2/sqrt/pow` from `Darwin`/`Glibc` in game logic. Use `SwiftStateTreeDeterministicMath` types (`IVec2`, `Position2`, etc.) exclusively. Never manually divide/multiply by the fixed-point scale (`1000`).

**DTOs over dictionaries:** Use `Codable` structs for HTTP request/response bodies. Avoid `[String: Any]` for API payloads.

**Cross-platform:** Avoid `#if os(macOS)` / `#if os(Linux)` unless unavoidable. Prefer Foundation APIs that work on both platforms.

**EnvConfig pattern:** Use `getEnvString`/`getEnvBool`/`getEnvUInt16` helpers (in `Sources/SwiftStateTree/Support/EnvHelpers.swift`) and named constants from `*EnvKeys` enums instead of `ProcessInfo.processInfo.environment["KEY"]` directly.

## Git Conventions

- Commit messages: short imperative English summaries (`Add room snapshot hook`, `Fix attack damage clamp`)
- All git operations and CLI command outputs from AI agents must be in English
- Keep library changes (`Sources/`) separate from demo changes (`Examples/`) when possible

## Key File Locations

- `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift` — `registerWithReevaluationSameLand` extension on `NIOLandHost`
- `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift` — admin HTTP routes including replay start
- `Sources/SwiftStateTree/Support/SafeTaskSleep.swift` — safe sleep wrapper
- `Sources/SwiftStateTree/Support/EnvHelpers.swift` — env config helpers
- `Notes/plans/` — task-specific implementation plans (AI agents should store plans here)
- `Notes/guides/DEBUGGING_TECHNIQUES.md` — debugging guide for complex issues
- `Tools/CLI/scenarios/` — E2E test scenario JSON files
