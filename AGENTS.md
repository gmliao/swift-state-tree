# Repository Guidelines

## AI Agent Quick Reference

### Common Commands
- **Run E2E Tests**: When user says "執行 e2e 測試" or "run e2e tests":
 1. **Option 1 - Use test script (recommended)**: `cd Tools/CLI && ./test-e2e-ci.sh`
    - Automatically handles server startup/shutdown
    - Tests all three encoding modes sequentially
    - Shows server logs on failure
 2. **Option 2 - Manual steps**:
    - Start server: `cd Examples/HummingbirdDemo && swift run DemoServer` (background)
    - Wait 2-3 seconds for server startup
    - Run tests: `cd Tools/CLI && npm test`
    - Verify all tests pass before proceeding

- **Run Full Test Suite**: `cd Tools/CLI && npm run test:e2e:with-game` (requires DemoServer + GameServer)

- **Create New Test Scenario**: Add JSON file to `Tools/CLI/scenarios/{land-type}/` directory

- **View PR Comments**: When user says "看 PR comment" or "查看 PR":
 1. View PR details with comments: `gh pr view --comments` (shows PR info and review comments)
 2. View PR comments (留言區): `gh api repos/:owner/:repo/pulls/$(gh pr view --json number --jq '.number')/comments --jq '.[] | {id: .id, author: .user.login, body: .body, createdAt: .created_at}'` (shows all comments in the conversation thread)
 3. View PR reviews (review comments): `gh pr view --json reviews --jq '.reviews[] | select(.state == "COMMENTED") | {body: .body, author: .author.login}'` (shows review comments from reviewers)
 4. View all comments and reviews together: `gh pr view --json comments,reviews --jq '{comments: .comments, reviews: .reviews}'`
 5. Open PR in browser: `gh pr view --web`

- **Reply to Specific PR Comment**: When user wants to reply to a specific comment thread:
 1. Get repo name: `gh repo view --json nameWithOwner --jq '.nameWithOwner'` (e.g., `gmliao/swift-state-tree`)
 2. Get comment ID from PR comments: `gh pr view PR_NUMBER --json comments,reviews --jq '.reviews[].comments[] | {id: .id, author: .author.login, body: (.body | split("\n")[0:2] | join("\n"))}'` or view line comments: `gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments --jq '.[] | {id: .id, path: .path, line: .line, body: (.body | split("\n")[0:2] | join("\n"))}'`
 3. Reply to review comment (line comment): `gh api --method POST repos/OWNER/REPO/pulls/PR_NUMBER/comments/COMMENT_ID/replies -f body="Your reply text"`
 4. Note: Use actual repo name (e.g., `gmliao/swift-state-tree`) instead of `:owner/:repo` placeholder
 5. Example: `gh api --method POST repos/gmliao/swift-state-tree/pulls/24/comments/2700778279/replies -f body="Thanks for the review! ..."`

### Key Testing Locations
- **Unit Tests**: `swift test` (Swift Testing framework)
- **E2E Tests**: `cd Tools/CLI && npm test` (requires DemoServer)
- **Protocol Tests**: `cd Tools/CLI && npm run test:protocol`
- **WebClient Tests**: `cd Examples/HummingbirdDemo/WebClient && npm test`

### Before Submitting PRs
- ✅ All `swift test` must pass
- ✅ All E2E tests must pass (both encoding modes: `jsonObject`, `opcodeJsonArray`)
- ✅ No linter errors
- ✅ Code comments in English

---

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library (Land DSL, Runtime, Sync, StateTree).
- `Sources/SwiftStateTreeTransport`: transport abstraction layer (WebSocket, Land management, routing).
- `Sources/SwiftStateTreeNIO`: NIO-based hosting (NIOLandHost, NIOLandServer, WebSocket). Default server integration; no Hummingbird dependency.
- `Sources/SwiftStateTreeMatchmaking`: matchmaking service and lobby functionality.
- `Sources/SwiftStateTreeMacros`: compile-time macros (`@StateNodeBuilder`, `@Payload`, `@SnapshotConvertible`).
- `Sources/SwiftStateTreeDeterministicMath`: deterministic math library for server-authoritative games.
  - `Core/`: Fixed-point arithmetic (`FixedPoint`), integer vectors (`IVec2`, `IVec3`).
  - `Collision/`: Collision detection (`IAABB2`, `ICircle`, `IRay`, `ILineSegment`) for 2D games.
  - `Semantic/`: Type-safe semantic types (`Position2`, `Velocity2`, `Acceleration2`).
  - `Grid/`: Grid-based coordinate conversions (`Grid2`).
  - `Overflow/`: Overflow handling policies (`OverflowPolicy`).
  - All operations use Int32 fixed-point arithmetic for deterministic behavior across platforms.
