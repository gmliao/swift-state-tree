# Matchmaking BullMQ + WebSocket Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace in-memory storage with BullMQ/Redis, replace setInterval tick with BullMQ repeatable job, and add pure WebSocket (ws) for real-time match assignment push. REST API remains unchanged for backward compatibility.

**Architecture:** Matchmaking uses Redis via BullMQ for queue persistence and tick scheduling. A WebSocket Gateway (pure ws) allows clients to subscribe by ticketId and receive `match.assigned` events immediately when assignment completes. Envelope format: `{ "type": "match.assigned", "v": 1, "data": { ... } }`.

**Tech Stack:** NestJS, BullMQ, Redis, @nestjs/platform-ws, ws, class-validator, existing provisioning/JWT flow.

---

## Prerequisites

- Redis running (local or Docker: `docker run -d -p 6379:6379 redis:7-alpine`)
- `REDIS_HOST`, `REDIS_PORT` env vars (default: localhost:6379)

---

## Task 1: Add BullMQ and Redis dependencies

**Files:**
- Modify: `packages/control-plane/package.json`

**Step 1: Add dependencies**

Add to `dependencies`:
```json
"@nestjs/bullmq": "^11.0.0",
"bullmq": "^5.0.0",
"ioredis": "^5.3.2"
```

Add to `devDependencies`:
```json
"@nestjs/platform-ws": "^11.0.0",
"ws": "^8.18.0"
```

**Step 2: Install**

Run: `cd packages/control-plane && npm install`

Expected: No errors, new packages in node_modules.

**Step 3: Commit**

```bash
git add packages/control-plane/package.json package-lock.json
git commit -m "chore(matchmaking): add BullMQ, Redis, ws dependencies"
```

---

## Task 2: Add BullMQ module and Redis connection

**Files:**
- Create: `packages/control-plane/src/queue/queue.module.ts`
- Modify: `packages/control-plane/src/app.module.ts`

**Step 1: Create queue module**

Create `packages/control-plane/src/queue/queue.module.ts`:

```typescript
import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';

const redisHost = process.env.REDIS_HOST ?? 'localhost';
const redisPort = parseInt(process.env.REDIS_PORT ?? '6379', 10);

@Module({
  imports: [
    BullModule.forRoot({
      connection: {
        host: redisHost,
        port: redisPort,
      },
    }),
    BullModule.registerQueue(
      { name: 'matchmaking-tick' },
      { name: 'matchmaking-tickets' },
    ),
  ],
  exports: [BullModule],
})
export class QueueModule {}
```

**Step 2: Import QueueModule in AppModule**

In `packages/control-plane/src/app.module.ts`, add `QueueModule` to imports:

```typescript
import { QueueModule } from './queue/queue.module';

@Module({
  imports: [QueueModule, MatchmakingModule],
  // ...
})
```

**Step 3: Run build**

Run: `cd packages/control-plane && npm run build`

Expected: Build succeeds.

**Step 4: Commit**

```bash
git add packages/control-plane/src/queue/queue.module.ts packages/control-plane/src/app.module.ts
git commit -m "feat(matchmaking): add BullMQ module and Redis connection"
```

---

## Task 3: Implement Redis-backed MatchStoragePort

**Files:**
- Create: `packages/control-plane/src/storage/redis-match-storage.ts`
- Modify: `packages/control-plane/src/matchmaking/matchmaking.module.ts`

**Step 1: Write the Redis storage implementation**

Create `packages/control-plane/src/storage/redis-match-storage.ts`:

