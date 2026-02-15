# Provisioning REST API Migration Plan

**Date**: 2026-02-14  
**Status**: ✅ **Completed** (Option A: merged into NestJS)  
**Goal**: Replace Distributed actors (Cluster + Receptionist) with REST API for data plane ↔ control plane interaction.

## Current Architecture (Distributed Actors)

```
┌─────────────────────┐     cluster join      ┌──────────────────────────────┐
│ ProvisioningService │ ◄─────────────────── │ GameServerProvisioning       │
│ (Cluster SEED)      │                      │ (LandProvisioningActor)      │
│ receptionist.lookup │                      │ receptionist.checkIn         │
└─────────┬───────────┘                      └──────────────────────────────┘
          │
          │ POST /v1/provisioning/allocate
          ▼
┌─────────────────────┐
│ Matchmaking Control │
│ Plane (NestJS)      │
└─────────────────────┘
```

**Problems**:
- Cross-process receptionist replication unreliable
- Cluster join order sensitive (ProvisioningService must start first)
- Heavy dependency on swift-distributed-actors

---

## Target Architecture (REST API) – Implemented as Option A

```
┌─────────────────────────────────────────────┐     POST /v1/provisioning/servers/register
│ Matchmaking Control Plane (NestJS)          │ ◄───────────────────────────────────────────┐
│ - ProvisioningModule (in-memory registry)   │                                             │
│ - MatchmakingModule (uses internal registry)│                                             │
└─────────────────────────────────────────────┘                                             │
                                                                                            │
┌──────────────────────────────┐                                                            │
│ GameServerProvisioning       │ ───────────────────────────────────────────────────────────┘
│ (Swift, no cluster/actor)    │
└──────────────────────────────┘
```

Provisioning merged into control plane. No separate ProvisioningService.

**Benefits**:
- No cluster, no receptionist
- GameServer and ProvisioningService can start in any order
- Simpler, debuggable, K8s-ready (future: K8s API as backend)

---

## API Design

### 1. Server Registration (NEW)

**POST /v1/provisioning/servers/register**

Request:
```json
{
  "serverId": "game-1",
  "host": "127.0.0.1",
  "port": 8080,
  "landType": "hero-defense"
}
```

Response: `204 No Content` or `200 OK`

- GameServer calls this on startup (and optionally heartbeat)
- ProvisioningService stores in registry

### 2. Allocate (EXISTING, unchanged)

**POST /v1/provisioning/allocate**

Request/Response: Same as today (ProvisioningAllocateRequest / ProvisioningAllocateResponse)

- ProvisioningService looks up registry, picks a server, generates landId/connectUrl
- No actor call; pure in-memory logic

---

## Implementation Tasks

### Phase 1: ProvisioningService – REST Registry

| Task | File | Description |
|------|------|-------------|
| 1.1 | `ProvisioningService/Package.swift` | Remove `swift-distributed-actors`, `SwiftStateTreeProvisioning`; keep NIO |
| 1.2 | `ProvisioningService/main.swift` | Remove ClusterSystem; start HTTP server only |
| 1.3 | `ProvisioningService/ServerRegistry.swift` | New: in-memory registry `[landType: [ServerEntry]]` |
| 1.4 | `ProvisioningHTTPHandler.swift` | Add POST /v1/provisioning/servers/register; change allocate to use registry |
| 1.5 | `ProvisioningHTTPHandler.swift` | Remove `performAllocate(system:...)`, `ClusterSystem`, receptionist |

**ServerRegistry** (conceptual):
```swift
struct ServerEntry: Sendable {
    let serverId: String
    let host: String
    let port: UInt16
    let landType: String
    let registeredAt: Date
}
actor ServerRegistry {
    func register(serverId: String, host: String, port: UInt16, landType: String)
    func pickServer(landType: String) -> ServerEntry?  // round-robin or first
}
```

### Phase 2: GameServerProvisioning – REST Registration

