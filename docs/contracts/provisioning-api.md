# Provisioning API Contract

Canonical contract for the Land Provisioning API. Provisioning is built into the NestJS Matchmaking Control Plane. Game servers register via REST; allocate is internal.

## Response Envelope

All provisioning endpoints return a standard JSON envelope:

```json
{
  "success": true,
  "result": {}
}
```

On error:

```json
{
  "success": false,
  "error": {
    "code": "PROVISIONING_ERROR",
    "message": "Human-readable message",
    "retryable": false
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| success | boolean | Yes | Whether the operation succeeded |
| result | object | No | Response payload (omit when empty) |
| error | object | No | Present when success is false |
| error.code | string | Yes | Error code |
| error.message | string | Yes | Human-readable message |
| error.retryable | boolean | No | Whether client should retry |

---

## POST /v1/provisioning/servers/register

Game servers call this on startup and periodically (heartbeat) to register with the control plane. Same endpoint for initial register and heartbeat; each call updates `lastSeenAt`.

### Request

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| serverId | string | Yes | Server identifier (e.g., "game-1") |
| host | string | Yes | Host the server binds to |
| port | number | Yes | Port the server binds to |
| landType | string | Yes | Land type (e.g., "hero-defense") |
| connectHost | string | No | Client-facing host for connectUrl. Use when behind K8s Ingress, nginx LB, etc. When omitted, host is used. |
| connectPort | number | No | Client-facing port. When omitted, port is used. |
| connectScheme | string | No | WebSocket scheme: "ws" or "wss". Default: "wss" when connectPort is 443, else "ws". |

### Response

- **200 OK** with `{ "success": true }` on success.

### Heartbeat

- Call every 30 seconds (recommended). Control plane TTL is 90 seconds; servers without heartbeat within TTL are excluded from allocate.

---

## DELETE /v1/provisioning/servers/:serverId

Game servers call this on shutdown to deregister from the control plane.

### Response

- **200 OK** with `{ "success": true }` on success.

---

## Allocate (Internal to Control Plane)

The allocate operation is internal. MatchmakingService calls InMemoryProvisioningClient, which uses the server registry. No external HTTP endpoint.

### Allocate Request (internal)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| queueKey | string | Yes | Queue identifier (e.g., "standard:asia") |
| groupId | string | Yes | Match group identifier |
| groupSize | number | Yes | Number of players in group |
| region | string | No | Preferred region |
| constraints | object | No | Additional matching constraints |

### Allocate Response

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| serverId | string | Yes | Assigned server identifier |
| landId | string | Yes | Land instance ID (e.g., "hero-defense:room-1") |
| connectUrl | string | Yes | WebSocket URL for client connection |
| expiresAt | string | No | ISO8601 timestamp when assignment expires |
| assignmentHints | object | No | Additional metadata for client |

### Error Response

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| code | string | Yes | Error code (e.g., "PROVISIONING_FAILED") |
| message | string | Yes | Human-readable message |
| retryable | boolean | Yes | Whether client should retry |
