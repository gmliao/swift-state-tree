# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftStateTree`: core library with game logic; key folders `GameCore` (state, commands, actors) and `StateTree` (tree engine, nodes).
- `Sources/SwiftStateTreeVaporDemo`: Vapor-based demo server (`main.swift`, `Configure.swift`, `Routes.swift`).
- `Tests/SwiftStateTreeTests`: unit tests for the library.
- `Package.swift`: SwiftPM manifest; defines products `SwiftStateTree` (library) and `SwiftStateTreeVaporDemo` (executable).

## Build, Test, and Development Commands
- `swift build`: compile all targets; use `-c release` for performance checks.
- `swift test`: run library tests; use `swift test --filter SwiftStateTreeTests.testJoinAndAttack` for a single case.
- `swift run SwiftStateTreeVaporDemo`: start the demo server at `http://localhost:8080`.
- `swift package resolve`: refresh dependencies if `Package.resolved` drifts.

## Coding Style & Naming Conventions
- Swift 6, macOS 13+; follow Swift API Design Guidelines and prefer `Sendable` on public types.
- Indent with 4 spaces; keep line length reasonable (~120 chars).
- Types: `UpperCamelCase`; methods/variables: `lowerCamelCase`; enums use verb-like cases for commands (`.join`, `.attack`).
- Place new game logic in `Sources/SwiftStateTree/GameCore`; keep demo-only code inside `SwiftStateTreeVaporDemo`.

## Testing Guidelines
- Framework: SwiftPM XCTest.
- Add tests under `Tests/SwiftStateTreeTests`, mirroring the type under test (e.g., `GameStateTests.swift`).
- Name async tests with clear intent (`testPlayerJoinCreatesSnapshot`); prefer arranging with setup/act/assert comments when logic grows.
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