- `Sources/SwiftStateTreeBenchmarks`: benchmark executable.
- `Examples/HummingbirdDemo`: demo project with unified `DemoServer` (NIO) and web client.
- `Archive/SwiftStateTreeHummingbird`: archived Hummingbird integration (reference only; see Archive README).
- `Tests/SwiftStateTreeTests`: unit tests for the library.

## Build, Test, and Development Commands
- `swift build`: compile all targets; use `-c release` for performance checks.
- `swift test`: run all library tests; use `swift test --filter StateTreeTests.testGetSyncFields` for a single case.
- `swift test list`: list all available tests.
- `swift run DemoServer`: start the unified demo server (from `Examples/HummingbirdDemo`).
- `swift run GameServer`: start the Hero Defense game server (from `Examples/GameDemo`).
- `swift package resolve`: refresh dependencies if `Package.resolved` drifts.
- **E2E Testing**: `cd Tools/CLI && npm test` (requires DemoServer running). See "Testing Guidelines" section for details.

## Schema Generation & Codegen
- **Generate schema**: `cd Examples/HummingbirdDemo && swift run SchemaGen --output schema.json` (generates JSON schema from LandDefinitions).
- **Generate client SDK**: `cd Examples/HummingbirdDemo/WebClient && npm run codegen` (generates TypeScript client code from `schema.json`).
- Schema generation uses `@StateNodeBuilder` and `@Payload` macro metadata to extract types automatically.
- Generated files in `WebClient/src/generated/` should be committed to version control.

## TypeScript SDK
- **Location**: `sdk/ts/` - TypeScript SDK with runtime, codegen, and type definitions.
- **Build SDK**: `cd sdk/ts && npm run build` (compiles TypeScript to `dist/`).
- **Test SDK**: `cd sdk/ts && npm test` (runs vitest tests).
- **SDK structure**: `core/` (runtime, view), `codegen/` (code generation), `types/` (transport types).
- **Usage**: SDK can be used as npm package `@swiftstatetree/sdk` or via local path in demo projects.

## Coding Style & Naming Conventions
- Swift 6, macOS 13+; follow Swift API Design Guidelines and prefer `Sendable` on public types.
- Indent with 4 spaces; keep line length reasonable (~120 chars).
- Types: `UpperCamelCase`; methods/variables: `lowerCamelCase`; enums use verb-like cases for commands (`.join`, `.attack`).
- Place new game logic in `Sources/SwiftStateTree`; keep demo-only code inside `Examples/HummingbirdDemo`.
- **Return statements**: Omit `return` for single-expression functions; include `return` for multi-line function bodies.
- **Cross-Platform Compatibility**: Always prioritize cross-platform solutions over platform-specific code. Avoid `#if os(macOS)` or `#if os(Linux)` conditionals unless absolutely necessary (e.g., when platform-specific APIs are required and no cross-platform alternative exists). Prefer using Foundation APIs that work on both macOS and Linux (e.g., `objCType` instead of `CFGetTypeID`). When platform-specific code is unavoidable, document why and consider future alternatives.

### Safe String Formatting (avoid C varargs pitfalls)
- **Avoid** C printf-style formatting with Swift objects: `String(format:)`, `NSString(format:)`, `printf/fprintf`, `NSLog`.
  - **Never use `%s` with Swift `String`/`Substring`**. `%s` expects a C string pointer and can crash in release builds.
- **Prefer**:
  - **String interpolation**: `print("rooms=\(rooms), bytes=\(bytes)")`
  - **SwiftLog `Logger`** with metadata for structured logs.
  - For fixed-width tables, build columns via padding/truncation helpers instead of `String(format:)`.
- **Allowed exception (with care)**:
  - `String(format:)` for **numeric/hex-only** formatting (e.g., `%.3f`, `%02x`) when all arguments are numeric primitives and the format string exactly matches the argument types.
  - If you must format a string with `String(format:)`, use `%@` (bridged object) or switch to interpolation.

### DeterministicMath Usage Guidelines
- **Never use Swift's built-in math functions** (e.g., `cos`, `sin`, `atan2`, `sqrt`, `pow`) in game logic code.
  - These functions are platform-dependent and may produce different results across macOS, Linux, and other platforms.
  - **Do not import `Darwin` or `Glibc`** for math functions.
  - Always use `SwiftStateTreeDeterministicMath` provided methods instead:
    - Angles: Use `IVec2.toAngle()` to get `Angle` from direction vectors.
    - Vector operations: Use `IVec2` methods (`normalizedVec()`, `scaled(by:)`, etc.).
    - Distance calculations: Use `Position2.isWithinDistance(to:threshold:)` or semantic type methods.
