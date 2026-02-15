import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import { WsAdapter } from '@nestjs/platform-ws';
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
    app.useWebSocketAdapter(new WsAdapter(app));
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
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

    const envelope = await new Promise<{ type: string; v: number; data: unknown }>(
      (resolve, reject) => {
        const t = setTimeout(
          () => reject(new Error('Timeout waiting for WS message')),
          5000,
        );
        ws.on('message', (buf) => {
          clearTimeout(t);
          resolve(JSON.parse(buf.toString()));
        });
        ws.on('error', reject);
      },
    );

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
