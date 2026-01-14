# Hero Defense CLI Client

A command-line interface client for the Hero Defense game. Uses the same SDK logic as the WebClient, but provides a text-based interface for playing the game.

## Setup

1. Install dependencies:
```bash
cd Examples/GameDemo/CliClient
npm install
```

2. Generate schema and codegen:
```bash
npm run generate
```

## Usage

### Development Mode
```bash
npm run dev [wsUrl] [playerName] [roomId]
```

### Production Mode
```bash
npm run build
npm start [wsUrl] [playerName] [roomId]
```

### Examples
```bash
# Connect to default server with auto-generated player name
npm run dev

# Connect to specific server with custom player name
npm run dev ws://localhost:8080/game/hero-defense myplayer

# Connect to specific room
npm run dev ws://localhost:8080/game/hero-defense myplayer room-123
```

## Commands

### Interactive CLI Commands
- `help` / `h` - Show help message
- `connect` / `c` - Connect to game server
- `disconnect` / `d` - Disconnect from server
- `play` / `p` - Start the game
- `move <x> <y>` / `m <x> <y>` - Move player to position
- `shoot <x> <y>` / `s <x> <y>` - Shoot at position
- `place <x> <y>` / `t <x> <y>` - Place turret at position
- `upgrade-weapon` / `uw` - Upgrade weapon (costs 5 resources)
- `upgrade-turret` / `ut` - Upgrade turret (costs 10 resources)
- `status` / `st` - Show game status
- `players` / `pl` - List all players
- `monsters` / `mo` - List all monsters
- `turrets` / `tu` - List all turrets
- `quit` / `q` / `exit` - Exit the program

### Automated Test Commands
- `npm run test` - Run automated tests (quiet mode, 5 seconds)
- `npm run test:normal` - Run tests in normal mode (show important events)
- `npm run test:verbose` - Run tests in verbose mode (show all logs)

Test modes:
- `quiet` (default) - Only show errors and final summary
- `normal` - Show errors, warnings, and important events
- `verbose` - Show all logs including debug info

Usage:
```bash
npm run test [wsUrl] [playerName] [roomId] [--mode=quiet|normal|verbose]
```

## Game Flow

1. The client automatically connects on startup
2. Use `play` command to start the game
3. Use `move`, `shoot`, `place` commands to interact with the game
4. Use `status` to check your resources and game state
5. Use `upgrade-weapon` and `upgrade-turret` to improve your capabilities

## Notes

- The CLI client uses the same SDK (`@swiftstatetree/sdk`) as the WebClient
- It automatically uses Node.js WebSocket implementation (`websocket-node.ts`)
- All game logic and state management is handled by the SDK
- The CLI provides a simple text interface for testing and playing the game