- **Never directly manipulate fixed-point scale (e.g., `/1000`, `*1000`)** in game logic code.
- **Never directly use `Int64` return values** from `IVec2` methods (e.g., `distanceSquared()`, `magnitudeSquared()`, `dot()`) in game logic.
- Always use semantic types (`Position2`, `Velocity2`, `Angle`) and their provided helper methods instead of raw `IVec2` operations when possible.
- If you find yourself doing manual fixed-point conversions or distance calculations, check if `SwiftStateTreeDeterministicMath` already provides a helper method:
  - Distance comparisons: Use `Position2.isWithinDistance(to:threshold:)` instead of `distanceSquared()` returning `Int64`.
  - Movement: Use `Position2.moveTowards(target:maxDistance:)` instead of manual direction normalization and scaling.
  - Vector operations: Use `IVec2.scaled(by:)` and `IVec2.normalizedVec()` instead of manual `/1000` conversions.
- **IVec2 methods returning `Int64` are for internal library use only** (collision detection, raycasting, etc.). Game logic should use semantic types (`Position2`, `Velocity2`) instead.
- If a needed helper method doesn't exist, **propose adding it to the DeterministicMath library** rather than implementing workarounds in game logic.
- This ensures code clarity, maintainability, and consistency across the codebase.

### Safe Task.sleep Usage (avoid Swift Concurrency runtime bug)
- **Never use `Task.sleep(for: Duration)` directly in library code** (`Sources/SwiftStateTree`).
  - `Task.sleep(for:)` has a known bug in Swift Concurrency runtime that can cause crashes (`SIGABRT` in `swift_task_dealloc`) on macOS release builds under load.
  - **Always use `safeTaskSleep(for: Duration)` instead** (defined in `Sources/SwiftStateTree/Support/SafeTaskSleep.swift`).
  - This helper converts `Duration` to nanoseconds and uses `Task.sleep(nanoseconds:)` to work around the runtime bug.
- **Exceptions**: `Task.sleep(for:)` is acceptable in `Tests/`, `Examples/`, and documentation code, but library runtime code must use `safeTaskSleep(for:)`.
- **Rationale**: This ensures stability in production server environments where release builds are used and load conditions can trigger the bug.

#### Collision Detection Range Limits

##### ICircle (Invariants)
- **Coordinates**: Must be within `FixedPoint.WORLD_MAX_COORDINATE` (≈ ±1,073,741,823 fixed-point units, or ±1,073,741.823 Float units with scale 1000).
  - **Why Int32.max / 2?** The maximum possible difference between two coordinates is `Int32.max - Int32.min ≈ 4,294,967,295`, and `dx²` would be `1.844e19`, which exceeds `Int64.max (9.22e18)`. To ensure `dx² + dy² ≤ Int64.max`, we need `|dx| ≤ sqrt(Int64.max / 2) ≈ 2,147,483,647`. Since `dx = x1 - x2`, we need `|x| ≤ Int32.max / 2 = 1,073,741,823` to guarantee safety.
- **Radius**: Must be within `FixedPoint.MAX_CIRCLE_RADIUS` (≈ 2,147,483,647 fixed-point units, or 2,147,483.647 Float units with scale 1000).
  - **Why Int32.max?** Since `IAABB2` and `IVec2` use Int32 coordinates, and `boundingAABB()` needs to compute `center ± radius`, we limit radius to `Int32.max` to ensure the result can be represented as Int32.
- **Invariant enforcement**: `ICircle.init` automatically clamps radius to `MAX_CIRCLE_RADIUS`. Coordinates should be validated by the game logic to ensure they are within `WORLD_MAX_COORDINATE`.
- **Overflow handling**: All collision detection methods use `multipliedReportingOverflow` and `addingReportingOverflow` to detect overflow and handle it deterministically (conservative: treat as intersecting if radius overflow, no intersection if distance overflow).

##### IRay and ILineSegment (Upgraded)
- **Coordinates**: Must be within `FixedPoint.WORLD_MAX_COORDINATE` (≈ ±1,073,741,823 fixed-point units, or ±1,073,741.823 Float units with scale 1000).
  - **Upgrade**: Both `IRay.intersects(circle:)` and `ILineSegment.intersects(circle:)` now use direct distance calculation with Int64, avoiding the previous 46.34 unit limit.
  - **ILineSegment.distanceSquaredToPoint**: Also upgraded to use direct Int64 distance calculation.
