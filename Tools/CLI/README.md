# SwiftStateTree CLI

TypeScript CLI tool for testing SwiftStateTree WebSocket connections.

## Installation

```bash
cd Tools/CLI
npm install
npm run build
```

**Note**: The CLI uses `tsx` for development, so you can run commands directly with `npm run dev` without building first.

## Usage

### Fetch Schema

Get the protocol schema from the server:

```bash
npm run dev schema -u http://localhost:8080
```

This will display:
- Schema version
- Available lands
- Actions, Client Events, and Server Events for each land
- Type definitions

### Connect and Join

```bash
# Basic connection
npm run dev connect -u ws://localhost:8080/game -l demo-game

# With player ID and metadata
npm run dev connect -u ws://localhost:8080/game -l demo-game -p player-123 -m '{"platform":"CLI"}'

# With JWT token
npm run dev connect -u ws://localhost:8080/game -l demo-game -t "your-jwt-token"
```

### Execute Script

Create a script file (JSON format):

```json
{
  "steps": [
    {
      "type": "log",
      "message": "Starting test script"
    },
    {
      "type": "action",
      "action": "AddGold",
      "payload": {
        "amount": 100
      }
    },
    {
      "type": "wait",
      "wait": 1000
    },
    {
      "type": "event",
      "event": "ChatEvent",
      "payload": {
        "message": "Hello from CLI!"
      }
    },
    {
      "type": "state",
      "message": "Final state"
    }
  ]
}
```

Execute the script:

```bash
npm run dev script -u ws://localhost:8080/game -l demo-game -s script.json
```

## Script Format

Script files are JSON with a `steps` array. Each step can be:

- **`action`**: Send an action
  ```json
  {
    "type": "action",
    "action": "ActionType",
    "payload": { ... }
  }
  ```

- **`event`**: Send an event
  ```json
  {
    "type": "event",
    "event": "EventType",
    "payload": { ... }
  }
  ```

- **`wait`**: Wait for specified milliseconds
  ```json
  {
    "type": "wait",
    "wait": 1000
  }
  ```

- **`log`**: Print a log message
  ```json
  {
    "type": "log",
    "message": "Custom log message"
  }
  ```

- **`state`**: Print current state
  ```json
  {
    "type": "state"
  }
  ```

- **`action` with error expectations**: Test error handling
  ```json
  {
    "type": "action",
    "action": "ActionType",
    "payload": { ... },
    "expectError": true,
    "errorCode": "ERROR_CODE",
    "errorMessage": "partial error message"
  }
  ```
  
  When `expectError: true`, the CLI expects the action to fail:
  - If action succeeds, script execution will throw an error
  - If action fails but error doesn't match `errorCode` or `errorMessage` (if provided), script execution will throw an error
  - If action fails and matches expectations, script continues normally
  - If `errorCode` or `errorMessage` are omitted, any error is considered acceptable

## Examples

### Example Script: Test Game Actions

```json
{
  "steps": [
    {
      "type": "log",
      "message": "Testing game actions"
    },
    {
      "type": "action",
      "action": "AddGold",
      "payload": {
        "amount": 100
      }
    },
    {
      "type": "wait",
      "wait": 500
    },
    {
      "type": "action",
      "action": "SpendGold",
      "payload": {
        "amount": 50
      }
    },
    {
      "type": "wait",
      "wait": 500
    },
    {
      "type": "state"
    }
  ]
}
```

### Example Script: Test Events

```json
{
  "steps": [
    {
      "type": "log",
      "message": "Testing events"
    },
    {
      "type": "event",
      "event": "ChatEvent",
      "payload": {
        "message": "Hello!"
      }
    },
    {
      "type": "wait",
      "wait": 1000
    },
    {
      "type": "event",
      "event": "PingEvent",
      "payload": {}
    }
  ]
}
```

## Commands

### `schema`
Fetch and display the protocol schema from the server.

```bash
npm run dev schema -u http://localhost:8080
```

