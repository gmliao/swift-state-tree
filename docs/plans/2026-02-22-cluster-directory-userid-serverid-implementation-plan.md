# ClusterDirectory UserIdDirectory + ServerIdDirectory Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor ClusterDirectory into UserIdDirectory + ServerIdDirectory, both Redis-backed for cross-node sync. Register on any node will be visible to Worker for allocate.

**Architecture:** ClusterDirectoryModule provides two interfaces: UserIdDirectory (userId→nodeId, rename from ClusterDirectory) and ServerIdDirectory (serverId→ServerEntry, new Redis-backed). Provisioning and Admin use ServerIdDirectory; Realtime and Matchmaking use UserIdDirectory.

**Tech Stack:** NestJS, TypeScript, ioredis, Jest.

**Design reference:** `docs/plans/2026-02-22-cluster-directory-userid-serverid-design.md`

---

## Task 1: Extract ServerEntry to shared location

**Files:**
- Create: `Packages/control-plane/src/infra/contracts/server-entry.dto.ts`
- Modify: `Packages/control-plane/src/modules/provisioning/server-registry.service.ts` (import from shared)

**Step 1: Create ServerEntry DTO**

Create `Packages/control-plane/src/infra/contracts/server-entry.dto.ts`:

```ts
/** Shared ServerEntry type for ServerIdDirectory and Provisioning. */
export const SERVER_TTL_MS = 90_000;

export interface ServerEntry {
  serverId: string;
  host: string;
  port: number;
  landType: string;
  connectHost?: string;
  connectPort?: number;
  connectScheme?: 'ws' | 'wss';
  registeredAt: Date;
  lastSeenAt: Date;
}
```

**Step 2: Update ServerRegistryService to re-export**

In `server-registry.service.ts`, change to:
```ts
export { ServerEntry, SERVER_TTL_MS } from '../../infra/contracts/server-entry.dto';
// Keep the rest of the class, but use ServerEntry from the import
```

Actually: we will remove ServerRegistryService later. For Task 1, just create the shared file and have server-registry.service.ts import from it (to avoid breaking anything yet). So:

In `server-registry.service.ts`: Remove the local `ServerEntry` and `SERVER_TTL_MS` definitions, add:
```ts
import { ServerEntry, SERVER_TTL_MS } from '../../infra/contracts/server-entry.dto';
export { ServerEntry, SERVER_TTL_MS };
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: PASS

**Step 4: Commit**

```bash
git add Packages/control-plane/src/infra/contracts/server-entry.dto.ts Packages/control-plane/src/modules/provisioning/server-registry.service.ts
git commit -m "refactor: extract ServerEntry to shared infra/contracts"
```

---

## Task 2: Create UserIdDirectory interface (rename from ClusterDirectory)

**Files:**
- Create: `Packages/control-plane/src/infra/cluster-directory/user-id-directory.interface.ts`
- Modify: `Packages/control-plane/src/infra/cluster-directory/cluster-directory.interface.ts` (deprecate or remove after migration)

**Step 1: Create user-id-directory.interface.ts**

Create `Packages/control-plane/src/infra/cluster-directory/user-id-directory.interface.ts`:

```ts
/**
 * UserIdDirectory: userId → nodeId mapping with TTL lease.
 * Gateway registers on connect; heartbeat refreshes lease.
 * Used for routing messages (e.g. match.assigned, sendToUser) to the correct API node.
 */
export interface UserIdDirectory {
  registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  getNodeId(userId: string): Promise<string | null>;
  unregisterSession(userId: string, nodeId: string): Promise<void>;
}

export const USER_ID_DIRECTORY = 'UserIdDirectory' as const;
```

**Step 2: Update cluster-directory.interface.ts to re-export (backward compat during migration)**

In `cluster-directory.interface.ts`, add at top:
```ts
export type { UserIdDirectory } from './user-id-directory.interface';
export { USER_ID_DIRECTORY } from './user-id-directory.interface';
// Keep existing ClusterDirectory and CLUSTER_DIRECTORY for now
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: PASS

**Step 4: Commit**

```bash
git add Packages/control-plane/src/infra/cluster-directory/
git commit -m "feat: add UserIdDirectory interface"
```

---

## Task 3: Create ServerIdDirectory interface

**Files:**
- Create: `Packages/control-plane/src/infra/cluster-directory/server-id-directory.interface.ts`

**Step 1: Create server-id-directory.interface.ts**

