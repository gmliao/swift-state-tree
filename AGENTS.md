# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library (Land DSL, Runtime, Sync, StateTree).
- `Sources/SwiftStateTreeTransport`: transport abstraction layer (WebSocket, Land management, routing).
- `Sources/SwiftStateTreeHummingbird`: Hummingbird integration (LandHost, LandServer, WebSocket adapter).
- `Sources/SwiftStateTreeMatchmaking`: matchmaking service and lobby functionality.
- `Sources/SwiftStateTreeMacros`: compile-time macros (`@StateNodeBuilder`, `@Payload`, `@SnapshotConvertible`).
- `Sources/SwiftStateTreeDeterministicMath`: deterministic math library for server-authoritative games.
  - `Core/`: Fixed-point arithmetic (`FixedPoint`), integer vectors (`IVec2`, `IVec3`) with SIMD optimization.
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

## Commit & Pull Request Guidelines
- Messages: short imperative summaries (`Add room snapshot hook`, `Fix attack damage clamp`).
- PRs: describe intent, note new APIs, list test coverage (`swift test` output), and include manual steps for demo changes.
- Keep changes scoped; separate library additions from demo tweaks when possible.

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
