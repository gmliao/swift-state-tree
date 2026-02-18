import { Test } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import * as request from 'supertest';
import { WebSocket } from 'ws';
import { AppModule } from '../src/app.module';
import { closeApp } from './e2e-helpers';
import { MATCH_ASSIGNED_CHANNEL } from '../src/infra/channels/match-assigned-channel.interface';
import { InMemoryMatchAssignedChannelService } from '../src/infra/channels/inmemory-match-assigned-channel.service';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';
import { InMemoryNodeInboxChannelService } from '../src/infra/channels/inmemory-node-inbox-channel.service';
import { CLUSTER_DIRECTORY } from '../src/infra/cluster-directory/cluster-directory.interface';
import { InMemoryClusterDirectoryService } from '../src/infra/cluster-directory/inmemory-cluster-directory.service';
import { MatchmakingService } from '../src/modules/matchmaking/matchmaking.service';
import { InMemoryMatchQueue } from '../src/modules/matchmaking/storage/inmemory-match-queue';

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-1',
    landId: 'standard:room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:room-1',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { minWaitMs: 0 };

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
      .overrideProvider(MATCH_ASSIGNED_CHANNEL)
      .useClass(InMemoryMatchAssignedChannelService)
      .overrideProvider(NODE_INBOX_CHANNEL)
      .useClass(InMemoryNodeInboxChannelService)
      .overrideProvider(CLUSTER_DIRECTORY)
      .useClass(InMemoryClusterDirectoryService)
      .compile();

    app = moduleFixture.createNestApplication();
    app.useWebSocketAdapter(new WsAdapter(app));
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    app.enableShutdownHooks();
    await app.listen(0);
    port = (app.getHttpServer().address() as { port: number }).port;
  });

  afterEach(async () => {
    await closeApp(app);
  });

  it('accepts WebSocket connection without ticketId (for enqueue-via-WS flow)', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/realtime`);

    await new Promise<void>((resolve, reject) => {
      ws.on('open', () => resolve());
      ws.on('error', reject);
      ws.on('close', (code) => {
        if (code !== 1000 && code !== 1005) reject(new Error(`Unexpected close: ${code}`));
      });
    });

    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.close();
  });

  it('accepts WebSocket connection with ticketId', async () => {
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
    const ws = new WebSocket(`ws://127.0.0.1:${port}/realtime?ticketId=${ticketId}`);

    await new Promise<void>((resolve, reject) => {
      ws.on('open', () => resolve());
      ws.on('error', reject);
      ws.on('close', (code) => {
        if (code !== 1000 && code !== 1005) reject(new Error(`Unexpected close: ${code}`));
      });
    });

    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.close();
  });

  // Requires Redis (BullMQ). With InMemory channel override, match.assigned delivery is synchronous (no race).
  it.skip('enqueue via WebSocket then receives match.assigned (single client)', async () => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/realtime`);

    await new Promise<void>((resolve, reject) => {
      ws.on('open', () => resolve());
      ws.on('error', reject);
    });

    ws.send(
      JSON.stringify({
        action: 'enqueue',
        queueKey: 'standard:asia',
        members: ['p-ws'],
        groupSize: 1,
      }),
    );

    const messages: { type: string; v?: number; data?: unknown }[] = [];
    const done = new Promise<void>((resolve, reject) => {
      const t = setTimeout(
        () => reject(new Error('Timeout waiting for match.assigned')),
        15000,
      );
      ws.on('message', (buf) => {
        const msg = JSON.parse(buf.toString());
        messages.push(msg);
        if (msg.type === 'enqueued') {
          expect(msg.data).toMatchObject({ status: 'queued', ticketId: expect.any(String) });
        }
        if (msg.type === 'match.assigned') {
          clearTimeout(t);
          resolve();
        }
      });
      ws.on('error', reject);
    });

    await done;
    ws.close();

    const assigned = messages.find((m) => m.type === 'match.assigned');
    expect(assigned).toBeDefined();
    expect(assigned!.v).toBe(1);
    expect(assigned!.data).toMatchObject({
      ticketId: expect.any(String),
      assignment: expect.objectContaining({
        connectUrl: expect.any(String),
        matchToken: expect.any(String),
        landId: expect.any(String),
      }),
    });
  });

  /**
   * Verifies two WebSocket clients each receive match.assigned.
   * Uses InMemoryMatchQueue + MATCHMAKING_ROLE=api to avoid BullMQ; triggers match via runMatchmakingTick().
   * Uses standard:asia (1v1) so each solo matches independently.
   */
  it('two WebSocket clients receive match.assigned when matchmaking', async () => {
    const prevRole = process.env.MATCHMAKING_ROLE;
    process.env.MATCHMAKING_ROLE = 'api';

    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider('ProvisioningClientPort')
      .useValue(mockProvisioning)
      .overrideProvider('MatchmakingConfig')
      .useValue(testConfig)
      .overrideProvider('MatchQueue')
      .useClass(InMemoryMatchQueue)
      .overrideProvider(MATCH_ASSIGNED_CHANNEL)
      .useClass(InMemoryMatchAssignedChannelService)
      .overrideProvider(NODE_INBOX_CHANNEL)
      .useClass(InMemoryNodeInboxChannelService)
      .overrideProvider(CLUSTER_DIRECTORY)
      .useClass(InMemoryClusterDirectoryService)
      .compile();

    const testApp = moduleFixture.createNestApplication();
    testApp.useWebSocketAdapter(new WsAdapter(testApp));
    testApp.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    testApp.enableShutdownHooks();
    await testApp.listen(0);
    const testPort = (testApp.getHttpServer().address() as { port: number }).port;

    try {
      const wsUrl = `ws://127.0.0.1:${testPort}/realtime`;
      const messages1: { type: string; v?: number; data?: unknown }[] = [];
      const messages2: { type: string; v?: number; data?: unknown }[] = [];

      const ws1 = new WebSocket(wsUrl);
      const ws2 = new WebSocket(wsUrl);

      await Promise.all([
        new Promise<void>((resolve, reject) => {
          ws1.on('open', () => resolve());
          ws1.on('error', reject);
        }),
        new Promise<void>((resolve, reject) => {
          ws2.on('open', () => resolve());
          ws2.on('error', reject);
        }),
      ]);

      const done1 = new Promise<void>((resolve, reject) => {
        ws1.on('message', (buf) => {
          const msg = JSON.parse(buf.toString());
          messages1.push(msg);
          if (msg.type === 'error') reject(new Error(`Client 1: ${(msg as { message?: string }).message}`));
          if (msg.type === 'match.assigned') resolve();
        });
        ws1.on('error', reject);
      });
      const done2 = new Promise<void>((resolve, reject) => {
        ws2.on('message', (buf) => {
          const msg = JSON.parse(buf.toString());
          messages2.push(msg);
          if (msg.type === 'error') reject(new Error(`Client 2: ${(msg as { message?: string }).message}`));
          if (msg.type === 'match.assigned') resolve();
        });
        ws2.on('error', reject);
      });

      ws1.send(
        JSON.stringify({
          action: 'enqueue',
          queueKey: 'standard:asia',
          groupId: 'solo-p1',
          members: ['p1'],
          groupSize: 1,
        }),
      );
      ws2.send(
        JSON.stringify({
          action: 'enqueue',
          queueKey: 'standard:asia',
          groupId: 'solo-p2',
          members: ['p2'],
          groupSize: 1,
        }),
      );

      await new Promise((r) => setTimeout(r, 200));

      const matchmakingService = testApp.get(MatchmakingService);
      await matchmakingService.runMatchmakingTick();

      await Promise.all([
        Promise.race([
          done1,
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error('Timeout client 1')), 5000),
          ),
        ]),
        Promise.race([
          done2,
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error('Timeout client 2')), 5000),
          ),
        ]),
      ]);

      ws1.close();
      ws2.close();

      const assigned1 = messages1.find((m) => m.type === 'match.assigned');
      const assigned2 = messages2.find((m) => m.type === 'match.assigned');
      expect(assigned1).toBeDefined();
      expect(assigned2).toBeDefined();
      expect(assigned1!.v).toBe(1);
      expect(assigned2!.v).toBe(1);

      const data1 = assigned1!.data as {
        ticketId: string;
        assignment: { connectUrl: string; matchToken: string; landId: string };
      };
      const data2 = assigned2!.data as {
        ticketId: string;
        assignment: { connectUrl: string; matchToken: string; landId: string };
      };
      expect(data1.ticketId).toBeDefined();
      expect(data2.ticketId).toBeDefined();
      expect(data1.ticketId).not.toBe(data2.ticketId);
      expect(data1.assignment.connectUrl).toContain('ws');
      expect(data2.assignment.connectUrl).toContain('ws');
      expect(data1.assignment.matchToken).not.toBe(data2.assignment.matchToken);
    } finally {
      await closeApp(testApp);
      if (prevRole !== undefined) process.env.MATCHMAKING_ROLE = prevRole;
      else delete process.env.MATCHMAKING_ROLE;
    }
  }, 15000);
});
