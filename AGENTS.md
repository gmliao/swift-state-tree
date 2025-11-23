# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library with game logic; key folders `GameCore` (state, commands, actors) and `StateTree` (tree engine, nodes).
- `Sources/SwiftStateTreeVaporDemo`: Vapor-based demo server (`main.swift`, `Configure.swift`, `Routes.swift`).
- `Tests/SwiftStateTreeTests`: unit tests for the library.
- `Package.swift`: SwiftPM manifest; defines products `SwiftStateTree` (library) and `SwiftStateTreeVaporDemo` (executable).

## Build, Test, and Development Commands
- `swift build`: compile all targets; use `-c release` for performance checks.
- `swift test`: run library tests; use `swift test --filter StateTreeTests.testGetSyncFields` for a single case.
- `swift run SwiftStateTreeVaporDemo`: start the demo server at `http://localhost:8080`.
- `swift package resolve`: refresh dependencies if `Package.resolved` drifts.

## Coding Style & Naming Conventions
- Swift 6, macOS 13+; follow Swift API Design Guidelines and prefer `Sendable` on public types.
- Indent with 4 spaces; keep line length reasonable (~120 chars).
- Types: `UpperCamelCase`; methods/variables: `lowerCamelCase`; enums use verb-like cases for commands (`.join`, `.attack`).
- Place new game logic in `Sources/SwiftStateTree/GameCore`; keep demo-only code inside `SwiftStateTreeVaporDemo`.

## Testing Guidelines
- **Framework: Swift Testing** (Swift 6's new testing framework, not XCTest).
- Add tests under `Tests/SwiftStateTreeTests`, mirroring the type under test (e.g., `StateTreeTests.swift`).
- Use `@Test` attribute with descriptive names: `@Test("Description of what is being tested")`.
- Use `#expect()` for assertions instead of `XCTAssert*`.
- Use `Issue.record()` for test failures that should be reported.
- Name test functions with clear intent; prefer arranging with setup/act/assert comments when logic grows.
- Use Arrange‑Act‑Assert structure; keep test files suffixed with `*Tests.swift` matching the type under test.
- When adding public APIs or core game logic, add/refresh tests and run `swift test` before sending changes out.
- Aim to cover new public APIs and concurrency paths; avoid shared mutable state between tests.

## Commit & Pull Request Guidelines
- Messages: short imperative summaries (`Add room snapshot hook`, `Fix attack damage clamp`).
- PRs: describe intent, note new APIs, list test coverage (`swift test` output), and include manual steps for demo changes.
- Keep changes scoped; separate library additions from demo tweaks when possible.

## Security & Configuration Tips
- Demo server is for local use; avoid committing secrets or tokens.
- Validate inbound WebSocket payloads in `Routes.swift` before acting on them.
- Run `swift build -c release` to catch availability or concurrency issues before tagging.

## Communication & Notes
- 回覆問題請使用繁體中文；如需程式碼範例或註解，註解請保持英文。

## Code Comments & Documentation
- **All code comments must be in English** (including `///` documentation comments and `//` inline comments)
- This applies to all source files in `Sources/` directory
- Documentation comments should follow Swift API Design Guidelines
- Use clear, concise English for all code annotations
