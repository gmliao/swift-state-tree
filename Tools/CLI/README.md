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

## Directory Index

### `scenarios/` (E2E Test Cases organized by Land)
- `scenarios/counter/`: Tests for the Counter demo (requires DemoServer).
- `scenarios/cookie/`: Tests for the Cookie Clicker game (requires DemoServer).
- `scenarios/game/`: Tests for the Hero Defense game (requires GameServer).
- `scenarios/load/`: Convergence load variant (`burst` steps from every client); run with `--clients` / `--rooms`, not as part of `scenarios/game/`.
  In a tick land a burst only queues, so a check right after it compares the pre-burst state
  (labels `burst-N-immediate`, bursts 1 and 3); bursts 2, 4 and 5 wait 250 ms (several ticks and
  sync periods) first and compare a state that contains the burst (`burst-N-after-ticks`).
- `scenarios/fault/`: Negative tests run with fault injection (e.g. `--fault-drop-patch`); not run as a directory.
  `test-e2e-ci.sh` drops a Demo counter `/count` patch (messagepack); `test-e2e-game.sh` drops the
  hero-defense `/score` patch (json, tick land, broadcast field). Both must fail with the path.
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
npm run test:e2e:game:ci  # Game demo tests with CI script (automatically starts/stops GameServer, tests all encoding modes)

# Matchmaking E2E (control plane + GameServer)
npm run test:e2e:game:matchmaking:full   # Control plane + GameServer, single client
npm run test:e2e:game:matchmaking:nginx  # + nginx LB, single client + two-player same-game (requires Docker)
npm run test:e2e:game:matchmaking:two-players  # Two players in same game (requires stack already running)
```

**Note**: 
- `npm test` uses a Fail-Fast strategy. If any protocol test fails, E2E tests will not run.
- Default E2E tests (`npm run test:e2e`) only test DemoServer lands (counter, cookie). Game tests require GameServer to be running separately.
- To test all lands including game: `npm run test:e2e:with-game` (requires both DemoServer and GameServer running).
- **GameServer CI Testing**: Use `npm run test:e2e:game:ci` to automatically start GameServer, run tests across all encoding modes, and clean up. This is equivalent to running `./test-e2e-game.sh`.
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
- **`waitForState`**: Wait for a state condition to be met (with timeout).
  - `path`: Dot-notation path to state field (e.g., `players.0.name`).
  - `equals`: Expected value (optional).
  - `exists`: boolean (optional).
  - `timeout`: Maximum wait time in milliseconds (default: 3000ms).
  - `interval`: Polling interval in milliseconds (default: 100ms).
  - `message`: Error message if condition is not met (optional).
- **`assert`**: Validate current state.
  - `path`: Dot-notation path to state field (e.g., `players.0.name`).
  - `equals`: Expected value.
  - `exists`: boolean (optional)
- **`waitForEvent`**: Wait until a server event has arrived (counted from the scenario start).
  - `event`: Server event type (e.g., `PlayerShoot`).
  - `minCount`: Number of events to wait for (default: 1).
  - `timeout`: Maximum wait time in milliseconds (default: 5000ms).
  - `message`: Error message if the events do not arrive (optional).
- **`assertConverged`**: Check that every client's state equals the server's state.
  - Freezes the land through the admin debug routes, waits until no client receives a patch
    for `quietMs` (default 200, bounded by `settleTimeoutMs`, default 3000), compares each
    client's state with the server projection for its player, then resumes with the freeze
    token (also when the check fails).
  - Comparison: SDK math types compare as raw fixed-point integers (the state-wire shape),
    `null` and an absent key are equal, key order is ignored, 64-bit integers compare as numbers
    while they are exact (|n| <= 2^53 - 1); a larger integer is always reported as a difference.
  - Mismatches print `CONVERGENCE MISMATCH (report-only)` with the first `maxPaths` (default 10)
    differing paths and do not fail the script, unless `--convergence-gating` (or
    `E2E_CONVERGENCE_GATING=true`) is set. A join or leave during the freeze prints
    `CONVERGENCE INCONCLUSIVE (membership changed)`. Route, auth, timeout and projection
    errors always fail the script; a resume failure is logged next to an earlier error instead of
    replacing it, and `resumed=false` (freeze already released) is logged as a warning. The run
    ends with a `CONVERGENCE SUMMARY` line.
  - Requires the server to run with `ENABLE_DEBUG_STATE_ROUTES=true` and an admin key, and the
    CLI to get the key from `--admin-key` or `E2E_ADMIN_KEY` (`--admin-url` defaults to the
    WebSocket host). `test-e2e-ci.sh` and `test-e2e-game.sh` set both.
  - `label`: Name printed with the result (optional).
- **`burst`**: Send `steps` back-to-back for `rounds` rounds without waiting between them,
  then wait for all action responses (load variant).
  - `steps`: list of `{ "action": ..., "payload": ... }` or `{ "event": ..., "payload": ... }`.
  - `rounds`: number of rounds (default 1).
  - `allClients`: send from every client of the land (default: client 0 only).
- **`state`**: Print full current state to console.
- **`log`**: Print a message.

### `script` options for convergence checks

- `--clients <n>`: join `n` clients to each scenario's land. Steps send from client 0;
  `assertConverged` freezes once and checks every client before one resume.
- `--rooms <n>`: run each scenario in `n` lands in parallel, each with `--clients` clients.
  Load variant against GameServer: `npm run test:e2e:game:convergence-load`
  (`E2E_LOAD_CLIENTS` / `E2E_LOAD_ROOMS`, default 4 x 4), or `E2E_CONVERGENCE_LOAD=true
  ./test-e2e-game.sh` to add it to every encoding pass. Mismatches stay report-only.
- `--fault-drop-patch <pathPrefix>`: client 0 drops the next diff patch under the prefix
  (negative test for `assertConverged`).

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
