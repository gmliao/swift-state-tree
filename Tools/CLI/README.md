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

# Run E2E scenarios in default mode
npm run test:e2e

# Run E2E scenarios across all encoding modes (jsonObject, opcodeJsonArray)
npm run test:e2e:all
```

**Note**: `npm test` uses a Fail-Fast strategy. If any protocol test fails, E2E tests will not run.

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
