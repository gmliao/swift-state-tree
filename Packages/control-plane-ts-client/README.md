# @swiftstatetree/control-plane-client

TypeScript client for the SwiftStateTree control plane: matchmaking (enqueue, cancel, status), optional admin APIs, and realtime WebSocket for match-assigned events.

## Installation

```bash
npm install @swiftstatetree/control-plane-client
```

For local development from the monorepo:

```bash
npm install ../control-plane-ts-client
```

## Basic usage

Create a client, enqueue for matchmaking, and poll or use the helper to wait for an assignment:

```ts
import { ControlPlaneClient, findMatch, type FindMatchOptions } from '@swiftstatetree/control-plane-client';

const client = new ControlPlaneClient('https://your-control-plane.example.com');

// Enqueue and get ticket
const { ticketId } = await client.enqueue({
  queueKey: 'hero-defense',
  members: [{ id: 'player-1', role: 'player' }],
  groupSize: 2,
});

// Optional: cancel or check status
// await client.cancel(ticketId);
// const status = await client.getStatus(ticketId);

// Wait for a match (enqueue + realtime in one)
const assignment = await findMatch(client, {
  queueKey: 'hero-defense',
  members: [{ id: 'player-1', role: 'player' }],
  groupSize: 2,
  timeoutMs: 30_000,
});

// Build game connection URL and connect
const url =
  assignment.connectUrl +
  (assignment.connectUrl.includes('?') ? '&' : '?') +
  'token=' +
  encodeURIComponent(assignment.matchToken);
// e.g. open WebSocket to url for your game
```

Use `FindMatchTimeoutError` to detect timeout when using `findMatch`:

```ts
import { findMatch, FindMatchTimeoutError } from '@swiftstatetree/control-plane-client';

try {
  const assignment = await findMatch(client, options);
  // use assignment
} catch (e) {
  if (e instanceof FindMatchTimeoutError) {
    // no match within timeout
  }
  throw e;
}
```

## Admin and realtime (optional)

- **Admin** (requires `adminApiKey` in client options): `getServers()`, `getQueueSummary()` for server list and queue summary.
- **RealtimeSocket**: `client.openRealtimeSocket(ticketId)` returns a `RealtimeSocket` that emits `match.assigned`; use this for custom polling/reconnect logic instead of `findMatch`.

## API and docs

- Control plane overview and REST API: [../control-plane/README.md](../control-plane/README.md)
- WebSocket realtime API: [../control-plane/docs/websocket-api.md](../control-plane/docs/websocket-api.md)