```typescript
import { InjectQueue } from '@nestjs/bullmq';
import { Injectable } from '@nestjs/common';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../contracts/assignment.dto';
import {
  MatchGroup,
  MatchStoragePort,
  QueuedTicket,
} from './match-storage.port';

const TICKETS_KEY = 'matchmaking:tickets';
const GROUP_TO_TICKET_KEY = 'matchmaking:groupToTicket';
const QUEUED_BY_QUEUE_PREFIX = 'matchmaking:queued:';
const TICKET_COUNTER_KEY = 'matchmaking:ticketCounter';

@Injectable()
export class RedisMatchStorage implements MatchStoragePort {
  constructor(
    @InjectQueue('matchmaking-tickets') private readonly queue: Queue,
  ) {}

  private async getRedis() {
    return this.queue.client;
  }

  async enqueue(group: MatchGroup): Promise<QueuedTicket> {
    const redis = await this.getRedis();
    const existing = await redis.hget(GROUP_TO_TICKET_KEY, group.groupId);
    if (existing) {
      const raw = await redis.hget(TICKETS_KEY, existing);
      if (raw) {
        const ticket = JSON.parse(raw) as QueuedTicket;
        ticket.createdAt = new Date(ticket.createdAt);
        if (ticket.status === 'queued') return ticket;
      }
    }

    const id = await redis.incr(TICKET_COUNTER_KEY);
    const ticketId = `ticket-${id}`;
    const ticket: QueuedTicket = {
      ticketId,
      groupId: group.groupId,
      queueKey: group.queueKey,
      members: group.members,
      groupSize: group.groupSize,
      region: group.region,
      status: 'queued',
      createdAt: new Date(),
    };
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hset(GROUP_TO_TICKET_KEY, group.groupId, ticketId);
    await redis.sadd(QUEUED_BY_QUEUE_PREFIX + group.queueKey, ticketId);
    return ticket;
  }

  async cancel(ticketId: string): Promise<boolean> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return false;
    const ticket = JSON.parse(raw) as QueuedTicket;
    if (ticket.status !== 'queued') return false;
    ticket.status = 'cancelled';
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hdel(GROUP_TO_TICKET_KEY, ticket.groupId);
    await redis.srem(QUEUED_BY_QUEUE_PREFIX + ticket.queueKey, ticketId);
    return true;
  }

  async getStatus(ticketId: string): Promise<QueuedTicket | null> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return null;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.createdAt = new Date(ticket.createdAt);
    if (ticket.assignment) {
      ticket.assignment = ticket.assignment as AssignmentResult;
    }
    return ticket;
  }

  async updateAssignment(
    ticketId: string,
    assignment: AssignmentResult,
  ): Promise<void> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.assignment = assignment;
    ticket.status = 'assigned';
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hdel(GROUP_TO_TICKET_KEY, ticket.groupId);
    await redis.srem(QUEUED_BY_QUEUE_PREFIX + ticket.queueKey, ticketId);
  }

  async listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]> {
    const redis = await this.getRedis();
    const ids = await redis.smembers(QUEUED_BY_QUEUE_PREFIX + queueKey);
    const tickets: QueuedTicket[] = [];
    for (const id of ids) {
      const raw = await redis.hget(TICKETS_KEY, id);
      if (!raw) continue;
      const t = JSON.parse(raw) as QueuedTicket;
      t.createdAt = new Date(t.createdAt);
      if (t.status === 'queued') tickets.push(t);
    }
    return tickets;
  }

  async listQueueKeysWithQueued(): Promise<string[]> {
    const redis = await this.getRedis();
    const keys = await redis.keys(QUEUED_BY_QUEUE_PREFIX + '*');
    const queueKeys: string[] = [];
    for (const k of keys) {
      const count = await redis.scard(k);
      if (count > 0) {
        queueKeys.push(k.replace(QUEUED_BY_QUEUE_PREFIX, ''));
      }
    }
    return queueKeys;
  }
}
```

**Step 2: Register RedisMatchStorage in MatchmakingModule**

In `packages/control-plane/src/matchmaking/matchmaking.module.ts`:
- Import `BullModule` and `QueueModule` (or ensure QueueModule exports the queue)
- Import `RedisMatchStorage`
- Change provider from `InMemoryMatchStorage` to `RedisMatchStorage`
- Add `BullModule.registerQueue({ name: 'matchmaking-tickets' })` to MatchmakingModule if not already in QueueModule

