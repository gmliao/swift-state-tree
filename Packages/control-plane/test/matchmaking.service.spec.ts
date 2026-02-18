import { getQueueToken } from '@nestjs/bullmq';
import { Test, TestingModule } from '@nestjs/testing';
import { MatchmakingService } from '../src/modules/matchmaking/matchmaking.service';
import { MATCH_ASSIGNED_CHANNEL } from '../src/infra/channels/match-assigned-channel.interface';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';
import { CLUSTER_DIRECTORY } from '../src/infra/cluster-directory/cluster-directory.interface';
import { InMemoryMatchQueue } from '../src/modules/matchmaking/storage/inmemory-match-queue';
import { FillGroupStrategy } from '../src/modules/matchmaking/strategies/fill-group.strategy';
import { JwtIssuerService } from '../src/infra/security/jwt-issuer.service';

const mockEnqueueTicketQueue = {
  add: jest.fn().mockResolvedValue({}),
};

const mockMatchAssignedChannel = {
  publish: jest.fn().mockResolvedValue(undefined),
  subscribe: jest.fn(),
};
const mockNodeInboxChannel = {
  publish: jest.fn().mockResolvedValue(undefined),
  subscribe: jest.fn(),
};
const mockClusterDirectory = {
  registerSession: jest.fn().mockResolvedValue(undefined),
  refreshLease: jest.fn().mockResolvedValue(undefined),
  getNodeId: jest.fn().mockResolvedValue(null),
  unregisterSession: jest.fn().mockResolvedValue(undefined),
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

const testConfig = { minWaitMs: 0 };

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
        { provide: 'MatchQueue', useClass: InMemoryMatchQueue },
        { provide: 'MatchStrategy', useClass: FillGroupStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        { provide: getQueueToken('enqueueTicket'), useValue: mockEnqueueTicketQueue },
        { provide: MATCH_ASSIGNED_CHANNEL, useValue: mockMatchAssignedChannel },
        { provide: NODE_INBOX_CHANNEL, useValue: mockNodeInboxChannel },
        { provide: CLUSTER_DIRECTORY, useValue: mockClusterDirectory },
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
      findMatchableGroups: jest.fn().mockReturnValue([]),
    };
    const queue = new InMemoryMatchQueue();
    const module = await Test.createTestingModule({
      providers: [
        MatchmakingService,
        { provide: 'MatchQueue', useValue: queue },
        { provide: 'MatchStrategy', useValue: neverMatchStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        { provide: getQueueToken('enqueueTicket'), useValue: mockEnqueueTicketQueue },
        { provide: MATCH_ASSIGNED_CHANNEL, useValue: mockMatchAssignedChannel },
        { provide: NODE_INBOX_CHANNEL, useValue: mockNodeInboxChannel },
        { provide: CLUSTER_DIRECTORY, useValue: mockClusterDirectory },
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

  /** Tests for match.assigned delivery via node inbox (USE_NODE_INBOX_FOR_MATCH_ASSIGNED). */
  describe('match.assigned delivery via node inbox', () => {
    const originalUseNodeInbox = process.env.USE_NODE_INBOX_FOR_MATCH_ASSIGNED;

    afterEach(() => {
      process.env.USE_NODE_INBOX_FOR_MATCH_ASSIGNED = originalUseNodeInbox;
    });

    it('publishes to node inbox when USE_NODE_INBOX_FOR_MATCH_ASSIGNED=true and getNodeId returns nodeId', async () => {
      process.env.USE_NODE_INBOX_FOR_MATCH_ASSIGNED = 'true';
      mockClusterDirectory.getNodeId.mockResolvedValue('node-api-1');

      await service.enqueue(base);
      await service.runMatchmakingTick();

      expect(mockNodeInboxChannel.publish).toHaveBeenCalledWith(
        'node-api-1',
        expect.objectContaining({
          ticketId: expect.any(String),
          envelope: expect.objectContaining({
            type: 'match.assigned',
            v: 1,
            data: expect.objectContaining({
              ticketId: expect.any(String),
              assignment: expect.any(Object),
            }),
          }),
        }),
      );
      expect(mockMatchAssignedChannel.publish).not.toHaveBeenCalled();
    });

    it('falls back to broadcast when USE_NODE_INBOX_FOR_MATCH_ASSIGNED=true but getNodeId returns null', async () => {
      process.env.USE_NODE_INBOX_FOR_MATCH_ASSIGNED = 'true';
      mockClusterDirectory.getNodeId.mockResolvedValue(null);

      await service.enqueue(base);
      await service.runMatchmakingTick();

      expect(mockMatchAssignedChannel.publish).toHaveBeenCalledWith(
        expect.objectContaining({
          ticketId: expect.any(String),
          envelope: expect.objectContaining({
            type: 'match.assigned',
            v: 1,
          }),
        }),
      );
      expect(mockNodeInboxChannel.publish).not.toHaveBeenCalled();
    });

    it('publishes to broadcast when USE_NODE_INBOX_FOR_MATCH_ASSIGNED is not true', async () => {
      process.env.USE_NODE_INBOX_FOR_MATCH_ASSIGNED = 'false';

      await service.enqueue(base);
      await service.runMatchmakingTick();

      expect(mockMatchAssignedChannel.publish).toHaveBeenCalled();
      expect(mockNodeInboxChannel.publish).not.toHaveBeenCalled();
    });
  });
});