```ts
import type { ServerEntry } from '../../contracts/server-entry.dto';

/**
 * ServerIdDirectory: serverId → ServerEntry mapping.
 * Game servers register via POST /v1/provisioning/servers/register.
 * Stored in Redis for cross-node visibility.
 */
export interface ServerIdDirectory {
  register(
    serverId: string,
    host: string,
    port: number,
    landType: string,
    opts?: { connectHost?: string; connectPort?: number; connectScheme?: 'ws' | 'wss' },
  ): Promise<void>;
  deregister(serverId: string): Promise<void>;
  pickServer(landType: string, ttlMs?: number): Promise<ServerEntry | null>;
  listAllServers(): Promise<(ServerEntry & { isStale: boolean })[]>;
}

export const SERVER_ID_DIRECTORY = 'ServerIdDirectory' as const;
```

**Step 2: Fix import path**

The path `../../contracts/` assumes cluster-directory is under infra. Actual path: `Packages/control-plane/src/infra/cluster-directory/` and contracts is `Packages/control-plane/src/infra/contracts/`. So from cluster-directory, it's `../contracts/server-entry.dto`. Adjust if needed.

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: PASS

**Step 4: Commit**

```bash
git add Packages/control-plane/src/infra/cluster-directory/server-id-directory.interface.ts
git commit -m "feat: add ServerIdDirectory interface"
```

---

## Task 4: Implement RedisServerIdDirectoryService

**Files:**
- Create: `Packages/control-plane/src/infra/cluster-directory/redis-server-id-directory.service.ts`

**Step 1: Write the implementation**

Create `redis-server-id-directory.service.ts`:

```ts
import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { getRedisConfig } from '../config/env.config';
import type { ServerEntry } from '../contracts/server-entry.dto';
import { SERVER_TTL_MS } from '../contracts/server-entry.dto';
import type { ServerIdDirectory } from './server-id-directory.interface';

const KEY_BYID = 'cd:server:byid:';
const KEY_LAND = 'cd:server:';
const KEY_IDS = 'cd:server:ids';
const KEY_RR = 'cd:server:rr:';

@Injectable()
export class RedisServerIdDirectoryService implements ServerIdDirectory, OnModuleDestroy {
  private client: Redis | null = null;

  private ensureClient(): Redis {
    if (!this.client) {
      this.client = new Redis(getRedisConfig());
    }
    return this.client;
  }

  async register(
    serverId: string,
    host: string,
    port: number,
    landType: string,
    opts?: { connectHost?: string; connectPort?: number; connectScheme?: 'ws' | 'wss' },
  ): Promise<void> {
    const now = new Date();
    const entry: ServerEntry = {
      serverId,
      host,
      port,
      landType,
      connectHost: opts?.connectHost,
      connectPort: opts?.connectPort,
      connectScheme: opts?.connectScheme,
      registeredAt: now,
      lastSeenAt: now,
    };

    const client = this.ensureClient();
    const oldJson = await client.get(KEY_BYID + serverId);
    if (oldJson) {
      try {
        const old = JSON.parse(oldJson) as ServerEntry;
        if (old.landType !== landType) {
          await client.hdel(KEY_LAND + old.landType, serverId);
        }
      } catch {
        // ignore parse error
      }
    }

    const json = JSON.stringify({
      ...entry,
      registeredAt: entry.registeredAt.toISOString(),
      lastSeenAt: entry.lastSeenAt.toISOString(),
    });
    await client.set(KEY_BYID + serverId, json);
    await client.hset(KEY_LAND + landType, serverId, json);
    await client.sadd(KEY_IDS, serverId);
  }

  async deregister(serverId: string): Promise<void> {
    const client = this.ensureClient();
    const json = await client.get(KEY_BYID + serverId);
    if (!json) return;
    const entry = JSON.parse(json) as { landType: string };
    await client.del(KEY_BYID + serverId);
    await client.hdel(KEY_LAND + entry.landType, serverId);
    await client.srem(KEY_IDS, serverId);
  }

  async pickServer(landType: string, ttlMs = SERVER_TTL_MS): Promise<ServerEntry | null> {
    const client = this.ensureClient();
    const map = await client.hgetall(KEY_LAND + landType);
    if (!map || Object.keys(map).length === 0) return null;

    const cutoff = Date.now() - ttlMs;
    const alive: ServerEntry[] = [];
    for (const json of Object.values(map)) {
      const e = this.parseEntry(json);
      if (e && e.lastSeenAt.getTime() > cutoff) {
        alive.push(e);
      }
    }
    if (alive.length === 0) return null;

    const idx = await client.incr(KEY_RR + landType);
    return alive[(idx - 1) % alive.length];
  }

  async listAllServers(): Promise<(ServerEntry & { isStale: boolean })[]> {
    const client = this.ensureClient();
    const ids = await client.smembers(KEY_IDS);
    const cutoff = Date.now() - SERVER_TTL_MS;
    const result: (ServerEntry & { isStale: boolean })[] = [];
    for (const serverId of ids) {
      const json = await client.get(KEY_BYID + serverId);
      if (json) {
        const e = this.parseEntry(json);
        if (e) {
          result.push({ ...e, isStale: e.lastSeenAt.getTime() < cutoff });
        }
      }
    }
    return result;
  }

  private parseEntry(json: string): ServerEntry | null {
    try {
      const o = JSON.parse(json);
      return {
        ...o,
        registeredAt: new Date(o.registeredAt),
        lastSeenAt: new Date(o.lastSeenAt),
      };
    } catch {
      return null;
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.client?.quit();
    this.client = null;
  }
}
```

