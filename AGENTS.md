# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library (Land DSL, Runtime, Sync, StateTree).
- `Sources/SwiftStateTreeTransport`: transport abstraction layer (WebSocket, Land management, routing).
- `Sources/SwiftStateTreeHummingbird`: Hummingbird integration (LandHost, LandServer, WebSocket adapter).
- `Sources/SwiftStateTreeMatchmaking`: matchmaking service and lobby functionality.
- `Sources/SwiftStateTreeMacros`: compile-time macros (`@StateNodeBuilder`, `@Payload`, `@SnapshotConvertible`).
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
- **Test modules**: `SwiftStateTreeTests` (core), `SwiftStateTreeTransportTests` (transport), `SwiftStateTreeHummingbirdTests` (Hummingbird), `SwiftStateTreeMacrosTests` (macros), `SwiftStateTreeMatchmakingTests` (matchmaking).
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

## Code Comments & Documentation
- **All code comments must be in English** (including `///` documentation comments and `//` inline comments)
- This applies to all source files in `Sources/` directory
- Documentation comments should follow Swift API Design Guidelines
- Use clear, concise English for all code annotations
