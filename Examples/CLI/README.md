# SwiftStateTree CLI

TypeScript CLI tool for testing SwiftStateTree WebSocket connections.

## Installation

```bash
cd Examples/CLI
npm install
npm run build
```

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

