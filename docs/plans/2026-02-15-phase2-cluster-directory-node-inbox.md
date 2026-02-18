# Phase 2: ClusterDirectory + Node Inbox Implementation Plan

> **Reference:** `Packages/control-plane/Notes/plans/package-split-evaluation.md` Phase 2

**Goal:** Enable multi-API horizontal scaling with userId-based routing. Add ClusterDirectory (userId→nodeId), Node Inbox (per-node Pub/Sub), and Gateway session registration. Match.assigned can use broadcast (current) or node inbox (routed).

**Architecture:**
- **ClusterDirectory**: Redis-based userId→nodeId mapping with TTL lease. Gateway registers on connect; heartbeat refreshes.
- **Node Inbox**: Each API subscribes to `cd:inbox:{nodeId}`. Matchmaking/Dispatch publishes to specific node instead of broadcast.
- **Gateway**: userId→sockets registry, registerSession on connect, heartbeat refresh.

**Coexistence:** Broadcast (matchmaking:assigned) and Node Inbox can coexist. TicketId subscription remains for backward compatibility; node inbox enables sendToUser, QueueStatus, and efficient multi-node routing.

---

## Prerequisites

- Phase 1 complete (pubsub, MatchAssignedChannel)
- Redis running
- `NODE_ID` env var for each API instance (or auto-generate UUID on startup)

---

## Task 1: ClusterDirectory module – interface and Redis impl

**Files:**
- Create: `Packages/control-plane/src/cluster-directory/cluster-directory.interface.ts`
- Create: `Packages/control-plane/src/cluster-directory/redis-cluster-directory.service.ts`
- Create: `Packages/control-plane/src/cluster-directory/cluster-directory.module.ts`

**Redis keys:**
- `cd:user:{userId}` → nodeId (string)
- `cd:lease:user:{userId}:{nodeId}` → TTL key for heartbeat refresh (optional; can use single key with EXPIRE)

**Interface:**
```ts
export interface ClusterDirectory {
  registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  getNodeId(userId: string): Promise<string | null>;
  unregisterSession(userId: string, nodeId: string): Promise<void>;
}
```

**Default TTL:** 8 seconds (align with design doc heartbeat). Heartbeat interval: 2–4 seconds.

**Step 1:** Create interface and Redis impl. Use `SET cd:user:{userId} {nodeId} EX {ttl}` for register; `EXPIRE` for refresh; `GET` for lookup; `DEL` on unregister (only if value matches nodeId).

**Step 2:** ClusterDirectoryModule provides `CLUSTER_DIRECTORY` token. Use Redis impl when Redis available; optional InMemory impl for tests.

**Step 3:** Run tests. Commit: `feat(cluster-directory): add ClusterDirectory interface and Redis impl`

---

## Task 2: Node Inbox channel

**Files:**
- Create: `Packages/control-plane/src/pubsub/node-inbox-channel.interface.ts`
- Create: `Packages/control-plane/src/pubsub/redis-node-inbox-channel.service.ts`
- Create: `Packages/control-plane/src/pubsub/inmemory-node-inbox-channel.service.ts`
- Update: `Packages/control-plane/src/pubsub/channels.ts`
- Update: `Packages/control-plane/src/pubsub/pubsub.module.ts`

**Channel name:** `cd:inbox:{nodeId}` (dynamic per node)

**Interface:**
```ts
export interface NodeInboxChannel {
  publish(nodeId: string, payload: NodeInboxPayload): Promise<void>;
  subscribe(nodeId: string, handler: (payload: NodeInboxPayload) => void): void;
}

export type NodeInboxPayload = MatchAssignedPayload | SendToUserPayload; // extensible
```

**Behavior:**
- Each API instance has a `nodeId` (from `NODE_ID` or generated).
- On init, API subscribes to `cd:inbox:{nodeId}`.
- Matchmaking/Dispatch calls `publish(nodeId, payload)` to send only to that node.

**Step 1:** Add `nodeInbox` to channels. Implement Redis + InMemory. Wire in PubSubModule with `NODE_INBOX_CHANNEL` token.

**Step 2:** RealtimeGateway gets `nodeId` from config; subscribes to NodeInboxChannel in onModuleInit.

**Step 3:** Commit: `feat(pubsub): add NodeInboxChannel for per-node delivery`

---

## Task 3: Gateway – userId registry, registerSession, heartbeat

**Files:**
- Modify: `Packages/control-plane/src/realtime/realtime.gateway.ts`
- Create: `Packages/control-plane/src/realtime/session-registry.ts` (optional; can inline)
- Update: `Packages/control-plane/src/realtime/realtime.module.ts`

