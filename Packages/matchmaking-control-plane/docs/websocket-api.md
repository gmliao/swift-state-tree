# WebSocket Realtime API

## Endpoint

- Direct: `ws://<host>:<port>/realtime?ticketId=<ticketId>`
- Via LB (nginx): `wss://<lb-host>/match/realtime?ticketId=<ticketId>` (see `docs/deploy/nginx-matchmaking-e2e.docker.conf`)

Connect with the ticketId returned from `POST /v1/matchmaking/enqueue`.

## Envelope Format

All server-pushed messages use:

```json
{
  "type": "match.assigned",
  "v": 1,
  "data": {
    "ticketId": "ticket-1",
    "assignment": {
      "assignmentId": "...",
      "matchToken": "...",
      "connectUrl": "ws://...",
      "landId": "...",
      "serverId": "...",
      "expiresAt": "..."
    }
  }
}
```

## Events

- `match.assigned` (v1): Sent when the ticket is matched and assigned. Client should connect to `data.assignment.connectUrl` with `?token=data.assignment.matchToken`.
