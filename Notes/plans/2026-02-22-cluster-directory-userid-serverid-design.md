# ClusterDirectory: UserIdDirectory + ServerIdDirectory Design

**Date:** 2026-02-22

**Goal:** Refactor ClusterDirectory into a cluster-wide directory module with two sub-directories: UserIdDirectory (userId→nodeId) and ServerIdDirectory (serverId→ServerEntry). Both use Redis for cross-node sync. No BaseClusterDirectory abstraction.

---

## 1. Architecture Overview

**ClusterDirectoryModule** is the parent concept: "cluster-wide shared directory" (群組伺服器共用地圖). It provides two independent interfaces:

| Sub-Directory | Purpose | Key → Value | Storage |
|---------------|---------|-------------|---------|
| **UserIdDirectory** | User session routing | userId → nodeId | Redis |
| **ServerIdDirectory** | Game server registry | serverId → ServerEntry | Redis |

- No BaseClusterDirectory: the two directories have different operations; a shared base would add little value.
- ClusterDirectory = conceptual parent (the module); UserIdDirectory and ServerIdDirectory are siblings.

---

## 2. Component Design

### 2.1 UserIdDirectory (rename from ClusterDirectory)

**Interface:** `UserIdDirectory`

| Method | Signature | Purpose |
|--------|-----------|---------|
| registerSession | `(userId, nodeId, ttlSeconds?) => Promise<void>` | Register user on node |
| refreshLease | `(userId, nodeId, ttlSeconds?) => Promise<void>` | Refresh TTL |
| getNodeId | `(userId) => Promise<string \| null>` | Lookup node |
| unregisterSession | `(userId, nodeId) => Promise<void>` | Remove session |

**Implementations:**
- `RedisUserIdDirectoryService` (rename from RedisClusterDirectoryService)
- `InMemoryUserIdDirectoryService` (rename from InMemoryClusterDirectoryService, for tests)

**Token:** `USER_ID_DIRECTORY`

**Redis keys:** `cd:user:{userId}` → nodeId (unchanged)

---

### 2.2 ServerIdDirectory (new)

**Interface:** `ServerIdDirectory`

| Method | Signature | Purpose |
|--------|-----------|---------|
| register | `(serverId, host, port, landType, opts?) => Promise<void>` | Register or heartbeat |
| deregister | `(serverId) => Promise<void>` | Remove server |
| pickServer | `(landType, ttlMs?) => Promise<ServerEntry \| null>` | Round-robin pick for allocate |
| listAllServers | `() => Promise<(ServerEntry & { isStale: boolean })[]>` | Admin dashboard |

**Implementation:** `RedisServerIdDirectoryService`

**Token:** `SERVER_ID_DIRECTORY`

**Shared types:** `ServerEntry` moves to a shared location (e.g. `infra/contracts/` or `provisioning/`) so both Provisioning and ClusterDirectory can use it.

---

### 2.3 Redis Data Structure for ServerIdDirectory

| Key | Type | Purpose |
|-----|------|---------|
| `cd:server:byid:{serverId}` | String (JSON) | Primary entry lookup |
| `cd:server:{landType}` | Hash (serverId → JSON) | Servers by landType for pickServer |
| `cd:server:ids` | Set of serverId | All server IDs for listAllServers |
| `cd:server:rr:{landType}` | Integer | Round-robin index per landType |

**Register flow:**
1. Get old entry from `cd:server:byid:{serverId}` (if exists) to get previous landType
2. If landType changed: `HDEL cd:server:{oldLandType} serverId`
3. `SET cd:server:byid:{serverId} JSON(entry)`
4. `HSET cd:server:{landType} serverId JSON(entry)`
5. `SADD cd:server:ids serverId`

**Deregister flow:**
1. `GET cd:server:byid:{serverId}` → parse JSON, get landType
2. `DEL cd:server:byid:{serverId}`
3. `HDEL cd:server:{landType} serverId`
4. `SREM cd:server:ids serverId`

**pickServer(landType):**
1. `HGETALL cd:server:{landType}`
2. Parse JSONs, filter by `lastSeenAt > cutoff`
3. If none alive: return null
4. `INCR cd:server:rr:{landType}` → idx
5. Return `alive[(idx - 1) % alive.length]`

