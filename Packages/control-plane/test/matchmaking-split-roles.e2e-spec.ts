/**
 * E2E test for api + queue-worker split deployment.
 * Uses two NestJS app instances in the same process: API (role=api) and queue-worker (role=queue-worker).
 * Verifies enqueue via API, processing by queue-worker, status via API.
 *
 * Requires: Redis running (docker compose up -d).
 * Run: npm run test:e2e -- --testPathPattern=matchmaking-split-roles
 */
import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import * as request from 'supertest';
import { WebSocket } from 'ws';
import { AppModule } from '../src/app.module';
import { closeApp } from './e2e-helpers';

const API_PORT = 3010;
const QUEUE_WORKER_PORT = 3011;
const testConfig = { minWaitMs: 0 };

async function createApp(role: 'api' | 'queue-worker'): Promise<INestApplication> {
  process.env.MATCHMAKING_ROLE = role;
  const moduleFixture: TestingModule = await Test.createTestingModule({
    imports: [AppModule],
  })
    .overrideProvider('MatchmakingConfig')
    .useValue(testConfig)
    .compile();

  const app = moduleFixture.createNestApplication();
  app.useWebSocketAdapter(new WsAdapter(app));
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );
  app.enableShutdownHooks();
  await app.init();
  return app;
}

async function waitForAssignment(
  apiApp: INestApplication,
  ticketId: string,
  maxAttempts = 60,
): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    const res = await request(apiApp.getHttpServer()).get(
      `/v1/matchmaking/status/${ticketId}`,
    );
    if (res.body?.status === 'assigned') return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('Timed out waiting for assignment');
}

describe('Matchmaking split roles (api + queue-worker) E2E', () => {
  let apiApp: INestApplication;
  let queueWorkerApp: INestApplication;

  beforeAll(async () => {
    apiApp = await createApp('api');
    queueWorkerApp = await createApp('queue-worker');
    await apiApp.listen(API_PORT);
    await queueWorkerApp.listen(QUEUE_WORKER_PORT);
  }, 15000);

  afterAll(async () => {
    await closeApp(apiApp);
    await closeApp(queueWorkerApp);
    delete process.env.MATCHMAKING_ROLE;
  });

  it('enqueue via API, process by queue-worker, status via API', async () => {
    await request(queueWorkerApp.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-split-1',
        host: '127.0.0.1',
        port: 8080,
        landType: 'standard',
      })
      .expect(200);

    const enqueueRes = await request(apiApp.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-split-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);

    expect(enqueueRes.body.ticketId).toBeDefined();
    expect(enqueueRes.body.status).toBe('queued');

    await waitForAssignment(apiApp, enqueueRes.body.ticketId);

    const statusRes = await request(apiApp.getHttpServer())
      .get(`/v1/matchmaking/status/${enqueueRes.body.ticketId}`)
      .expect(200);
    expect(statusRes.body.status).toBe('assigned');
    expect(statusRes.body.assignment).toBeDefined();
    expect(statusRes.body.assignment.connectUrl).toContain('ws');
    expect(statusRes.body.assignment.matchToken).toBeDefined();
  }, 15000);

  // Requires Redis pub/sub; flaky due to timing. See realtime.e2e-spec for working two-client WS test.
  it.skip('two WebSocket clients receive match.assigned when 2v2 matchmaking', async () => {
    // Reuse server from first test (game-split-1) - both use landType 'standard'
    // Use enqueue-via-WS flow so clients are subscribed before worker processes (avoids race)
    const wsUrl = `ws://127.0.0.1:${API_PORT}/realtime`;
    const messages1: { type: string; v?: number; data?: unknown }[] = [];
    const messages2: { type: string; v?: number; data?: unknown }[] = [];

    const ws1 = new WebSocket(wsUrl);
    const ws2 = new WebSocket(wsUrl);

    const open1 = new Promise<void>((resolve, reject) => {
      ws1.on('open', () => resolve());
      ws1.on('error', reject);
    });
    const open2 = new Promise<void>((resolve, reject) => {
      ws2.on('open', () => resolve());
      ws2.on('error', reject);
    });
    await Promise.all([open1, open2]);

    const done1 = new Promise<void>((resolve, reject) => {
      ws1.on('message', (buf) => {
        const msg = JSON.parse(buf.toString());
        messages1.push(msg);
        if (msg.type === 'error') reject(new Error(`Client 1 error: ${(msg as { message?: string }).message}`));
        if (msg.type === 'match.assigned') resolve();
      });
      ws1.on('error', reject);
    });
    const done2 = new Promise<void>((resolve, reject) => {
      ws2.on('message', (buf) => {
        const msg = JSON.parse(buf.toString());
        messages2.push(msg);
        if (msg.type === 'error') reject(new Error(`Client 2 error: ${(msg as { message?: string }).message}`));
        if (msg.type === 'match.assigned') resolve();
      });
      ws2.on('error', reject);
    });

    ws1.send(
      JSON.stringify({
        action: 'enqueue',
        queueKey: 'standard:2v2',
        groupId: 'solo-2v2-p1',
        members: ['p1'],
        groupSize: 1,
      }),
    );
    ws2.send(
      JSON.stringify({
        action: 'enqueue',
        queueKey: 'standard:2v2',
        groupId: 'solo-2v2-p2',
        members: ['p2'],
        groupSize: 1,
      }),
    );

    try {
      await Promise.all([
        Promise.race([
          done1,
          new Promise<never>((_, reject) =>
            setTimeout(
              () =>
                reject(
                  new Error(
                    `Timeout client 1. Received: ${JSON.stringify(messages1)}`,
                  ),
                ),
              20000,
            ),
          ),
        ]),
        Promise.race([
          done2,
          new Promise<never>((_, reject) =>
            setTimeout(
              () =>
                reject(
                  new Error(
                    `Timeout client 2. Received: ${JSON.stringify(messages2)}`,
                  ),
                ),
              20000,
            ),
          ),
        ]),
      ]);
    } finally {
      ws1.close();
      ws2.close();
    }

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
    expect(data1.assignment.landId).toBe(data2.assignment.landId);
    expect(data1.assignment.matchToken).not.toBe(data2.assignment.matchToken);
  }, 25000);
});
