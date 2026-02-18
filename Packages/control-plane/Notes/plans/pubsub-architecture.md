# Pub/Sub Architecture Plan: Type-Safe, Testable

## Goals

1. **Type-safe**: Channel names and payloads are strongly typed
2. **Unit testable**: No Redis in tests; inject mock/in-memory implementation
3. **Gateway integrates pub/sub**: Gateway subscribes and pushes; clear responsibility boundary

---

## 1. Channel Interface（頻道介面）

```ts
// src/pubsub/match-assigned-channel.interface.ts

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

---

## 2. Channel Registry (Type-Safe, Extensible)

```ts
// src/pubsub/channels.ts

export const CHANNEL_NAMES = {
  matchAssigned: 'matchmaking:assigned',
} as const;
```

---

## 3. Implementations

### 3.1 Redis (Production)

```ts
// src/pubsub/redis-match-assigned-channel.service.ts

@Injectable()
export class RedisMatchAssignedChannelService
  implements MatchAssignedChannel, OnModuleDestroy
{
  private pubClient: Redis | null = null;
  private subClient: Redis | null = null;

  onModuleInit(): void {
    this.pubClient = new Redis({ host, port });
    // subClient created when subscribe() is called (lazy)
  }

  async publish(payload: MatchAssignedPayload): Promise<void> {
    await this.pubClient!.publish(CHANNEL_NAMES.matchAssigned, JSON.stringify(payload));
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    if (!isApiEnabled(getMatchmakingRole())) return;
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
}
```

### 3.2 In-Memory (Tests)

```ts
// src/pubsub/inmemory-match-assigned-channel.service.ts

@Injectable()
export class InMemoryMatchAssignedChannelService implements MatchAssignedChannel {
  private handler: ((p: MatchAssignedPayload) => void) | null = null;

  async publish(payload: MatchAssignedPayload): Promise<void> {
    this.handler?.(payload);  // Same process: immediate delivery
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    this.handler = handler;
  }
}
```

---

## 4. RealtimeGateway 整合 Pub/Sub

Gateway 在啟動時訂閱 channel，收到訊息時 push 給 WebSocket clients。

```ts
// src/realtime/realtime.gateway.ts

@WebSocketGateway({ path: '/realtime' })
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit {
  constructor(
    @Inject(MATCH_ASSIGNED_CHANNEL)
    private readonly matchAssignedChannel: MatchAssignedChannel,
    // ... MatchmakingService for enqueue
  ) {}

  onModuleInit(): void {
    this.matchAssignedChannel.subscribe((payload) => {
      this.pushMatchAssigned(payload.ticketId, payload.envelope);
    });
  }

  pushMatchAssigned(ticketId: string, envelope: object): void {
    // ... existing logic
  }
}
```

- **Gateway 職責**：管理 WS 連線 + 訂閱 match.assigned 並 push
- **MatchmakingService 職責**：assign 完成時 publish

---

## 5. MatchmakingService Changes

```ts
// Before
this.realtimeGateway.pushMatchAssigned(ticketId, envelope);

// After
await this.matchAssignedChannel.publish({ ticketId, envelope });
```

- Inject `@Inject(MATCH_ASSIGNED_CHANNEL) matchAssignedChannel: MatchAssignedChannel`
- Remove `RealtimeGateway` dependency from MatchmakingService

---

## 6. Module Wiring

```ts
// src/pubsub/pubsub.module.ts

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

Tests: `overrideProvider(MATCH_ASSIGNED_CHANNEL).useClass(InMemoryMatchAssignedChannelService)`

---

## 7. File Structure

```
src/
  pubsub/
    channels.ts
    match-assigned-channel.interface.ts
    redis-match-assigned-channel.service.ts
    inmemory-match-assigned-channel.service.ts
    pubsub.module.ts
  realtime/
    realtime.gateway.ts   # 新增 onModuleInit，訂閱 channel
```

---

## 8. Unit Test Example

```ts
// matchmaking.service.spec.ts
const mockChannel: MatchAssignedChannel = {
  publish: jest.fn().mockResolvedValue(undefined),
  subscribe: jest.fn(),
};

.overrideProvider(MATCH_ASSIGNED_CHANNEL)
.useValue(mockChannel)

expect(mockChannel.publish).toHaveBeenCalledWith(
  expect.objectContaining({
    ticketId: expect.any(String),
    envelope: expect.objectContaining({ type: 'match.assigned' }),
  }),
);
```

```ts
// realtime.gateway.spec.ts - 驗證有訂閱
expect(mockChannel.subscribe).toHaveBeenCalledWith(expect.any(Function));
```