**Step 2: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: PASS (no tests for this yet; add unit test in next task or verify e2e)

**Step 3: Commit**

```bash
git add Packages/control-plane/src/infra/cluster-directory/redis-server-id-directory.service.ts
git commit -m "feat: add RedisServerIdDirectoryService"
```

---

## Task 5: Rename ClusterDirectory to UserIdDirectory (implementation)

**Files:**
- Rename: `redis-cluster-directory.service.ts` → `redis-user-id-directory.service.ts`
- Rename: `inmemory-cluster-directory.service.ts` → `inmemory-user-id-directory.service.ts`
- Modify: both to implement UserIdDirectory

**Step 1: Create redis-user-id-directory.service.ts**

Copy `redis-cluster-directory.service.ts` to `redis-user-id-directory.service.ts`, change:
- `import type { ClusterDirectory }` → `import type { UserIdDirectory }`
- `implements ClusterDirectory` → `implements UserIdDirectory`
- Class name: `RedisUserIdDirectoryService`

**Step 2: Create inmemory-user-id-directory.service.ts**

Copy `inmemory-cluster-directory.service.ts` to `inmemory-user-id-directory.service.ts`, change:
- `import type { ClusterDirectory }` → `import type { UserIdDirectory }`
- `implements ClusterDirectory` → `implements UserIdDirectory`
- Class name: `InMemoryUserIdDirectoryService`

**Step 3: Delete old files**

Delete `redis-cluster-directory.service.ts` and `inmemory-cluster-directory.service.ts`.

**Step 4: Update cluster-directory.module.ts**

```ts
import { Module } from '@nestjs/common';
import { USER_ID_DIRECTORY } from './user-id-directory.interface';
import { SERVER_ID_DIRECTORY } from './server-id-directory.interface';
import { RedisUserIdDirectoryService } from './redis-user-id-directory.service';
import { RedisServerIdDirectoryService } from './redis-server-id-directory.service';

@Module({
  providers: [
    { provide: USER_ID_DIRECTORY, useClass: RedisUserIdDirectoryService },
    { provide: SERVER_ID_DIRECTORY, useClass: RedisServerIdDirectoryService },
  ],
  exports: [USER_ID_DIRECTORY, SERVER_ID_DIRECTORY],
})
export class ClusterDirectoryModule {}
```

**Step 5: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: FAIL (consumers still use CLUSTER_DIRECTORY)

**Step 6: Commit**

```bash
git add Packages/control-plane/src/infra/cluster-directory/
git commit -m "refactor: rename ClusterDirectory impl to UserIdDirectory, add ServerIdDirectory"
```

---

## Task 6: Update ProvisioningModule to use ServerIdDirectory

**Files:**
- Modify: `Packages/control-plane/src/modules/provisioning/provisioning.controller.ts`
- Modify: `Packages/control-plane/src/modules/provisioning/inmemory-provisioning.client.ts`
- Modify: `Packages/control-plane/src/modules/provisioning/provisioning.module.ts`

**Step 1: Update provisioning.module.ts**

Remove ServerRegistryService. Add ClusterDirectoryModule to imports. ProvisioningController and InMemoryProvisioningClient will inject SERVER_ID_DIRECTORY.

