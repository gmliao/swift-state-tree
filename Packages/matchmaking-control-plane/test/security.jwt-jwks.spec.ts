import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import * as request from 'supertest';
import { JwtIssuerService } from '../src/security/jwt-issuer.service';
import { JwksController } from '../src/security/jwks.controller';

describe('Security JWT/JWKS', () => {
  let app: INestApplication;
  let issuer: JwtIssuerService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [JwksController],
      providers: [JwtIssuerService],
    }).compile();

    app = module.createNestApplication();
    await app.init();
    issuer = module.get<JwtIssuerService>(JwtIssuerService);
  });

  afterEach(async () => {
    await app.close();
  });

  it('issues RS256 token with assignment claims', async () => {
    const payload = {
      assignmentId: 'assign-1',
      playerId: 'p1',
      landId: 'standard:room-1',
      exp: Math.floor(Date.now() / 1000) + 3600,
      jti: 'assign-1',
    };
    const token = await issuer.issue(payload);
    expect(token.split('.').length).toBe(3);
  });

  it('exposes JWKS endpoint', async () => {
    const res = await request(app.getHttpServer())
      .get('/.well-known/jwks.json')
      .expect(200);
    expect(res.body.keys).toBeDefined();
    expect(Array.isArray(res.body.keys)).toBe(true);
    expect(res.body.keys.length).toBeGreaterThan(0);
    expect(res.body.keys[0].kid).toBe('mm-dev-1');
    expect(res.body.keys[0].alg).toBe('RS256');
  });
});
