# Matchmaking Control Plane

NestJS-based matchmaking control plane MVP for SwiftStateTree game servers.

## Features

- In-memory queue storage with group deduplication
- **Continuous periodic matchmaking**: Background loop runs every N seconds; tickets wait at least M seconds before being matched
- Gateway-facing REST API: enqueue, cancel, status
- JWT issuance (RS256) and JWKS endpoint for game server token validation
- Provisioning client integration for Land assignment

## Quick Start

```bash
# Install dependencies
npm install

# Run tests
npm test
npm run test:e2e -- --runInBand

# Start server (default port 3000)
PROVISIONING_BASE_URL=http://127.0.0.1:9101 npm run start:dev
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /health | Health check |
| POST | /v1/matchmaking/enqueue | Enqueue a match group |
| POST | /v1/matchmaking/cancel | Cancel a ticket |
| GET | /v1/matchmaking/status/:ticketId | Get ticket status |
| GET | /.well-known/jwks.json | JWKS for token validation |
| GET | /api | **Swagger UI** (OpenAPI documentation) |

## Environment Variables

- `PORT`: Server port (default: 3000)
- `PROVISIONING_BASE_URL`: Base URL for provisioning API (default: http://127.0.0.1:9101)
- `MATCHMAKING_INTERVAL_MS`: How often the matchmaking loop runs (default: 3000)
- `MATCHMAKING_MIN_WAIT_MS`: Minimum time a ticket must wait in queue before it can be matched (default: 3000)

## Matchmaking Flow

1. Client calls `POST /v1/matchmaking/enqueue` → receives `ticketId` and `status: "queued"`
2. Client polls `GET /v1/matchmaking/status/:ticketId` until `status` becomes `"assigned"`
3. When assigned, the response includes `assignment` with `connectUrl`, `matchToken`, etc.

## MVP Constraints

- **InMemory only**: Queue state is stored in memory. Restart clears all in-flight state.
- **No automatic reassignment**: Failed assignments are not retried. Client must retry through Gateway.
- **Development mode**: `ALLOW_CLIENT_PLAYER_ID` (Mode A) for development; production should use Gateway-issued identity (Mode B).