| Task | File | Description |
|------|------|-------------|
| 2.1 | `GameDemoProvisioning/Package.swift` | Remove `swift-distributed-actors`, `SwiftStateTreeProvisioning` |
| 2.2 | `GameServerProvisioning/main.swift` | Remove ClusterSystem, LandProvisioningActor |
| 2.3 | `GameServerProvisioning/main.swift` | Add HTTP client call to POST /v1/provisioning/servers/register on startup |
| 2.4 | Env vars | `PROVISIONING_BASE_URL` (e.g. http://127.0.0.1:9101) |

**Registration flow**:
```swift
// On startup, after NIO host is ready:
let provUrl = ProcessInfo.processInfo.environment["PROVISIONING_BASE_URL"] ?? "http://127.0.0.1:9101"
try await registerWithProvisioning(baseUrl: provUrl, serverId: "game-1", host: host, port: port, landType: "hero-defense")
```

### Phase 3: SwiftStateTreeProvisioning – Simplify or Deprecate

| Task | File | Description |
|------|------|-------------|
| 3.1 | `SwiftStateTreeProvisioning` | Remove `LandProvisioningActor`; keep `ProvisioningTypes` only |
| 3.2 | OR | Deprecate package; move `ProvisioningTypes` to ProvisioningService or shared module |

**Recommendation**: Keep `SwiftStateTreeProvisioning` as a thin types-only package (ProvisioningAllocateRequest, ProvisioningAllocateResponse) so GameServer and ProvisioningService can share. Remove DistributedCluster dependency.

### Phase 4: Test Script & E2E

| Task | File | Description |
|------|------|-------------|
| 4.1 | `run-matchmaking-full-with-test.sh` | Remove cluster port vars; start order: prov, game, cp (no cluster join wait) |
| 4.2 | `MATCHMAKING_USE_STUB` | Can default to 0 (real ProvisioningService) since REST works cross-process |
| 4.3 | E2E | Verify matchmaking flow with real ProvisioningService |

### Phase 5: Cleanup

| Task | Description |
|------|-------------|
| 5.1 | Remove `swift-distributed-actors` from all packages |
| 5.2 | Delete or archive `LandProvisioningActorTests`, `receptionistDiscoveryTwoNodes` |
| 5.3 | Delete `MultiNode+ProvisioningStyleReceptionistTests` from checkout (or leave; will be overwritten on resolve) |
| 5.4 | Update docs (provisioning-api.md, architecture diagrams) |

---

## File Change Summary

| Package/File | Action |
|--------------|--------|
| `Packages/ProvisioningService/Package.swift` | Remove DistributedCluster, SwiftStateTreeProvisioning (or keep types only) |
| `Packages/ProvisioningService/main.swift` | Replace cluster bootstrap with HTTP-only |
| `Packages/ProvisioningService/ProvisioningHTTPHandler.swift` | Registry-based allocate; add register endpoint |
| `Packages/ProvisioningService/ServerRegistry.swift` | **New** |
| `Examples/GameDemoProvisioning/Package.swift` | Remove DistributedCluster, SwiftStateTreeProvisioning |
| `Examples/GameDemoProvisioning/main.swift` | Remove cluster; add REST registration |
| `Packages/SwiftStateTreeProvisioning` | Remove LandProvisioningActor; keep ProvisioningTypes; remove DistributedCluster |
| `Tools/CLI/scripts/internal/run-matchmaking-full-with-test.sh` | Simplify startup; MATCHMAKING_USE_STUB=0 default |

---

## Allocate Logic (ProvisioningService)

Current (actor):
```swift
let actor = await system.receptionist.lookup(...).first
let response = try await actor.allocate(request: request)
```

New (registry):
```swift
guard let server = await registry.pickServer(landType: request.landType ?? "hero-defense") else {
    return .failure(.noServerAvailable)
}
let instanceId = UUID().uuidString
let landId = "\(server.landType):\(instanceId)"
let connectUrl = "ws://\(server.host):\(server.port)/game/\(server.landType)?landId=\(landId)"
return .success(ProvisioningAllocateResponse(serverId: server.serverId, landId: landId, connectUrl: connectUrl, ...))
```

**Note**: Allocate request may not include `landType`; stub uses `hero-defense`. We can:
- Add `landType` to ProvisioningAllocateRequest (optional, default "hero-defense"), or
- Registry stores servers by landType; allocate picks by queueKey/constraints or first available.

For MVP: single landType "hero-defense"; registry is `[String: [ServerEntry]]` keyed by landType.

---

## Environment Variables

| Var | ProvisioningService | GameServerProvisioning |
|-----|---------------------|------------------------|
| `PORT` | HTTP port (9101) | - |
| `PROVISIONING_BASE_URL` | - | http://127.0.0.1:9101 |
| `HOST`, `SERVER_PORT` | - | Game bind |
| `PROVISIONING_CLUSTER_*` | **Remove** | **Remove** |
| `GAME_SERVER_CLUSTER_*` | **Remove** | **Remove** |

---

## Execution Order

1. Phase 1 (ProvisioningService)
2. Phase 3 (SwiftStateTreeProvisioning – simplify types)
3. Phase 2 (GameServerProvisioning)
4. Phase 4 (Test script)
5. Phase 5 (Cleanup)

Estimated: 1–2 days for full migration.