```ts
import { Module } from '@nestjs/common';
import { ProvisioningController } from './provisioning.controller';
import { InMemoryProvisioningClient } from './inmemory-provisioning.client';
import { ClusterDirectoryModule } from '../../infra/cluster-directory/cluster-directory.module';

@Module({
  controllers: [ProvisioningController],
  imports: [ClusterDirectoryModule],
  providers: [
    InMemoryProvisioningClient,
    { provide: 'ProvisioningClientPort', useExisting: InMemoryProvisioningClient },
  ],
  exports: ['ProvisioningClientPort'],
})
export class ProvisioningModule {}
```

**Step 2: Update provisioning.controller.ts**

```ts
import { Body, Controller, Delete, Param, Post } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
import { Inject } from '@nestjs/common';
import { ServerRegisterDto } from './dto/server-register.dto';

@Controller('v1/provisioning')
@ApiTags('provisioning')
export class ProvisioningController {
  constructor(
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
  ) {}

  @Post('servers/register')
  @ApiOperation({ summary: 'Register or heartbeat game server' })
  async register(@Body() dto: ServerRegisterDto) {
    await this.serverIdDirectory.register(dto.serverId, dto.host, dto.port, dto.landType, {
      connectHost: dto.connectHost,
      connectPort: dto.connectPort,
      connectScheme: dto.connectScheme,
    });
    return { ok: true };
  }

  @Delete('servers/:serverId')
  @ApiOperation({ summary: 'Deregister game server on shutdown' })
  async deregister(@Param('serverId') serverId: string) {
    await this.serverIdDirectory.deregister(serverId);
    return { ok: true };
  }
}
```

**Step 3: Update inmemory-provisioning.client.ts**

```ts
import { Injectable, Inject } from '@nestjs/common';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
import { AssignmentResult } from '../../infra/contracts/assignment.dto';
import { ProvisioningAllocateRequest, ProvisioningClientPort } from './provisioning-client.port';
import { NoServerAvailableError } from './provisioning-errors';

@Injectable()
export class InMemoryProvisioningClient implements ProvisioningClientPort {
  constructor(
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
  ) {}

  async allocate(request: ProvisioningAllocateRequest): Promise<AssignmentResult> {
    const landType =
      request.queueKey.includes(':')
        ? request.queueKey.split(':')[0]
        : request.queueKey || 'hero-defense';
    const server = await this.serverIdDirectory.pickServer(landType);
    if (!server) {
      throw new NoServerAvailableError(landType);
    }
    // ... rest unchanged
  }
}
```

**Step 4: Remove ServerRegistryService**

Delete or deprecate `server-registry.service.ts`. Update `provisioning/index.ts` to export ServerEntry from infra/contracts.

**Step 5: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Some failures (AdminController, MatchmakingModule imports)

**Step 6: Commit**

```bash
git add Packages/control-plane/src/modules/provisioning/
git commit -m "refactor: ProvisioningModule uses ServerIdDirectory"
```

---

## Task 7: Update AdminModule to use ServerIdDirectory

**Files:**
- Modify: `Packages/control-plane/src/modules/admin/admin.controller.ts`
- Modify: `Packages/control-plane/src/modules/admin/admin.module.ts` (if needed)

**Step 1: Update admin.controller.ts**

Inject SERVER_ID_DIRECTORY, call listAllServers (async). Add ClusterDirectoryModule to AdminModule imports if not already.

```ts
import { Controller, Get } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
import { AdminQueueService } from './admin-queue.service';
import { QueueSummaryResponseDto, ServerListResponseDto } from './dto/admin-response.dto';

@Controller('v1/admin')
@ApiTags('admin')
export class AdminController {
  constructor(
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
    private readonly queueSummary: AdminQueueService,
  ) {}

  @Get('servers')
  async getServers(): Promise<ServerListResponseDto> {
    const list = await this.serverIdDirectory.listAllServers();
    return {
      servers: list.map((e) => ({
        serverId: e.serverId,
        host: e.host,
        port: e.port,
        landType: e.landType,
        connectHost: e.connectHost,
        connectPort: e.connectPort,
        connectScheme: e.connectScheme,
        registeredAt: e.registeredAt.toISOString(),
        lastSeenAt: e.lastSeenAt.toISOString(),
        isStale: e.isStale,
      })),
    };
  }
  // ... queueSummary unchanged
}
```

