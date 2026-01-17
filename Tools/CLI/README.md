# SwiftStateTree CLI & E2E Testing Tool

A powerful TypeScript CLI for testing, benchmarking, and end-to-end (E2E) validation of SwiftStateTree connections.

## Directory Structure

- `src/`: Core CLI source code.
- `scenarios/`: JSON-based E2E test scenarios.
- `benchmarks/`: Performance benchmarks and protocol measurement scripts.
- `scripts/internal/`: Low-level protocol validation and developer integration tests.

## Installation

```bash
cd Tools/CLI
npm install
npm run build
```

<<<<<<< HEAD
## Directory Index

### `scenarios/` (E2E Test Cases organized by Land)
- `scenarios/counter/`: Tests for the Counter demo (requires DemoServer).
- `scenarios/cookie/`: Tests for the Cookie Clicker game (requires DemoServer).
- `scenarios/game/`: Tests for the Hero Defense game (requires GameServer).
- `scenarios/internal/`: Internal protocol and compression validation scenarios.

**AI Agents Tip**: When adding tests for a new project or Land, create a corresponding subdirectory under `scenarios/`. You can use your own created scenarios to verify new logic or bug fixes before submitting a PR.

---

## Unified Testing

The CLI provides a unified testing suite that covers both low-level protocol and high-level E2E scenarios across all encoding modes.
### Run All Tests
```bash
# Run all tests (Protocol + E2E Matrix)
npm test
```

### Run Single Scenario or Directory
```bash
# Run a specific scenario file
npm run dev -- script -u ws://localhost:8080/game -l demo-game -s scenarios/test-game.json

# Run all scenarios in a directory
npm run dev -- script -u ws://localhost:8080/game -l demo-game -s scenarios/
```

### Other Test Commands
```bash
# Run only low-level protocol tests
npm run test:protocol

# Run E2E scenarios in default mode (counter, cookie)
# Note: Game tests are excluded by default - use test:e2e:with-game to include them
npm run test:e2e

# Run E2E scenarios including game tests (requires GameServer running)
npm run test:e2e:with-game

# Run E2E scenarios across all encoding modes (jsonObject, opcodeJsonArray, messagepack)
# Note: Tests automatically start DemoServer with correct encoding via TRANSPORT_ENCODING env var
npm run test:e2e:all

# Run E2E tests with specific encoding mode
npm run test:e2e:jsonObject      # JSON object state updates (TRANSPORT_ENCODING=json)
npm run test:e2e:opcodeJsonArray # Opcode JSON array state updates (TRANSPORT_ENCODING=jsonOpcode)
npm run test:e2e:messagepack     # MessagePack binary encoding (TRANSPORT_ENCODING=messagepack)

# Run individual test suites
npm run test:e2e:counter  # Counter demo tests (requires DemoServer)
npm run test:e2e:cookie   # Cookie game tests (requires DemoServer)
npm run test:e2e:game     # Game demo tests (requires GameServer on ws://localhost:8080/game/hero-defense)
```

**Note**: 
- `npm test` uses a Fail-Fast strategy. If any protocol test fails, E2E tests will not run.
- Default E2E tests (`npm run test:e2e`) only test DemoServer lands (counter, cookie). Game tests require GameServer to be running separately.
- To test all lands including game: `npm run test:e2e:with-game` (requires both DemoServer and GameServer running).
- **Encoding Modes**: `test:e2e:all` automatically tests all three encoding modes by starting DemoServer with different `TRANSPORT_ENCODING` environment variables:
  - `json`: JSON messages + JSON object state updates
  - `jsonOpcode`: JSON messages + opcode JSON array state updates
  - `messagepack`: MessagePack binary encoding for both messages and state updates

### Running Tests
- **GitLab CI**: Use `gitlab-runner exec docker <job-name>` to run jobs locally
- **Jenkins**: Can run Jenkins locally or use `jenkinsfile-runner`
- **CircleCI**: Use `circleci local execute` to test workflows locally
- **Azure DevOps**: Use `azure-pipelines-task-lib` for local task testing
- **GitHub Actions**: Use `act` (as shown above) or custom scripts like `test-e2e-ci.sh`

## Scenario Format (JSON)

Test scenarios are defined in JSON files within the `scenarios/` directory.

### Example Scenario

```json
{
  "maxDuration": 30000,
  "steps": [
    {
      "type": "log",
      "message": "Testing cookie game"
    },
    {
      "type": "action",
      "action": "ClickAction",
      "payload": { "amount": 1 }
    },
    { "type": "wait", "wait": 500 },
    {
      "type": "assert",
      "path": "room.cookies",
      "equals": 1,
      "message": "Cookies should increment after click"
    }
  ]
}
```

### Supported Step Types

- **`action`**: Send a server action.
  - `expectError`: boolean (optional)
  - `errorCode`: string (optional)
- **`event`**: Send a client event.
- **`wait`**: Wait for N milliseconds.
- **`assert`**: Validate current state.
  - `path`: Dot-notation path to state field (e.g., `players.0.name`).
  - `equals`: Expected value.
  - `exists`: boolean (optional)
- **`state`**: Print full current state to console.
- **`log`**: Print a message.

## Benchmarking

Performance scripts are located in `benchmarks/`:

```bash
# Run sync benchmarks
bash benchmarks/run-transport-sync-benchmarks.sh

# Measure protocol overhead
npm run measure
```

## AI Agent Integration

This tool is designed to be used by AI agents for automated regression testing. Agents should follow the SOP defined in the root `AGENTS.md` file.