Check: QueueModule already registers `matchmaking-tickets`. MatchmakingModule needs to import a module that provides the queue. The RedisMatchStorage injects `@InjectQueue('matchmaking-tickets')` - we need the queue to be available. QueueModule exports BullModule which registers the queues. MatchmakingModule must import QueueModule.

Add to MatchmakingModule:
```typescript
import { QueueModule } from '../queue/queue.module';
import { RedisMatchStorage } from '../storage/redis-match-storage';

// In @Module:
imports: [QueueModule, SecurityModule, ProvisioningModule],
providers: [
  // ...
  {
    provide: 'MatchStoragePort',
    useClass: RedisMatchStorage,
  },
],
```

**Step 3: Run tests (expect some to fail if Redis not running)**

Run: `cd packages/control-plane && npm test`

Note: E2E tests may fail if Redis is not running. For CI/local, ensure Redis is up. Add optional env `REDIS_URL` or skip Redis tests when Redis unavailable - for now assume Redis is required.

**Step 4: Commit**

```bash
git add packages/control-plane/src/storage/redis-match-storage.ts packages/control-plane/src/matchmaking/matchmaking.module.ts
git commit -m "feat(matchmaking): add Redis-backed MatchStoragePort"
```

---

## Task 4: Replace setInterval with BullMQ repeatable job

**Files:**
- Modify: `packages/control-plane/src/matchmaking/matchmaking.service.ts`
- Modify: `packages/control-plane/src/matchmaking/matchmaking.module.ts`

**Step 1: Inject Queue and replace setInterval**

In `matchmaking.service.ts`:
- Remove `OnModuleInit`, `OnModuleDestroy`, `tickInterval`
- Inject `@InjectQueue('matchmaking-tick') private readonly tickQueue: Queue`
- Add `onModuleInit` that adds a repeatable job: `await this.tickQueue.add('tick', {}, { repeat: { every: this.config.intervalMs } })`
- Add `onModuleDestroy` that removes repeatable jobs: `await this.tickQueue.removeRepeatableByKey(...)` - need to store the repeatable job key
- Add a `@Processor('matchmaking-tick')` - actually the processor should be in a separate processor class. Use `@Processor` from `@nestjs/bullmq`.

Create `MatchmakingTickProcessor`:
- `@Processor('matchmaking-tick')` class
- `@Process('tick')` method that calls `matchmakingService.runMatchmakingTick()`

And in MatchmakingService:
- Remove setInterval/clearInterval
- In onModuleInit: add repeatable job
- In onModuleDestroy: remove repeatable job by key (store the key from add result)

**Step 2: Create MatchmakingTickProcessor**

Create `packages/control-plane/src/matchmaking/matchmaking-tick.processor.ts`:

```typescript
import { Processor, Process } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { MatchmakingService } from './matchmaking.service';

@Processor('matchmaking-tick')
export class MatchmakingTickProcessor {
  constructor(private readonly matchmakingService: MatchmakingService) {}

  @Process('tick')
  async handleTick(_job: Job) {
    await this.matchmakingService.runMatchmakingTick();
  }
}
```

**Step 3: Update MatchmakingService**

In `matchmaking.service.ts`:
- Remove `private tickInterval`
- Add `@InjectQueue('matchmaking-tick') private readonly tickQueue: Queue`
- In `onModuleInit`: `const job = await this.tickQueue.add('tick', {}, { repeat: { every: this.config.intervalMs } }); this.repeatableKey = job.repeatJobKey;` - but repeatJobKey might not be available immediately. Use `this.tickQueue.add('tick', {}, { repeat: { every: this.config.intervalMs } })` and then `getRepeatableJobs()` to find and remove. Simpler: store `repeat: { every }` and in onModuleDestroy call `removeRepeatable('tick', {}, { every: this.config.intervalMs })`.
- Actually: `removeRepeatable` needs the exact repeat opts. Store `{ every: this.config.intervalMs }` and use it.

