import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-server-1',
    landId: 'standard:stub-room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { intervalMs: 50, minWaitMs: 0 };

async function waitForAssignment(
  getStatus: () => Promise<{ body: { status: string } }>,
  maxAttempts = 20,
): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    const res = await getStatus();
    if (res.body.status === 'assigned') return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error('Timed out waiting for assignment');
}

describe('MatchmakingController (e2e)', () => {
  let app: INestApplication;

  beforeEach(async () => {
    jest.clearAllMocks();
    mockProvisioning.allocate.mockResolvedValue({
      serverId: 'stub-server-1',
      landId: 'standard:stub-room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
      expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
    });

    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider('ProvisioningClientPort')
      .useValue(mockProvisioning)
      .overrideProvider('MatchmakingConfig')
      .useValue(testConfig)
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
    await app.init();
  });

  afterEach(async () => {
    await app.close();
  });

  it('POST /v1/matchmaking/enqueue returns queued, then status becomes assigned', async () => {
    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);
    expect(enqueueRes.body.ticketId).toBeDefined();
    expect(enqueueRes.body.status).toBe('queued');

    await waitForAssignment(() =>
      request(app.getHttpServer()).get(
        `/v1/matchmaking/status/${enqueueRes.body.ticketId}`,
      ),
    );
    const statusRes = await request(app.getHttpServer())
      .get(`/v1/matchmaking/status/${enqueueRes.body.ticketId}`)
      .expect(200);
    expect(statusRes.body.status).toBe('assigned');
    expect(statusRes.body.assignment).toBeDefined();
    expect(statusRes.body.assignment.connectUrl).toContain('ws');
    expect(statusRes.body.assignment.matchToken).toBeDefined();
  });

  it('POST /v1/matchmaking/cancel cancels queued ticket', async () => {
    const neverMatchStrategy = {
      findMatchableTickets: jest.fn().mockReturnValue([]),
    };
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider('ProvisioningClientPort')
      .useValue(mockProvisioning)
      .overrideProvider('MatchStrategyPort')
      .useValue(neverMatchStrategy)
      .overrideProvider('MatchmakingConfig')
      .useValue(testConfig)
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
    await testApp.init();

    const enqueueRes = await request(testApp.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);
    expect(enqueueRes.body.status).toBe('queued');

    const cancelRes = await request(testApp.getHttpServer())
      .post('/v1/matchmaking/cancel')
      .send({ ticketId: enqueueRes.body.ticketId })
      .expect(201);
    expect(cancelRes.body.cancelled).toBe(true);
    await testApp.close();
  });

  it('GET /v1/matchmaking/status/:ticketId returns status', async () => {
    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);

    await waitForAssignment(() =>
      request(app.getHttpServer()).get(
        `/v1/matchmaking/status/${enqueueRes.body.ticketId}`,
      ),
    );
    const statusRes = await request(app.getHttpServer())
      .get(`/v1/matchmaking/status/${enqueueRes.body.ticketId}`)
      .expect(200);
    expect(statusRes.body.ticketId).toBe(enqueueRes.body.ticketId);
    expect(statusRes.body.status).toBe('assigned');
    expect(statusRes.body.assignment).toBeDefined();
  });

  it('GET /v1/matchmaking/status/:ticketId returns 404 for unknown ticket', async () => {
    await request(app.getHttpServer())
      .get('/v1/matchmaking/status/unknown-ticket')
      .expect(404);
  });
});