Add `@Inject(SERVER_ID_DIRECTORY)` and `Inject` from `@nestjs/common`.

**Step 2: Update admin.module.ts**

Add ClusterDirectoryModule to AdminModule imports so SERVER_ID_DIRECTORY is available:

```ts
import { ClusterDirectoryModule } from '../../infra/cluster-directory/cluster-directory.module';

@Module({
  imports: [ClusterDirectoryModule, ProvisioningModule, MatchmakingModule],
  // ...
})
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Admin tests may need mock updates

**Step 4: Commit**

```bash
git add Packages/control-plane/src/modules/admin/
git commit -m "refactor: AdminController uses ServerIdDirectory"
```

---

## Task 8: Update RealtimeModule and MatchmakingModule to use UserIdDirectory

**Files:**
- Modify: `Packages/control-plane/src/modules/realtime/user-session-registry.service.ts`
- Modify: `Packages/control-plane/src/modules/matchmaking/matchmaking.service.ts`

**Step 1: Update user-session-registry.service.ts**

Change `CLUSTER_DIRECTORY` → `USER_ID_DIRECTORY`, `ClusterDirectory` → `UserIdDirectory`.

**Step 2: Update matchmaking.service.ts**

Change `CLUSTER_DIRECTORY` → `USER_ID_DIRECTORY`, `ClusterDirectory` → `UserIdDirectory`.

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: PASS (after test mocks updated)

**Step 4: Commit**

```bash
git add Packages/control-plane/src/modules/realtime/ Packages/control-plane/src/modules/matchmaking/
git commit -m "refactor: use UserIdDirectory instead of ClusterDirectory"
```

---

## Task 9: Update all tests and remove ClusterDirectory

**Files:**
- Modify: `Packages/control-plane/test/*.spec.ts` (all files using CLUSTER_DIRECTORY)
- Modify: `Packages/control-plane/test/*.e2e-spec.ts`
- Delete: `Packages/control-plane/src/infra/cluster-directory/cluster-directory.interface.ts` (or keep for re-export during transition, then remove)

**Step 1: Update test mocks**

In each test file:
- `CLUSTER_DIRECTORY` → `USER_ID_DIRECTORY`
- `mockClusterDirectory` → `mockUserIdDirectory`
- Add `SERVER_ID_DIRECTORY` mock where Provisioning/Admin are tested

**Step 2: Update cluster-directory.spec.ts**

Rename to `user-id-directory.spec.ts`, test `InMemoryUserIdDirectoryService`.

**Step 3: Add RedisServerIdDirectoryService unit test (optional)**

Create `test/redis-server-id-directory.spec.ts` if desired, or rely on e2e.

**Step 4: Remove cluster-directory.interface.ts**

Remove the old ClusterDirectory interface and CLUSTER_DIRECTORY token. Ensure all imports use user-id-directory.interface and server-id-directory.interface.

**Step 5: Run full test suite**

Run: `cd Packages/control-plane && npm test`
Run: `cd Packages/control-plane && npm run test:e2e -- --runInBand`
Expected: PASS

**Step 6: Commit**

```bash
git add Packages/control-plane/
git commit -m "test: update all tests for UserIdDirectory and ServerIdDirectory"
```

---

## Task 10: Update documentation and env

**Files:**
- Modify: `Packages/control-plane/README.md`
- Modify: `Packages/control-plane/.env.example`
- Modify: `Packages/control-plane/src/infra/config/env.config.ts` (if CLUSTER_DIRECTORY_TTL referenced)

**Step 1: Update README**

Replace ClusterDirectory references with UserIdDirectory. Add ServerIdDirectory description.

**Step 2: Update .env.example**

Comment for CLUSTER_DIRECTORY_TTL_SECONDS: "UserIdDirectory session lease TTL"

**Step 3: Run final verification**

Run: `cd Packages/control-plane && npm test && npm run test:e2e -- --runInBand`
Expected: PASS

**Step 4: Commit**

```bash
git add Packages/control-plane/README.md Packages/control-plane/.env.example
git commit -m "docs: update for UserIdDirectory and ServerIdDirectory"
```

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-02-22-cluster-directory-userid-serverid-implementation-plan.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** – Dispatch fresh subagent per task, review between tasks, fast iteration.

2. **Parallel Session (separate)** – Open new session with executing-plans, batch execution with checkpoints.

**Which approach?**
