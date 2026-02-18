# Pub/Sub Module Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract pub/sub into a dedicated `pubsub/` module with type-safe `MatchAssignedChannel` interface, Redis + InMemory implementations. MatchmakingService publishes; RealtimeGateway subscribes. Enables cross-instance push and unit testing without Redis.

**Architecture:** New `pubsub/` module provides `MatchAssignedChannel` (publish + subscribe). Redis impl for production; InMemory impl for tests. MatchmakingService injects channel and calls `publish` instead of `realtimeGateway.pushMatchAssigned`. RealtimeGateway injects channel and calls `subscribe(handler)` in `onModuleInit`. Remove `match-assigned-pubsub.service.ts` from matchmaking.

**Tech Stack:** NestJS, ioredis, existing realtime/ws-envelope types.

**Reference:** `Packages/control-plane/Notes/plans/pubsub-architecture.md`

---

## Task 1: Create pubsub module structure and interface

**Files:**
- Create: `Packages/control-plane/src/pubsub/channels.ts`
- Create: `Packages/control-plane/src/pubsub/match-assigned-channel.interface.ts`

**Step 1: Create channels.ts**

Create `Packages/control-plane/src/pubsub/channels.ts`:

```ts
export const CHANNEL_NAMES = {
  matchAssigned: 'matchmaking:assigned',
} as const;
```

**Step 2: Create match-assigned-channel.interface.ts**

Create `Packages/control-plane/src/pubsub/match-assigned-channel.interface.ts`:

```ts
import type { AssignmentResult } from '../contracts/assignment.dto';
import type { WsEnvelope } from '../realtime/ws-envelope.dto';

/** Payload for match.assigned channel. */
export interface MatchAssignedPayload {
  ticketId: string;
  envelope: WsEnvelope<{ ticketId: string; assignment: AssignmentResult }>;
}

/** Injection token for DI. */
export const MATCH_ASSIGNED_CHANNEL = 'MatchAssignedChannel' as const;

/**
 * Channel interface: publish (worker) + subscribe (API).
 * MatchmakingService calls publish; RealtimeGateway calls subscribe.
 */
export interface MatchAssignedChannel {
  publish(payload: MatchAssignedPayload): Promise<void>;
  subscribe(handler: (payload: MatchAssignedPayload) => void): void;
}
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Pass (new files, no breaking changes).

**Step 4: Commit**

```bash
git add Packages/control-plane/src/pubsub/
git commit -m "feat(pubsub): add MatchAssignedChannel interface and channel names"
```

---

## Task 2: Implement InMemoryMatchAssignedChannelService

**Files:**
- Create: `Packages/control-plane/src/pubsub/inmemory-match-assigned-channel.service.ts`
- Create: `Packages/control-plane/test/pubsub/inmemory-match-assigned-channel.spec.ts`

**Step 1: Write the failing test**

Create `Packages/control-plane/test/pubsub/inmemory-match-assigned-channel.spec.ts`:

```ts
import { Test, TestingModule } from '@nestjs/testing';
import { InMemoryMatchAssignedChannelService } from '../../src/pubsub/inmemory-match-assigned-channel.service';