**listAllServers():**
1. `SMEMBERS cd:server:ids`
2. For each serverId: `GET cd:server:byid:{serverId}`, parse, add `isStale`
3. Return array

---

## 3. Module Wiring

**ClusterDirectoryModule:**
- Provides `USER_ID_DIRECTORY` → RedisUserIdDirectoryService
- Provides `SERVER_ID_DIRECTORY` → RedisServerIdDirectoryService
- Exports both tokens

**ProvisioningModule:**
- Imports ClusterDirectoryModule
- Removes ServerRegistryService
- ProvisioningController injects `SERVER_ID_DIRECTORY`, calls `register`/`deregister` (async)
- InMemoryProvisioningClient injects `SERVER_ID_DIRECTORY`, calls `pickServer` (async)

**AdminModule:**
- AdminController injects `SERVER_ID_DIRECTORY`, calls `listAllServers` (async)

**RealtimeModule / MatchmakingModule:**
- Inject `USER_ID_DIRECTORY` instead of `CLUSTER_DIRECTORY`

---

## 4. Data Flow

**Register (game server):**
1. POST /v1/provisioning/servers/register → ProvisioningController
2. Controller calls `serverIdDirectory.register(...)`
3. RedisServerIdDirectoryService writes to Redis
4. All nodes share Redis → Worker sees server for allocate

**Allocate (matchmaking):**
1. MatchmakingService.tryMatch → provisioning.allocate
2. InMemoryProvisioningClient.allocate → serverIdDirectory.pickServer(landType)
3. RedisServerIdDirectoryService reads from Redis, round-robin pick
4. Returns connectUrl

**User session:**
1. WebSocket connect → UserSessionRegistry.bindClient
2. Calls `userIdDirectory.registerSession(userId, nodeId)`
3. RedisUserIdDirectoryService writes to Redis
4. MatchmakingService uses `userIdDirectory.getNodeId(primaryUserId)` for targeted push

---

## 5. Error Handling

- **Redis unavailable:** RedisServerIdDirectoryService and RedisUserIdDirectoryService use `getRedisConfig()`; if Redis is not configured, module init may fail. Align with existing Channels/BullMQ behavior.
- **pickServer returns null:** InMemoryProvisioningClient throws `NoServerAvailableError` (unchanged).
- **Date serialization:** ServerEntry uses `registeredAt` and `lastSeenAt` as Date; Redis stores JSON. Serialize as ISO string, deserialize to Date when reading.

---

## 6. Testing

- **Unit tests:** InMemoryUserIdDirectoryService (rename existing cluster-directory.spec), mock ServerIdDirectory for ProvisioningClient/MatchmakingService tests
- **E2E:** Use Redis; admin.e2e and matchmaking e2e should pass with ServerIdDirectory
- **Backward compatibility:** All consumers of CLUSTER_DIRECTORY switch to USER_ID_DIRECTORY; no dual support

---

## 7. Migration Summary

| File / Component | Change |
|------------------|--------|
| cluster-directory.interface.ts | Rename to user-id-directory.interface.ts, interface UserIdDirectory |
| redis-cluster-directory.service.ts | Rename to redis-user-id-directory.service.ts |
| inmemory-cluster-directory.service.ts | Rename to inmemory-user-id-directory.service.ts |
| cluster-directory.module.ts | Add ServerIdDirectory, rename provider |
| server-registry.service.ts | Remove; logic moves to RedisServerIdDirectoryService |
| provisioning.controller.ts | Inject SERVER_ID_DIRECTORY, async register/deregister |
| inmemory-provisioning.client.ts | Inject SERVER_ID_DIRECTORY, async allocate |
| admin.controller.ts | Inject SERVER_ID_DIRECTORY |
| user-session-registry.service.ts | Inject USER_ID_DIRECTORY |
| matchmaking.service.ts | Inject USER_ID_DIRECTORY |
| All test files | Update mocks and overrides |

---

## 8. Out of Scope (YAGNI)

- BaseClusterDirectory interface
- In-memory ServerIdDirectory for tests (use Redis or mock)
- Server entry TTL in Redis (stale filtering remains in application logic via lastSeenAt)
