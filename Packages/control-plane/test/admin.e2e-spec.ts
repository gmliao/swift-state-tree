import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';
import { closeApp, flushServerKeys } from './e2e-helpers';

const testConfig = { intervalMs: 100, minWaitMs: 0 };

/**
 * E2E tests for admin API (read-only dashboard endpoints).
 * Uses beforeAll/afterAll to avoid BullMQ "Connection is closed" during rapid app lifecycle.
 * Trade-off: tests share app state; test order matters (test 1 expects empty servers).
 */
describe('AdminController (e2e)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    await flushServerKeys();
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

  afterAll(async () => {
    await closeApp(app);
    await flushServerKeys();
  });

  it('GET /v1/admin/servers returns empty list when no servers', async () => {
    const res = await request(app.getHttpServer())
      .get('/v1/admin/servers')
      .expect(200);
    expect(res.body.servers).toEqual([]);
  });

  it('GET /v1/admin/servers returns registered servers', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-admin-1',
        host: '127.0.0.1',
        port: 8080,
        landType: 'hero-defense',
      })
      .expect(200);

    const res = await request(app.getHttpServer())
      .get('/v1/admin/servers')
      .expect(200);
    expect(res.body.servers).toHaveLength(1);
    expect(res.body.servers[0]).toMatchObject({
      serverId: 'game-admin-1',
      host: '127.0.0.1',
      port: 8080,
      landType: 'hero-defense',
      isStale: false,
    });
    expect(res.body.servers[0]).toHaveProperty('registeredAt');
    expect(res.body.servers[0]).toHaveProperty('lastSeenAt');
  });

  it('GET /v1/admin/queue/summary returns summary shape', async () => {
    const res = await request(app.getHttpServer())
      .get('/v1/admin/queue/summary')
      .expect(200);
    expect(res.body).toHaveProperty('queueKeys');
    expect(res.body).toHaveProperty('byQueueKey');
    expect(Array.isArray(res.body.queueKeys)).toBe(true);
    expect(typeof res.body.byQueueKey).toBe('object');
  });

  it('GET /v1/admin/queue/summary returns valid structure after enqueue', async () => {
    await request(app.getHttpServer())
      .post('/v1/provisioning/servers/register')
      .send({
        serverId: 'game-q',
        host: '127.0.0.1',
        port: 8080,
        landType: 'hero-defense',
      })
      .expect(200);

    await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send({
        groupId: 'g-queue-test',
        queueKey: 'hero-defense:asia',
        members: ['p1'],
        groupSize: 1,
      })
      .expect(201);

    const res = await request(app.getHttpServer())
      .get('/v1/admin/queue/summary')
      .expect(200);
    expect(res.body.queueKeys).toBeDefined();
    expect(res.body.byQueueKey).toBeDefined();
    expect(Array.isArray(res.body.queueKeys)).toBe(true);
    for (const k of res.body.queueKeys) {
      expect(res.body.byQueueKey[k]).toMatchObject({ queuedCount: expect.any(Number) });
    }
  });
});