**Step 4: Register processor in module**

Add `MatchmakingTickProcessor` to MatchmakingModule providers.

**Step 5: Run tests**

Run: `cd packages/control-plane && npm test`

Expected: Unit tests pass. E2E may need Redis.

**Step 6: Commit**

```bash
git commit -m "feat(matchmaking): replace setInterval with BullMQ repeatable job"
```

---

## Task 5: Define WebSocket envelope and event DTOs

**Files:**
- Create: `packages/control-plane/src/realtime/ws-envelope.dto.ts`
- Create: `packages/control-plane/src/realtime/realtime.module.ts`

**Step 1: Create envelope types**

Create `packages/control-plane/src/realtime/ws-envelope.dto.ts`:

```typescript
import { IsEnum, IsNumber, IsObject, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import { AssignmentResult } from '../contracts/assignment.dto';

/** Server-to-client WebSocket event types. */
export type WsEventType = 'match.assigned';

/** Envelope for all server-pushed WebSocket messages. */
export interface WsEnvelope<T = unknown> {
  type: WsEventType;
  v: number;
  data: T;
}

/** Payload for match.assigned event. */
export class MatchAssignedDataDto {
  ticketId!: string;
  assignment!: AssignmentResult;
}

/** Validator for match.assigned data. */
export class MatchAssignedDataValidator {
  @IsNumber()
  v!: number;

  @ValidateNested()
  @Type(() => MatchAssignedDataDto)
  @IsObject()
  data!: MatchAssignedDataDto;
}
```

Note: MatchAssignedDataDto needs AssignmentResult fields. Use `plainToClass` and `validate` from class-validator. For simplicity, we can use a simpler DTO that mirrors AssignmentResult - or just use AssignmentResultDto from assignment.dto. The envelope `data` will be the full StatusResponse.assignment. Reuse AssignmentResult.

**Step 2: Simplify - use inline structure**

```typescript
/** Event type for match.assigned. */
export const WS_EVENT_MATCH_ASSIGNED = 'match.assigned' as const;
export const WS_ENVELOPE_VERSION = 1;

/** Build match.assigned envelope. */
export function buildMatchAssignedEnvelope(
  ticketId: string,
  assignment: AssignmentResult,
): WsEnvelope<{ ticketId: string; assignment: AssignmentResult }> {
  return {
    type: WS_EVENT_MATCH_ASSIGNED,
    v: WS_ENVELOPE_VERSION,
    data: { ticketId, assignment },
  };
}
```

**Step 3: Commit**

```bash
git add packages/control-plane/src/realtime/ws-envelope.dto.ts
git commit -m "feat(matchmaking): add WebSocket envelope types"
```

---

## Task 6: Add WsAdapter and WebSocket Gateway

**Files:**
- Create: `packages/control-plane/src/realtime/realtime.gateway.ts`
- Modify: `packages/control-plane/src/main.ts`
- Modify: `packages/control-plane/src/app.module.ts`

**Step 1: Create RealtimeGateway**

Create `packages/control-plane/src/realtime/realtime.gateway.ts`:

```typescript
import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Server } from 'ws';
import { IncomingMessage } from 'http';

/** Maps ticketId -> Set of WebSocket clients subscribed to that ticket. */
const ticketSubscriptions = new Map<string, Set<WebSocket>>();

@WebSocketGateway({ path: '/realtime' })
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server!: Server;

  handleConnection(client: WebSocket, request: IncomingMessage) {
    const url = new URL(request.url ?? '', `http://${request.headers.host}`);
    const ticketId = url.searchParams.get('ticketId');
    if (!ticketId) {
      client.close(4000, 'Missing ticketId query param');
      return;
    }
    let set = ticketSubscriptions.get(ticketId);
    if (!set) {
      set = new Set();
      ticketSubscriptions.set(ticketId, set);
    }
    set.add(client);
    (client as unknown as { _ticketId: string })._ticketId = ticketId;
  }

  handleDisconnect(client: WebSocket) {
    const ticketId = (client as unknown as { _ticketId?: string })._ticketId;
    if (ticketId) {
      const set = ticketSubscriptions.get(ticketId);
      if (set) {
        set.delete(client);
        if (set.size === 0) ticketSubscriptions.delete(ticketId);
      }
    }
  }

  /** Push match.assigned to all clients subscribed to this ticketId. */
  pushMatchAssigned(ticketId: string, envelope: object): void {
    const set = ticketSubscriptions.get(ticketId);
    if (!set) return;
    const msg = JSON.stringify(envelope);
    for (const ws of set) {
      if (ws.readyState === 1) ws.send(msg);
    }
  }
}
```

**Step 2: Export pushMatchAssigned for MatchmakingService**

The gateway needs to be injectable so MatchmakingService can call `pushMatchAssigned`. Use a port/adapter pattern or inject the gateway. NestJS allows injecting gateways. Inject `RealtimeGateway` into MatchmakingService.

**Step 3: Wire WsAdapter in main.ts**

In `main.ts`, before `app.listen`:
```typescript
import { WsAdapter } from '@nestjs/platform-ws';
app.useWebSocketAdapter(new WsAdapter(app));
```

**Step 4: Create RealtimeModule and register gateway**

Create `packages/control-plane/src/realtime/realtime.module.ts`:
```typescript
import { Module } from '@nestjs/common';
import { RealtimeGateway } from './realtime.gateway';

@Module({
  providers: [RealtimeGateway],
  exports: [RealtimeGateway],
})
export class RealtimeModule {}
```

Import RealtimeModule in AppModule. Import RealtimeModule in MatchmakingModule so MatchmakingService can inject RealtimeGateway.

**Step 5: Run build**

Run: `cd packages/control-plane && npm run build`

Expected: Build succeeds.

**Step 6: Commit**

```bash
git add packages/control-plane/src/realtime/
git commit -m "feat(matchmaking): add WebSocket Gateway for realtime push"
```

---

## Task 7: Integrate Gateway push into MatchmakingService

**Files:**
- Modify: `packages/control-plane/src/matchmaking/matchmaking.service.ts`
- Modify: `packages/control-plane/src/matchmaking/matchmaking.module.ts`
- Modify: `packages/control-plane/src/realtime/realtime.gateway.ts`

**Step 1: Inject RealtimeGateway and call pushMatchAssigned**

In MatchmakingService, after `storage.updateAssignment`:
- Inject `RealtimeGateway` (optional - use `@Optional()` so tests without gateway still work, or make it required)
- Call `this.realtimeGateway.pushMatchAssigned(ticketId, buildMatchAssignedEnvelope(ticketId, assignment))`

**Step 2: Import buildMatchAssignedEnvelope**

From `../realtime/ws-envelope.dto`.

**Step 3: Add RealtimeModule to MatchmakingModule imports**

**Step 4: Run E2E test**

Run: `cd packages/control-plane && npm run test:e2e`

Expected: E2E passes (with Redis). Existing tests should still pass - they poll status. New E2E can be added in next task for WS.

**Step 5: Commit**

```bash
git commit -m "feat(matchmaking): push match.assigned via WebSocket on assignment"
```

---

## Task 8: Add E2E test for WebSocket push

**Files:**
- Create: `packages/control-plane/test/realtime.e2e-spec.ts`
- Modify: `packages/control-plane/test/jest-e2e.json` (if needed to include new spec)

**Step 1: Write E2E test**

Create `packages/control-plane/test/realtime.e2e-spec.ts`:

```typescript
import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { WebSocket } from 'ws';
import { AppModule } from '../src/app.module';

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-1',
    landId: 'standard:room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:room-1',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { intervalMs: 50, minWaitMs: 0 };