- **Radius**: Circle radius must be within `FixedPoint.MAX_CIRCLE_RADIUS` to ensure compatibility.
- **Overflow handling**: All methods use overflow detection to handle edge cases deterministically.

##### IAABB2
- **No inherent coordinate limits**: `IAABB2` itself uses only simple comparisons (min/max checks) and does not compute squared distances, so it has no inherent overflow risk.
- **Interaction with other collision types**: When `IAABB2` is used with other collision types:
  - `ICircle.intersects(aabb:)`: Uses direct Int64 distance calculation, supports up to `WORLD_MAX_COORDINATE` (≈ ±1,073,741.823 Float units).
  - `IRay.intersects(aabb:)`: Uses slab method (no distance calculation), supports full `Int32` coordinate range.
- **Note**: The previous 46.34 unit limit was due to `ICircle.intersects(aabb:)` using `IVec2.distanceSquared`, but this has been upgraded and the limit no longer applies.

##### Normal game scenarios
- Most games will never approach these limits. `WORLD_MAX_COORDINATE` (≈ 1 million Float units with scale 1000) is very large for most 2D games.
- Be aware when designing very large worlds or using extreme coordinate values. Use `FixedPoint.clampToWorldRange()` to ensure coordinates are within safe bounds.

## Testing Guidelines
- **Framework: Swift Testing** (Swift 6's new testing framework, not XCTest).
- **Test modules**: `SwiftStateTreeTests` (core), `SwiftStateTreeTransportTests` (transport), `SwiftStateTreeNIOTests` (NIO), `SwiftStateTreeMacrosTests` (macros), `SwiftStateTreeMatchmakingTests` (matchmaking), `SwiftStateTreeDeterministicMathTests` (deterministic math).
- Add tests under appropriate test module, mirroring the type under test (e.g., `StateTreeTests.swift`).
- Use `@Test` attribute with descriptive names: `@Test("Description of what is being tested")`.
- Use `#expect()` for assertions instead of `XCTAssert*`.
- Use `Issue.record()` for test failures that should be reported.
- Name test functions with clear intent; prefer arranging with setup/act/assert comments when logic grows.
- Use Arrange‑Act‑Assert structure; keep test files suffixed with `*Tests.swift` matching the type under test.
- When adding public APIs or core game logic, add/refresh tests and run `swift test` before sending changes out.
- Aim to cover new public APIs and concurrency paths; avoid shared mutable state between tests.
- **WebClient tests**: `cd Examples/HummingbirdDemo/WebClient && npm test` (uses vitest for Vue component and business logic tests).
- **Automated E2E Testing (CLI)**: 
  **Quick Command**: When user says "執行 e2e 測試" or "run e2e tests", AI should:
  1. **Start DemoServer**: `cd Examples/HummingbirdDemo && swift run DemoServer` (run in background, default: json encoding).
  2. **Wait for server**: Wait 2-3 seconds for server to start.
  3. **Run E2E tests**: `cd Tools/CLI && npm test` (runs protocol tests + counter/cookie E2E tests in both jsonObject and opcodeJsonArray modes).
  4. **Note**: Tests automatically start servers with correct encoding modes via environment variables.
  5. **Verify results**: All tests must pass. If any test fails, investigate and fix before proceeding.
  
  **Full Test Suite** (including game tests):
  1. **Start DemoServer**: `cd Examples/HummingbirdDemo && swift run DemoServer`.
  2. **Start GameServer** (optional): `cd Examples/GameDemo && swift run GameServer` (runs on same port 8080, different endpoint).
  3. **Run all tests**: `cd Tools/CLI && npm run test:e2e:with-game` (requires both servers running).
  
  **Test Coverage**:
  - ✅ **Core Features**: Actions, Events, State Sync, Error Handling, Multi-Encoding
  - ✅ **Lifecycle**: Tick Handler, OnJoin Handler
  - ⚠️ **Partial**: Per-Player State, Broadcast State (single client only)
  - ❌ **Not Covered**: Multi-Player Scenarios, OnLeave Handler (requires disconnect testing)
  
  **Important Notes**:
  - AI must ensure all tests pass before submitting PRs.
  - **Encoding Modes**: Tests run in all three encoding modes (`jsonObject`, `opcodeJsonArray`, `messagepack`). DemoServer automatically switches encoding based on `TRANSPORT_ENCODING` environment variable:
    - `TRANSPORT_ENCODING=json` → JSON messages + JSON object state updates
    - `TRANSPORT_ENCODING=jsonOpcode` → JSON messages + opcode JSON array state updates
    - `TRANSPORT_ENCODING=messagepack` → MessagePack binary encoding for both messages and state updates
  - When running tests manually, ensure the server is started with the matching encoding mode.
  - Each test uses unique land instance ID to ensure clean state.
  - Tests verify exact state values (not ranges) for precision.
  - **Connection Info**:
    - **Base URL**: `http://localhost:8080`
    - **WebSocket Endpoints**:
      - `cookie`: `ws://localhost:8080/game/cookie` (DemoServer)
      - `counter`: `ws://localhost:8080/game/counter` (DemoServer)
      - `hero-defense`: `ws://localhost:8080/game/hero-defense` (GameServer)
    - **Admin Keys**: 
      - DemoServer: `demo-admin-key`
      - GameServer: `hero-defense-admin-key`
  - **Proactive Testing**: AI agents are encouraged to create new JSON scenarios in `Tools/CLI/scenarios/` (organized by Land subdirectories) to verify specific features or bug fixes. These scenarios should use the `assert` step to ensure correctness.

## Commit & Pull Request Guidelines
- Messages: short imperative summaries (`Add room snapshot hook`, `Fix attack damage clamp`).
- PRs: describe intent, note new APIs, list test coverage (`swift test` output), and include manual steps for demo changes.
- Keep changes scoped; separate library additions from demo tweaks when possible.
- **AI CLI Operations**: When AI agents perform git operations (commit, rebase, merge, etc.) or any CLI commands through tools, all commit messages, branch names, and command outputs must be in English. This ensures consistency and compatibility across different environments and tools.

## Security & Configuration Tips
- Demo server is for local use; avoid committing secrets or tokens.
- Validate inbound WebSocket payloads in transport layer before processing.
- Run `swift build -c release` to catch availability or concurrency issues before tagging.

## Communication & Notes
- Respond in the user's language; keep code comments and examples in English.

## Documentation
- `docs/`: Official, complete documentation for users and developers.
- `Notes/`: Development notes and design documents; may contain outdated or incorrect information.
- `Notes/plans/`: Implementation plans and technical memos for specific features or refactors. AI agents should store their task-specific plans here.

### Bilingual Documentation
- **README**: `README.md` (English, default) and `README.zh-TW.md` (Traditional Chinese)
- **Documentation files**: English versions use original filenames (e.g., `docs/index.md`), Chinese versions use `.zh-TW.md` suffix (e.g., `docs/index.zh-TW.md`)
- **When modifying documentation**: Always check and update both language versions to keep them in sync
  - If adding new content, translate it to both languages
  - If updating existing content, ensure both versions reflect the same changes
  - If fixing errors, apply fixes to both language versions
- **Language switching**: Each documentation file should include language switching links at the top (e.g., `[English](file.md) | [中文版](file.zh-TW.md)`)
- **Internal links**: 
  - English files should link to other English files (`.md`)
  - Chinese files should link to other Chinese files (`.zh-TW.md`)

## Code Comments & Documentation
- **All code comments must be in English** (including `///` documentation comments and `//` inline comments)
- This applies to all source files in `Sources/` directory
- Documentation comments should follow Swift API Design Guidelines
- Use clear, concise English for all code annotations

## Debugging & Troubleshooting

When encountering bugs, test failures, or unexpected behavior, refer to the comprehensive debugging guide:

**📖 See: `Notes/guides/DEBUGGING_TECHNIQUES.md`** for detailed debugging techniques, Swift build system reference, and common debug patterns.

### Quick Reference

**When debugging gets stuck:**
1. **Refer to the guide**: `Notes/guides/DEBUGGING_TECHNIQUES.md` contains:
   - Code search techniques (`codebase_search`, `grep`, pattern matching)
   - Data flow verification methods
   - Incremental testing strategies
   - Swift build system reference (`-c release`, build configurations)
   - Common debug patterns and solutions
   - Real-world examples from this project

2. **Use systematic debugging skill**: `.agent/skills/Superpowers/systematic-debugging/` for structured approach

3. **Check platform differences**: macOS vs Linux (tools, Swift runtime bugs, etc.)

4. **Test in both modes**: Always test in both `debug` and `release` builds (`swift build -c release`)

**Swift Build System Quick Reference:**
- `swift build`: Debug build (default)
- `swift build -c release`: Release build (optimized, for production/benchmarks)
- `swift run -c release ServerLoadTest`: Run with release configuration
- `swift test -c release`: Run tests in release mode
- **Important**: Release builds can expose bugs not visible in debug (e.g., Swift Concurrency runtime bugs on macOS)