**Changes:**
1. **userId extraction:** Client connects with `?userId=xxx` or sends `userId` in first message. For enqueue-via-WS, use `members[0]` as userId when no explicit userId.
2. **userId→sockets registry:** `Map<userId, Set<WebSocket>>` per node (in addition to ticketSubscriptions).
3. **registerSession:** On connect (or when userId known), call `clusterDirectory.registerSession(userId, nodeId)`.
4. **heartbeat:** Option A: client sends `{ action: 'heartbeat' }` every 2–4s; Gateway calls `refreshLease`. Option B: server-side timer per connected client.
5. **unregister:** On disconnect, call `clusterDirectory.unregisterSession(userId, nodeId)`.

**Backward compatibility:** If no userId, skip ClusterDirectory registration. TicketId subscription still works (broadcast flow).

**Step 1:** Add userId to connection flow. Add registry. Integrate ClusterDirectory.

**Step 2:** Add heartbeat handler. Add unregister on disconnect.

**Step 3:** Commit: `feat(realtime): add userId registry, registerSession, heartbeat`

---

## Task 4: Match.assigned – optional node inbox routing

**Files:**
- Modify: `Packages/control-plane/src/matchmaking/matchmaking.service.ts`
- Create: `Packages/control-plane/src/matchmaking/match-assigned-router.service.ts` (or inline in MatchmakingService)

**Logic:**
- When match assigned, we have `ticketId` and `members` (playerIds).
- **Primary userId** = `members[0]` (solo) or first member.
- Lookup `clusterDirectory.getNodeId(userId)`.
- If nodeId found: `nodeInboxChannel.publish(nodeId, { ticketId, envelope })`.
- If not found: fallback to broadcast `matchAssignedChannel.publish(...)` (current behavior).

**Config:** `USE_NODE_INBOX_FOR_MATCH_ASSIGNED=true` to enable routing; default false for gradual rollout.

**Step 1:** Add routing logic. Keep broadcast as fallback.

**Step 2:** Add config. Test with single node (nodeId same as publisher) and multi-node.

**Step 3:** Commit: `feat(matchmaking): optional node inbox routing for match.assigned`

---

## Task 5: AppModule and config

**Files:**
- Modify: `Packages/control-plane/src/app.module.ts`
- Add: `Packages/control-plane/src/cluster-directory/node-id.config.ts`

**NodeId:** Read `NODE_ID` from env; if missing, generate UUID and log (single-node mode, node inbox still works for future).

**Step 1:** Import ClusterDirectoryModule. Provide NODE_ID.

**Step 2:** Update README with Phase 2 env vars: `NODE_ID`, `USE_NODE_INBOX_FOR_MATCH_ASSIGNED`.

**Step 3:** Commit: `feat: wire ClusterDirectory and NodeInbox for Phase 2`

---

## Task 6: Tests and e2e

**Files:**
- Create: `Packages/control-plane/test/cluster-directory.spec.ts`
- Create: `Packages/control-plane/test/node-inbox-channel.spec.ts`
- Update: `Packages/control-plane/test/realtime.e2e-spec.ts` (optional: test userId flow)

**Step 1:** Unit tests for ClusterDirectory (InMemory impl), NodeInboxChannel (InMemory).

**Step 2:** E2E: connect with userId, verify registerSession; disconnect, verify unregister. (Requires Redis for full flow.)

**Step 3:** Commit: `test: add Phase 2 unit and e2e tests`

---

## Environment Variables (Phase 2)

| Variable | Description | Default |
|----------|-------------|---------|
| `NODE_ID` | Unique ID for this API instance | Auto-generated UUID |
| `USE_NODE_INBOX_FOR_MATCH_ASSIGNED` | Use node inbox routing for match.assigned | false |
| `CLUSTER_DIRECTORY_TTL_SECONDS` | Session lease TTL | 8 |
| `HEARTBEAT_INTERVAL_MS` | Client heartbeat interval (if client-driven) | 3000 |

---

## Execution Order

1. Task 1: ClusterDirectory
2. Task 2: Node Inbox channel
3. Task 3: Gateway changes
4. Task 4: Match.assigned routing (optional)
5. Task 5: AppModule
6. Task 6: Tests

---

## Rollback

- Set `USE_NODE_INBOX_FOR_MATCH_ASSIGNED=false` to use broadcast only.
- ClusterDirectory and Node Inbox can be no-op if not configured (single-node mode).
