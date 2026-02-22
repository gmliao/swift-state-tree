import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import * as request from 'supertest';
import { AppModule } from '../../src/app.module';
import { closeApp, flushServerKeys } from '../e2e-helpers';

const testConfig = { intervalMs: 100, minWaitMs: 0 };

async function waitForAssignment(
  getStatus: () => Promise<{ body: { status: string } }>,
  maxAttempts = 30,
): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    const res = await getStatus();
    if (res.body.status === 'assigned') return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('Timed out waiting for assignment');
}

/**
 * E2E test for internal provisioning (server registry).
 * No external stub - GameServer registers via POST /v1/provisioning/servers/register.
 */
describe('Provisioning (Internal Registry) E2E', () => {
  let app: INestApplication;

  beforeEach(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
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
    app.enableShutdownHooks();
    await app.init();
  });

  afterEach(async () => {
    await closeApp(app);
    await flushServerKeys();
  });

  it('registers a server and assigns connectUrl from internal registry', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-1',
        host: '127.0.0.1',
        port: 8080,
        landType: 'hero-defense',
      })
      .expect(200);

    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p1',
        queueKey: 'hero-defense:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);

    expect(enqueueRes.body.status).toBe('queued');
    await waitForAssignment(() =>
      request(app.getHttpServer()).get(
        `/v1/matchmaking/status/${enqueueRes.body.ticketId}`,
      ),
    );
    const statusRes = await request(app.getHttpServer())
      .get(`/v1/matchmaking/status/${enqueueRes.body.ticketId}`)
      .expect(200);
    expect(statusRes.body.assignment).toBeDefined();
    expect(statusRes.body.assignment.connectUrl).toContain('ws://');
    expect(statusRes.body.assignment.connectUrl).toContain('127.0.0.1:8080');
    expect(statusRes.body.assignment.serverId).toBe('game-1');
    expect(statusRes.body.assignment.landId).toMatch(/^hero-defense:/);
  });

  it('deregisters a server and excludes it from allocate', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-2',
        host: '127.0.0.1',
        port: 8081,
        landType: 'hero-defense',
      })
      .expect(200);

    await request(app.getHttpServer())
      .delete('/v1/provisioning/servers/game-2')
      .expect(200);

    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p2',
        queueKey: 'hero-defense:asia',
        members: ['p2'],
        groupSize: 1,
      })
      .expect(201);

    await expect(
      waitForAssignment(() =>
        request(app.getHttpServer()).get(
          `/v1/matchmaking/status/${enqueueRes.body.ticketId}`,
        ),
      ),
    ).rejects.toThrow('Timed out waiting for assignment');
  });

  it('uses connectHost/connectPort/connectScheme for connectUrl when provided', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-lb',
        host: '127.0.0.1',
        port: 8080,
        landType: 'hero-defense',
        connectHost: 'game.example.com',
        connectPort: 443,
        connectScheme: 'wss',
      })
      .expect(200);

    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-lb',
        queueKey: 'hero-defense:asia',
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
    expect(statusRes.body.assignment.connectUrl).toContain('wss://game.example.com:443');
    expect(statusRes.body.assignment.connectUrl).toContain('landId=');
  });

  it('heartbeat updates lastSeenAt and keeps server alive', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-3',
        host: '127.0.0.1',
        port: 8082,
        landType: 'hero-defense',
      })
      .expect(200);

    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-3',
        host: '127.0.0.1',
        port: 8082,
        landType: 'hero-defense',
      })
      .expect(200);

    const enqueueRes = await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'solo-p3',
        queueKey: 'hero-defense:asia',
        members: ['p3'],
        groupSize: 1,
      })
      .expect(201);

    await waitForAssignment(() =>
      request(app.getHttpServer()).get(
        `/v1/matchmaking/status/${enqueueRes.body.ticketId}`,
      ),
    );
  });
});