Options:
- `-u, --url <url>`: Server URL (required, can be http:// or ws://)

### `connect`
Connect to a SwiftStateTree server and optionally execute a script.

```bash
npm run dev connect -u ws://localhost:8080/game -l demo-game
```

Options:
- `-u, --url <url>`: WebSocket URL (required)
- `-l, --land <landID>`: Land ID to join (required)
- `-p, --player <playerID>`: Player ID (optional)
- `-d, --device <deviceID>`: Device ID (optional)
- `-m, --metadata <json>`: Metadata as JSON string (optional)
- `-t, --token <token>`: JWT token for authentication (optional)
- `-s, --script <file>`: Script file to execute (optional)
- `--once`: Exit immediately after successful connection and join (non-interactive mode)
- `--timeout <seconds>`: Auto-exit timeout in seconds after script completion (default: 10)

### `script`
Execute a test script against a server.

```bash
npm run dev script -u ws://localhost:8080/game -l demo-game -s examples/test-game.json
```

Options:
- `-u, --url <url>`: WebSocket URL (required)
- `-l, --land <landID>`: Land ID to join (required)
- `-s, --script <file>`: Script file to execute (required)
- `-p, --player <playerID>`: Player ID (optional)
- `-d, --device <deviceID>`: Device ID (optional)
- `-m, --metadata <json>`: Metadata as JSON string (optional)
- `-t, --token <token>`: JWT token for authentication (optional)

## Testing Notes

### Starting the Server

Before testing with CLI, make sure the Hummingbird demo server is running:

```bash
# From project root
swift run HummingbirdDemo
```

The server typically runs on `http://localhost:8080` with WebSocket endpoint at `ws://localhost:8080/game`.

### Common Test Scenarios

1. **Test successful actions**: Use normal `action` steps without `expectError`
2. **Test error handling**: Use `expectError: true` to verify error responses
3. **Test state changes**: Use `wait` steps between actions to allow state updates, then use `state` step to verify
4. **Test events**: Use `event` steps to send client events to the server

### Debugging Tips

- Use `log` steps to add markers in your test output
- Increase `wait` times if state updates are not appearing
- Check server logs if actions are not working as expected
- Use `schema` command to verify available actions and events

## Error Handling Behavior

### Script Execution Errors

When executing scripts with `expectError: true`:

1. **Expected Errors** (`expectError: true`):
   - ✅ If the action fails as expected and matches error criteria, script continues normally
   - ❌ If the action succeeds when it should fail, script execution throws an error (this is a test failure)
   - ⚠️ If the action fails but doesn't match expected error code/message, a warning is shown but **script continues execution**
   - This allows testing multiple error cases even if some error formats don't exactly match expectations

2. **Unexpected Errors**:
   - If an action fails unexpectedly (without `expectError: true`), the error is logged but script execution continues
   - This allows testing multiple actions even if some fail

3. **Join Errors**:
   - Join errors (e.g., `JOIN_DENIED`, `JOIN_ROOM_FULL`) are automatically handled
   - If join fails, the CLI will exit with an error message
   - Join errors are properly routed to the view and will not cause the script to hang

4. **Script Completion & Timeout**:
   - After script execution (successful or with errors), CLI waits for a timeout period (default 10 seconds) to receive final responses
   - **The countdown timer always runs regardless of script errors**, unless the process is manually interrupted (Ctrl+C)
   - This ensures you can see all server responses even when testing error cases
   - You can customize the timeout with `--timeout <seconds>` in the `connect` command

### Error Routing

The CLI uses the TypeScript SDK which automatically routes errors to the correct view:
- Errors with `landID` in details are routed to the specific view
- Errors with `requestID` are matched to pending action/join callbacks
- If routing fails, errors are broadcast to all views as a fallback
- This ensures errors are always handled and don't cause the script to hang

### Example: Testing Error Cases

```json
{
  "steps": [
    {
      "type": "action",
      "action": "NonExistentAction",
      "payload": {},
      "expectError": true,
      "errorCode": "ACTION_NOT_REGISTERED"
    },
    {
      "type": "wait",
      "wait": 500
    },
    {
      "type": "action",
      "action": "AddGold",
      "payload": {
        "invalidField": "test"
      },
      "expectError": true
    }
  ]
}
```

In this example:
- First action is expected to fail with `ACTION_NOT_REGISTERED` error code
- Second action is expected to fail (any error is acceptable)
- Script will continue to completion and wait for timeout even if errors occur

