import { getQueueToken } from '@nestjs/bullmq';
import { Test, TestingModule } from '@nestjs/testing';
import { MatchmakingService } from '../src/matchmaking/matchmaking.service';
import { RealtimeGateway } from '../src/realtime/realtime.gateway';
import { InMemoryMatchQueue } from '../src/storage/inmemory-match-queue';
import { FillGroupStrategy } from '../src/matchmaking/strategies/fill-group.strategy';
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
        { provide: 'MatchQueuePort', useClass: InMemoryMatchQueue },
        { provide: 'MatchStrategyPort', useClass: FillGroupStrategy },
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

  it('forms one group from 3 solo tickets in hero-defense:3v3', async () => {
    const queueKey = 'hero-defense:3v3';
    const r1 = await service.enqueue({
      groupId: 'solo-p1',
      queueKey,
      members: ['p1'],
      groupSize: 1,
    });
    const r2 = await service.enqueue({
      groupId: 'solo-p2',
      queueKey,
      members: ['p2'],
      groupSize: 1,
    });
    const r3 = await service.enqueue({
      groupId: 'solo-p3',
      queueKey,
      members: ['p3'],
      groupSize: 1,
    });
    await service.runMatchmakingTick();
    const s1 = await service.getStatus(r1.ticketId);
    const s2 = await service.getStatus(r2.ticketId);
    const s3 = await service.getStatus(r3.ticketId);
    expect(s1.status).toBe('assigned');
    expect(s2.status).toBe('assigned');
    expect(s3.status).toBe('assigned');
    expect(s1.assignment!.landId).toBe(s2.assignment!.landId);
    expect(s2.assignment!.landId).toBe(s3.assignment!.landId);
    expect(mockProvisioning.allocate).toHaveBeenCalledTimes(1);
  });

  it('cancels queued ticket', async () => {
    const neverMatchStrategy = {
      findMatchableTickets: jest.fn().mockReturnValue([]),
      findMatchableGroups: jest.fn().mockReturnValue([]),
    };
    const queue = new InMemoryMatchQueue();
    const module = await Test.createTestingModule({
      providers: [
        MatchmakingService,
        { provide: 'MatchQueuePort', useValue: queue },
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
