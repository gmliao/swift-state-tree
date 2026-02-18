# Matchmaking Control Plane MVP Runbook

## Overview

The Matchmaking Control Plane MVP provides queue management, assignment lifecycle, and JWT issuance for game server connections. **Provisioning is built-in** (in-memory server registry). Game servers register via `POST /v1/provisioning/servers/register`.

## Prerequisites

- Node.js 18+
- pnpm or npm

## Local Run

### 1. Start Control Plane

```bash
cd Packages/control-plane
npm install
npm run start:dev
```

Server runs on port 3000 (or `PORT` env). Provisioning (server registry) is built-in.

### 2. Register a Game Server (for matchmaking to work)

Game servers call `POST /v1/provisioning/servers/register` on startup. For manual testing:

```bash
curl -X POST http://localhost:3000/v1/provisioning/servers/register \
  -H "Content-Type: application/json" \
  -d '{"serverId":"game-1","host":"127.0.0.1","port":8080,"landType":"hero-defense"}'
```

### 3. Verify Endpoints

```bash
# Health
curl http://localhost:3000/health

# Enqueue (returns queued; poll status until assigned)
curl -X POST http://localhost:3000/v1/matchmaking/enqueue \
  -H "Content-Type: application/json" \
  -d '{"groupId":"test-1","queueKey":"standard:asia","members":["p1"],"groupSize":1}'

# Poll status (use ticketId from enqueue response)
curl http://localhost:3000/v1/matchmaking/status/<ticketId>

# JWKS
curl http://localhost:3000/.well-known/jwks.json
```

**Note:** Matchmaking runs periodically (default: every 3 seconds). Tickets must wait at least `MATCHMAKING_MIN_WAIT_MS` (default: 3000) before being matched. Configure via `MATCHMAKING_INTERVAL_MS` and `MATCHMAKING_MIN_WAIT_MS` if needed.

## Test Suite

```bash
cd Packages/control-plane
npm test                    # Unit tests
npm run test:e2e            # E2E tests (uses internal provisioning registry)
```

## MVP Constraints

- **InMemory storage**: Queue state is lost on restart. No persistence.
- **InMemory provisioning**: Server registry is in-memory. Game servers must register on startup.
- **No automatic reassignment**: If assignment fails, client must retry via Gateway.
- **Single-instance**: No distributed coordination; scale by running multiple instances with separate provisioning backends.
