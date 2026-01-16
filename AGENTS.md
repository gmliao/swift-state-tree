# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library (Land DSL, Runtime, Sync, StateTree).
- `Sources/SwiftStateTreeTransport`: transport abstraction layer (WebSocket, Land management, routing).
- `Sources/SwiftStateTreeHummingbird`: Hummingbird integration (LandHost, LandServer, WebSocket adapter).
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
- `Examples/HummingbirdDemo`: demo project with unified `DemoServer` and web client.
- `Tests/SwiftStateTreeTests`: unit tests for the library.

## Build, Test, and Development Commands
- `swift build`: compile all targets; use `-c release` for performance checks.
- `swift test`: run all library tests; use `swift test --filter StateTreeTests.testGetSyncFields` for a single case.
- `swift test list`: list all available tests.
- `swift run DemoServer`: start the unified demo server (from `Examples/HummingbirdDemo`).
- `swift package resolve`: refresh dependencies if `Package.resolved` drifts.

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
- **Test modules**: `SwiftStateTreeTests` (core), `SwiftStateTreeTransportTests` (transport), `SwiftStateTreeHummingbirdTests` (Hummingbird), `SwiftStateTreeMacrosTests` (macros), `SwiftStateTreeMatchmakingTests` (matchmaking), `SwiftStateTreeDeterministicMathTests` (deterministic math).
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
  1. Start server: `swift run DemoServer`.
  2. Run suite: `cd Tools/CLI && npm test`.
  3. AI must ensure all encoding modes (`jsonObject`, `opcodeJsonArray`) pass before submitting PRs.
  4. **Proactive Testing**: AI agents are encouraged to create new JSON scenarios in `Tools/CLI/scenarios/` to verify specific features or bug fixes. These scenarios should use the `assert` step to ensure correctness.

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