describe('Realtime WebSocket (e2e)', () => {
  let app: INestApplication;
  let port: number;

  beforeEach(async () => {
    jest.clearAllMocks();
    mockProvisioning.allocate.mockResolvedValue({
      serverId: 'stub-1',
      landId: 'standard:room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:room-1',
      expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
    });

    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider('ProvisioningClientPort')
      .useValue(mockProvisioning)
      .overrideProvider('MatchmakingConfig')
      .useValue(testConfig)
      .compile();

    app = moduleFixture.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }),
    );
    await app.listen(0);
    port = (app.getHttpServer().address() as { port: number }).port;
  });

  afterEach(async () => {
    await app.close();
  });

  it('pushes match.assigned via WebSocket when ticket is assigned', async () => {
    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);

    const ticketId = enqueueRes.body.ticketId;

    const ws = new WebSocket(`ws://localhost:${port}/realtime?ticketId=${ticketId}`);

    const envelope = await new Promise<{ type: string; v: number; data: unknown }>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('Timeout waiting for WS message')), 5000);
      ws.on('message', (buf) => {
        clearTimeout(t);
        resolve(JSON.parse(buf.toString()));
      });
      ws.on('error', reject);
    });

    expect(envelope.type).toBe('match.assigned');
    expect(envelope.v).toBe(1);
    expect(envelope.data).toMatchObject({
      ticketId,
      assignment: expect.objectContaining({
        connectUrl: expect.any(String),
        matchToken: expect.any(String),
        landId: expect.any(String),
      }),
    });

    ws.close();
  });
});
```

**Step 2: Ensure main.ts uses dynamic port in tests**

The test uses `app.listen(0)` - NestJS supports this for dynamic port. The WebSocket path is `/realtime` - we need to ensure the HTTP server and WS share the same port. Default NestJS setup does this when using WsAdapter.

**Step 3: Run E2E**

Run: `cd packages/control-plane && npm run test:e2e`

Expected: New test passes. All E2E pass.

**Step 4: Commit**

```bash
git add packages/control-plane/test/realtime.e2e-spec.ts
git commit -m "test(matchmaking): add E2E for WebSocket match.assigned push"
```

---

## Task 9: Add docker-compose for Redis (dev)

**Files:**
- Create: `packages/control-plane/docker-compose.yml`

**Step 1: Create docker-compose**

```yaml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
```

**Step 2: Add README note**

In `packages/control-plane/README.md` (or create if missing), add:
```markdown
## Development

Start Redis: `docker compose up -d`
Run tests: `npm test && npm run test:e2e`
```

**Step 3: Commit**

```bash
git add packages/control-plane/docker-compose.yml
git commit -m "chore(matchmaking): add docker-compose for Redis"
```

---

## Task 10: Update documentation

**Files:**
- Modify: `docs/matchmaking-two-plane.md` (or create matchmaking-realtime section)
- Create: `packages/control-plane/docs/websocket-api.md`

**Step 1: Document WebSocket API**

Create `packages/control-plane/docs/websocket-api.md`:

```markdown
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
```

**Step 2: Commit**

```bash
git add packages/control-plane/docs/websocket-api.md
git commit -m "docs(matchmaking): add WebSocket API documentation"
```

---

## Verification Checklist

Before considering Phase 1 complete:

- [ ] `cd packages/control-plane && npm run build` - PASS
- [ ] `cd packages/control-plane && npm test` - PASS (unit tests)
- [ ] Redis running: `cd packages/control-plane && npm run test:e2e` - PASS
- [ ] REST enqueue/cancel/status still works
- [ ] WebSocket push works for match.assigned
- [ ] HTTP status polling still works (backward compat)

---

## Execution Handoff

Plan complete and saved to `docs/plans/2025-02-15-matchmaking-bullmq-ws-phase1.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** - Dispatch fresh subagent per task, review between tasks, fast iteration
2. **Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
