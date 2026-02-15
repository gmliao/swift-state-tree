import { getQueueToken } from '@nestjs/bullmq';
import { Test, TestingModule } from '@nestjs/testing';
import { MatchmakingService } from '../src/matchmaking/matchmaking.service';
import { RealtimeGateway } from '../src/realtime/realtime.gateway';
import { InMemoryMatchStorage } from '../src/storage/inmemory-match-storage';
import { DefaultMatchStrategy } from '../src/matchmaking/strategies/default.strategy';
import { JwtIssuerService } from '../src/security/jwt-issuer.service';

const mockTickQueue = {
  add: jest.fn().mockResolvedValue({}),
  removeRepeatable: jest.fn().mockResolvedValue(undefined),
};

const mockRealtimeGateway = {
  pushMatchAssigned: jest.fn(),
};

const mockProvisioning = {
  allocate: jest.fn().mockResolvedValue({
    serverId: 'stub-server-1',
    landId: 'standard:stub-room-1',
    connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
    assignmentId: 'assign-1',
    matchToken: '',
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { intervalMs: 100, minWaitMs: 0 };

describe('MatchmakingService', () => {
  let service: MatchmakingService;
  const base = {
    groupId: 'solo-p1',
    queueKey: 'standard:asia',
    members: ['p1'],
    groupSize: 1,
  };
  const baseParty = {
    groupId: 'party-g1',
    queueKey: 'standard:asia',
    members: ['p1', 'p2', 'p3'],
    groupSize: 3,
  };

  beforeEach(async () => {
    jest.clearAllMocks();
    mockProvisioning.allocate.mockResolvedValue({
      serverId: 'stub-server-1',
      landId: 'standard:stub-room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/standard?landId=standard:stub-room-1',
      assignmentId: 'assign-1',
      matchToken: '',
      expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
    });

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        MatchmakingService,
        { provide: 'MatchStoragePort', useClass: InMemoryMatchStorage },
        { provide: 'MatchStrategyPort', useClass: DefaultMatchStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        { provide: getQueueToken('matchmaking-tick'), useValue: mockTickQueue },
        { provide: RealtimeGateway, useValue: mockRealtimeGateway },
        JwtIssuerService,
      ],
    }).compile();

    service = module.get<MatchmakingService>(MatchmakingService);
  });

  it('supports solo and party by same MatchGroup model', async () => {
    const solo = await service.enqueue(base);
    const party = await service.enqueue(baseParty);
    expect(solo).toBeDefined();
    expect(party).toBeDefined();
    expect(solo.status).toBe('queued');
    expect(party.status).toBe('queued');
  });

  it('assigns after matchmaking tick when minWaitMs is 0', async () => {
    const result = await service.enqueue(base);
    expect(result.status).toBe('queued');
    await service.runMatchmakingTick();
    const status = await service.getStatus(result.ticketId);
    expect(status.status).toBe('assigned');
    expect(status.assignment).toBeDefined();
    expect(status.assignment!.connectUrl).toContain('ws://');
    expect(status.assignment!.landId).toBe('standard:stub-room-1');
  });

  it('cancels queued ticket', async () => {
    const neverMatchStrategy = {
      findMatchableTickets: jest.fn().mockReturnValue([]),
    };
    const storage = new InMemoryMatchStorage();
    const module = await Test.createTestingModule({
      providers: [
        MatchmakingService,
        { provide: 'MatchStoragePort', useValue: storage },
        { provide: 'MatchStrategyPort', useValue: neverMatchStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        { provide: getQueueToken('matchmaking-tick'), useValue: mockTickQueue },
        { provide: RealtimeGateway, useValue: mockRealtimeGateway },
        JwtIssuerService,
      ],
    }).compile();
    const svc = module.get<MatchmakingService>(MatchmakingService);
    const enqueueResult = await svc.enqueue(base);
    expect(enqueueResult.status).toBe('queued');
    const cancelResult = await svc.cancel(enqueueResult.ticketId);
    expect(cancelResult.cancelled).toBe(true);
  });

  it('returns status for ticket', async () => {
    const enqueueResult = await service.enqueue(base);
    await service.runMatchmakingTick();
    const status = await service.getStatus(enqueueResult.ticketId);
    expect(status.ticketId).toBe(enqueueResult.ticketId);
    expect(status.status).toBe('assigned');
    expect(status.assignment).toBeDefined();
  });
});
