import { Test, TestingModule } from '@nestjs/testing';
import { MatchmakingService } from '../src/matchmaking/matchmaking.service';
import { InMemoryMatchStorage } from '../src/storage/inmemory-match-storage';
import { DefaultMatchStrategy } from '../src/matchmaking/strategies/default.strategy';
import { JwtIssuerService } from '../src/security/jwt-issuer.service';

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-server-1',
    landId: 'standard:stub-room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { intervalMs: 100, minWaitMs: 0 };

describe('Assignment Flow', () => {
  let service: MatchmakingService;

  beforeEach(async () => {
    jest.clearAllMocks();
    mockProvisioning.allocate.mockResolvedValue({
      serverId: 'stub-server-1',
      landId: 'standard:stub-room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
      expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
    });

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        MatchmakingService,
        { provide: 'MatchStoragePort', useClass: InMemoryMatchStorage },
        { provide: 'MatchStrategyPort', useClass: DefaultMatchStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        JwtIssuerService,
      ],
    }).compile();

    service = module.get<MatchmakingService>(MatchmakingService);
  });

  it('creates assignment and returns connect info from provisioning client', async () => {
    const group = {
      groupId: 'solo-p1',
      queueKey: 'standard:asia',
      members: ['p1'],
      groupSize: 1,
    };
    const result = await service.enqueue(group);
    expect(result.status).toBe('queued');
    await service.runMatchmakingTick();
    const status = await service.getStatus(result.ticketId);
    expect(status.status).toBe('assigned');
    expect(status.assignment).toBeDefined();
    expect(status.assignment!.connectUrl).toContain('ws');
    expect(status.assignment!.assignmentId).toBeDefined();
    expect(status.assignment!.landId).toBeDefined();
    expect(status.assignment!.matchToken).toBeDefined();
    expect(status.assignment!.matchToken.split('.').length).toBe(3);
  });
});