describe('InMemoryMatchAssignedChannelService', () => {
  let service: InMemoryMatchAssignedChannelService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [InMemoryMatchAssignedChannelService],
    }).compile();
    service = module.get(InMemoryMatchAssignedChannelService);
  });

  it('delivers payload to subscriber when publish is called', async () => {
    const received: unknown[] = [];
    service.subscribe((p) => received.push(p));
    await service.publish({
      ticketId: 't1',
      envelope: { type: 'match.assigned', v: 1, data: { ticketId: 't1', assignment: {} } },
    });
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ ticketId: 't1' });
  });

  it('does nothing when no subscriber', async () => {
    await expect(service.publish({ ticketId: 't1', envelope: {} as never })).resolves.not.toThrow();
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/control-plane && npm test -- --testPathPattern=inmemory-match-assigned`
Expected: FAIL (InMemoryMatchAssignedChannelService not found or not implemented).

**Step 3: Implement InMemoryMatchAssignedChannelService**

Create `Packages/control-plane/src/pubsub/inmemory-match-assigned-channel.service.ts`:

```ts
import { Injectable } from '@nestjs/common';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

@Injectable()
export class InMemoryMatchAssignedChannelService implements MatchAssignedChannel {
  private handler: ((p: MatchAssignedPayload) => void) | null = null;

  async publish(payload: MatchAssignedPayload): Promise<void> {
    this.handler?.(payload);
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    this.handler = handler;
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd Packages/control-plane && npm test -- --testPathPattern=inmemory-match-assigned`
Expected: PASS.

**Step 5: Commit**

```bash
git add Packages/control-plane/src/pubsub/inmemory-match-assigned-channel.service.ts Packages/control-plane/test/pubsub/
git commit -m "feat(pubsub): add InMemoryMatchAssignedChannelService"
```

---

## Task 3: Implement RedisMatchAssignedChannelService

**Files:**
- Create: `Packages/control-plane/src/pubsub/redis-match-assigned-channel.service.ts`

**Step 1: Create Redis implementation**

Create `Packages/control-plane/src/pubsub/redis-match-assigned-channel.service.ts`:

```ts
import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { CHANNEL_NAMES } from './channels';
import { getMatchmakingRole, isApiEnabled } from '../matchmaking/matchmaking-role';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

@Injectable()
export class RedisMatchAssignedChannelService implements MatchAssignedChannel, OnModuleDestroy {
  private pubClient: Redis | null = null;
  private subClient: Redis | null = null;

  private getRedisConfig() {
    const host = process.env.REDIS_HOST ?? 'localhost';
    const port = parseInt(process.env.REDIS_PORT ?? '6379', 10);
    return { host, port };
  }

  private ensurePubClient(): Redis {
    if (!this.pubClient) {
      const { host, port } = this.getRedisConfig();
      this.pubClient = new Redis({ host, port });
    }
    return this.pubClient;
  }

  async publish(payload: MatchAssignedPayload): Promise<void> {
    const client = this.ensurePubClient();
    await client.publish(CHANNEL_NAMES.matchAssigned, JSON.stringify(payload));
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    if (!isApiEnabled(getMatchmakingRole())) return;
    const { host, port } = this.getRedisConfig();
    this.subClient = new Redis({ host, port });
    this.subClient.subscribe(CHANNEL_NAMES.matchAssigned);
    this.subClient.on('message', (_ch, msg) => {
      try {
        handler(JSON.parse(msg) as MatchAssignedPayload);
      } catch (e) {
        console.error('[MatchAssignedChannel] parse error:', e);
      }
    });
  }

  async onModuleDestroy(): Promise<void> {
    await this.pubClient?.quit();
    await this.subClient?.quit();
    this.pubClient = null;
    this.subClient = null;
  }
}
```

**Step 2: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Pass (Redis impl not yet wired, no integration test).

**Step 3: Commit**

```bash
git add Packages/control-plane/src/pubsub/redis-match-assigned-channel.service.ts
git commit -m "feat(pubsub): add RedisMatchAssignedChannelService"
```

---

## Task 4: Create PubSubModule and wire to app

**Files:**
- Create: `Packages/control-plane/src/pubsub/pubsub.module.ts`
- Modify: `Packages/control-plane/src/app.module.ts`

**Step 1: Create PubSubModule**

Create `Packages/control-plane/src/pubsub/pubsub.module.ts`:

```ts
import { Module } from '@nestjs/common';
import { MATCH_ASSIGNED_CHANNEL } from './match-assigned-channel.interface';
import { RedisMatchAssignedChannelService } from './redis-match-assigned-channel.service';

@Module({
  providers: [
    {
      provide: MATCH_ASSIGNED_CHANNEL,
      useClass: RedisMatchAssignedChannelService,
    },
  ],
  exports: [MATCH_ASSIGNED_CHANNEL],
})
export class PubSubModule {}
```

**Step 2: Import PubSubModule in AppModule**

Modify `Packages/control-plane/src/app.module.ts`:

```ts
import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { MatchmakingModule } from './matchmaking/matchmaking.module';
import { BullMQModule } from './bullmq/bullmq.module';
import { RealtimeModule } from './realtime/realtime.module';
import { PubSubModule } from './pubsub/pubsub.module';

@Module({
  imports: [BullMQModule, PubSubModule, RealtimeModule, MatchmakingModule],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Pass.

**Step 4: Commit**

```bash
git add Packages/control-plane/src/pubsub/pubsub.module.ts Packages/control-plane/src/app.module.ts
git commit -m "feat(pubsub): add PubSubModule and wire to AppModule"
```

---

## Task 5: RealtimeGateway subscribes to channel in onModuleInit

**Files:**
- Modify: `Packages/control-plane/src/realtime/realtime.gateway.ts`
- Modify: `Packages/control-plane/src/realtime/realtime.module.ts`

**Step 1: Add OnModuleInit and channel injection to RealtimeGateway**

Modify `Packages/control-plane/src/realtime/realtime.gateway.ts`:
- Add `OnModuleInit` to implements
- Add `@Inject(MATCH_ASSIGNED_CHANNEL) private readonly matchAssignedChannel: MatchAssignedChannel` to constructor
- Add `onModuleInit()` that calls `this.matchAssignedChannel.subscribe((payload) => this.pushMatchAssigned(payload.ticketId, payload.envelope))`

Full constructor and new method:

```ts
import { Inject, forwardRef } from '@nestjs/common';
import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Server, WebSocket as WsWebSocket } from 'ws';
import { IncomingMessage } from 'http';
import { MatchmakingService } from '../matchmaking/matchmaking.service';
import { MATCH_ASSIGNED_CHANNEL } from '../pubsub/match-assigned-channel.interface';
import type { MatchAssignedChannel } from '../pubsub/match-assigned-channel.interface';
import { buildEnqueuedEnvelope } from './ws-envelope.dto';
import type { WsEnqueueMessage } from './ws-envelope.dto';

// ... existing ticketSubscriptions, etc.

@WebSocketGateway({ path: '/realtime' })
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit {
  // ... existing @WebSocketServer

  constructor(
    @Inject(forwardRef(() => MatchmakingService))
    private readonly matchmakingService: MatchmakingService,
    @Inject(MATCH_ASSIGNED_CHANNEL)
    private readonly matchAssignedChannel: MatchAssignedChannel,
  ) {}

  onModuleInit(): void {
    this.matchAssignedChannel.subscribe((payload) => {
      this.pushMatchAssigned(payload.ticketId, payload.envelope);
    });
  }

  // ... rest unchanged
}
```

Add `OnModuleInit` to the import from `@nestjs/common`.

**Step 2: Import PubSubModule in RealtimeModule**

Modify `Packages/control-plane/src/realtime/realtime.module.ts`:

```ts
import { Module, forwardRef } from '@nestjs/common';
import { RealtimeGateway } from './realtime.gateway';
import { MatchmakingModule } from '../matchmaking/matchmaking.module';
import { PubSubModule } from '../pubsub/pubsub.module';

@Module({
  imports: [forwardRef(() => MatchmakingModule), PubSubModule],
  providers: [RealtimeGateway],
  exports: [RealtimeGateway],
})
export class RealtimeModule {}
```

**Step 3: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: May fail - MatchmakingService still uses RealtimeGateway, and tests may not provide MATCH_ASSIGNED_CHANNEL. Proceed to Task 6.

**Step 4: Commit**

```bash
git add Packages/control-plane/src/realtime/
git commit -m "feat(realtime): gateway subscribes to MatchAssignedChannel in onModuleInit"
```

---

## Task 6: MatchmakingService uses channel.publish instead of realtimeGateway.pushMatchAssigned

**Files:**
- Modify: `Packages/control-plane/src/matchmaking/matchmaking.service.ts`
- Modify: `Packages/control-plane/src/matchmaking/matchmaking.module.ts`
- Modify: `Packages/control-plane/test/matchmaking.service.spec.ts`
- Delete: `Packages/control-plane/src/matchmaking/match-assigned-pubsub.service.ts`

**Step 1: Update MatchmakingService**

In `Packages/control-plane/src/matchmaking/matchmaking.service.ts`:
- Remove `RealtimeGateway` import and constructor param
- Add `@Inject(MATCH_ASSIGNED_CHANNEL) private readonly matchAssignedChannel: MatchAssignedChannel`
- Replace `this.realtimeGateway.pushMatchAssigned(ticketId, buildMatchAssignedEnvelope(...))` with `await this.matchAssignedChannel.publish({ ticketId, envelope: buildMatchAssignedEnvelope(ticketId, assignment) })`

**Step 2: Import PubSubModule in MatchmakingModule**

In `Packages/control-plane/src/matchmaking/matchmaking.module.ts`:
- Add `import { PubSubModule } from '../pubsub/pubsub.module'`
- Add `PubSubModule` to imports array
- Remove `forwardRef(() => RealtimeModule)` from imports (MatchmakingService no longer needs RealtimeGateway)

**Step 3: Update matchmaking.service.spec.ts**

Replace `{ provide: RealtimeGateway, useValue: mockRealtimeGateway }` with:

```ts
import { MATCH_ASSIGNED_CHANNEL } from '../src/pubsub/match-assigned-channel.interface';

const mockMatchAssignedChannel = {
  publish: jest.fn().mockResolvedValue(undefined),
  subscribe: jest.fn(),
};

// In providers:
{ provide: MATCH_ASSIGNED_CHANNEL, useValue: mockMatchAssignedChannel },
```

Remove `mockRealtimeGateway` and its usage. Update any assertion that checks `pushMatchAssigned` to check `mockMatchAssignedChannel.publish` instead.

**Step 4: Delete match-assigned-pubsub.service.ts**

Delete `Packages/control-plane/src/matchmaking/match-assigned-pubsub.service.ts`.

Remove it from MatchmakingModule if it was ever registered (it is not in the current providers - it exists but is unused).

**Step 5: Run tests**

Run: `cd Packages/control-plane && npm test`
Expected: Pass.

**Step 6: Run e2e tests**

Run: `cd Packages/control-plane && npm run test:e2e -- --testPathPattern="matchmaking.controller|realtime" --runInBand`
Expected: Pass (matchmaking controller e2e; realtime e2e may have skipped test).

**Step 7: Commit**

```bash
git add Packages/control-plane/src/matchmaking/ Packages/control-plane/test/matchmaking.service.spec.ts
git rm Packages/control-plane/src/matchmaking/match-assigned-pubsub.service.ts
git commit -m "feat(matchmaking): use MatchAssignedChannel.publish instead of RealtimeGateway"
```

---

## Task 7: Update realtime e2e to use InMemory channel (optional, for flaky test)

**Files:**
- Modify: `Packages/control-plane/test/realtime.e2e-spec.ts`

**Step 1: Override MATCH_ASSIGNED_CHANNEL with InMemory in e2e**

In `Packages/control-plane/test/realtime.e2e-spec.ts`, add:

```ts
import { MATCH_ASSIGNED_CHANNEL } from '../src/pubsub/match-assigned-channel.interface';
import { InMemoryMatchAssignedChannelService } from '../src/pubsub/inmemory-match-assigned-channel.service';
```

In the `Test.createTestingModule` chain, add:

```ts
.overrideProvider(MATCH_ASSIGNED_CHANNEL)
.useClass(InMemoryMatchAssignedChannelService)
```

This allows the "enqueue via WebSocket then receives match.assigned" test to run without Redis pub/sub timing. Consider removing the `it.skip` if the test was skipped.

**Step 2: Run realtime e2e**

Run: `cd Packages/control-plane && npm run test:e2e -- --testPathPattern=realtime`
Expected: All realtime tests pass (including previously skipped one if un-skipped).

**Step 3: Commit**

```bash
git add Packages/control-plane/test/realtime.e2e-spec.ts
git commit -m "test(realtime): use InMemory channel in e2e for deterministic push"
```

---

## Task 8: Update README and verify full test suite

**Files:**
- Modify: `Packages/control-plane/README.md`

**Step 1: Update architecture diagram**

In README, ensure the diagram mentions Pub/Sub for match.assigned. The existing diagram already shows "MS | persist + publish | PubSub" and "PubSub | match.assigned | Sub". Update if the module name changed (e.g. "MatchAssignedChannel" or "PubSubModule").

**Step 2: Run full test suite**

Run: `cd Packages/control-plane && npm test && npm run test:e2e -- --runInBand`
Expected: All pass.

**Step 3: Commit**

```bash
git add Packages/control-plane/README.md
git commit -m "docs: update README for pubsub module"
```

---

## Execution Handoff

Plan complete and saved to `docs/plans/2026-02-15-pubsub-module-implementation-plan.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** - Dispatch fresh subagent per task, review between tasks, fast iteration
2. **Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?**
