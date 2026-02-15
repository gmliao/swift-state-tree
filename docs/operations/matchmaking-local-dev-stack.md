# Matchmaking Local Development Stack

Scripts for running the full matchmaking stack locally. Provisioning is built into the control plane (NestJS). GameServer registers via REST when `PROVISIONING_BASE_URL` is set.

## Scripts

- `Tools/CLI/scripts/internal/run-matchmaking-local-stack.sh` - Start all services (background)
- `Tools/CLI/scripts/internal/run-matchmaking-full-with-test.sh` - Start all + run E2E in one command

## Prerequisites

- Node.js 18+
- Swift 6+
- Control plane built: `cd Packages/matchmaking-control-plane && npm run build`

## Usage

### Start stack (blocking)

```bash
cd Tools/CLI
bash scripts/internal/run-matchmaking-local-stack.sh
```

This starts control plane first, then GameServer (with provisioning). Press Ctrl+C to stop.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| MATCHMAKING_CONTROL_PLANE_PORT | 3000 | Control plane HTTP port (includes provisioning) |
| SERVER_PORT | 8080 | GameServer port |
| E2E_TMP_DIR | $PROJECT_ROOT/tmp/e2e | Log and PID files |

### Run MVP E2E after stack is up

```bash
cd Tools/CLI
MATCHMAKING_CONTROL_PLANE_URL=http://127.0.0.1:3000 npm run test:e2e:game:matchmaking:mvp
```

### One-command: start all servers + run E2E

```bash
cd Tools/CLI
npm run test:e2e:game:matchmaking:full
```

Starts control plane first, then GameServer (with provisioning), waits for health, runs the MVP E2E test, then exits (kills all servers).
