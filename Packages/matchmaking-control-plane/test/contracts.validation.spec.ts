import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication, ValidationPipe } from '@nestjs/common';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

describe('Contracts Validation', () => {
  let app: INestApplication;

  beforeEach(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
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

  it('rejects enqueue request without queueKey', async () => {
    const body = { groupId: 'g1', members: ['p1'], groupSize: 1 };
    await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send(body)
      .expect(400);
  });

  it('rejects enqueue request without groupId', async () => {
    const body = { queueKey: 'standard:asia', members: ['p1'], groupSize: 1 };
    await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send(body)
      .expect(400);
  });

  it('rejects enqueue request without members', async () => {
    const body = { queueKey: 'standard:asia', groupId: 'g1', groupSize: 1 };
    await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send(body)
      .expect(400);
  });

  it('rejects enqueue request without groupSize', async () => {
    const body = { queueKey: 'standard:asia', groupId: 'g1', members: ['p1'] };
    await request(app.getHttpServer())
      .post('/v1/matchmaking/enqueue')
      .send(body)
      .expect(400);
  });
});
