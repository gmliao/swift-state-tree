/**
 * E2E test that uses @swiftstatetree/control-plane-client SDK against a running control-plane.
 * Boots the app with listen(0), then exercises ControlPlaneClient (enqueue, getStatus, getServers,
 * getQueueSummary) and asserts assignment via polling. findMatch() is covered by unit tests with mocks.
 */
import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import { ControlPlaneClient } from '@swiftstatetree/control-plane-client';
import { MATCH_ASSIGNED_CHANNEL } from '../src/infra/channels/match-assigned-channel.interface';
import { InMemoryMatchAssignedChannelService } from '../src/infra/channels/inmemory-match-assigned-channel.service';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';
import { InMemoryNodeInboxChannelService } from '../src/infra/channels/inmemory-node-inbox-channel.service';
import { USER_ID_DIRECTORY } from '../src/infra/cluster-directory/user-id-directory.interface';
import { InMemoryUserIdDirectoryService } from '../src/infra/cluster-directory/inmemory-user-id-directory.service';
import { AppModule } from '../src/app.module';
import { closeApp } from './e2e-helpers';

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-1',
    landId: 'standard:room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:room-1',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { intervalMs: 50, minWaitMs: 0 };

describe('Control Plane SDK (e2e)', () => {
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

    const moduleFixture: TestingModule = await Test.createTestingModule({
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
      .overrideProvider(USER_ID_DIRECTORY)
      .useClass(InMemoryUserIdDirectoryService)
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

  it('SDK enqueue then poll getStatus until assigned returns assignment', async () => {
    const baseUrl = `http://127.0.0.1:${port}`;
    const client = new ControlPlaneClient(baseUrl);

    const enqueueRes = await client.enqueue({
      queueKey: 'standard:asia',
      members: ['p1'],
      groupSize: 1,
    });
    expect(enqueueRes.status).toBe('queued');

    let assignment: Awaited<ReturnType<typeof client.getStatus>>['assignment'];
    const deadline = Date.now() + 10_000;
    while (Date.now() < deadline) {
      const status = await client.getStatus(enqueueRes.ticketId);
      if (status.status === 'assigned' && status.assignment) {
        assignment = status.assignment;
        break;
      }
      if (status.status === 'cancelled' || status.status === 'expired') {
        throw new Error(`Ticket ${status.status}`);
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    expect(assignment).toBeDefined();
    expect(assignment!.assignmentId).toBeDefined();
    expect(assignment!.matchToken).toBeDefined();
    expect(assignment!.connectUrl).toContain('ws://');
    expect(assignment!.connectUrl).toContain('landId=');
    expect(assignment!.landId).toBeDefined();
    expect(assignment!.serverId).toBeDefined();
    expect(assignment!.expiresAt).toBeDefined();
  }, 15_000);

  it('ControlPlaneClient enqueue, getStatus, getServers, getQueueSummary work against live app', async () => {
    const baseUrl = `http://127.0.0.1:${port}`;
    const client = new ControlPlaneClient(baseUrl);

    const enqueueRes = await client.enqueue({
      queueKey: 'standard:asia',
      members: ['p2'],
      groupSize: 1,
    });
    expect(enqueueRes.ticketId).toBeDefined();
    expect(enqueueRes.status).toBe('queued');

    const status = await client.getStatus(enqueueRes.ticketId);
    expect(status.ticketId).toBe(enqueueRes.ticketId);
    expect(['queued', 'assigned']).toContain(status.status);

    const servers = await client.getServers();
    expect(servers.servers).toBeDefined();
    expect(Array.isArray(servers.servers)).toBe(true);

    const summary = await client.getQueueSummary();
    expect(summary.queueKeys).toBeDefined();
    expect(summary.byQueueKey).toBeDefined();
  });
});
