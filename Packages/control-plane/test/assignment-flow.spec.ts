import { getQueueToken } from '@nestjs/bullmq';
import { Test, TestingModule } from '@nestjs/testing';
import { MatchmakingService } from '../src/modules/matchmaking/matchmaking.service';
import { InMemoryMatchQueue } from '../src/modules/matchmaking/storage/inmemory-match-queue';
import { DefaultMatchStrategy } from '../src/modules/matchmaking/strategies/default.strategy';
import { JwtIssuerService } from '../src/infra/security/jwt-issuer.service';
import { MATCH_ASSIGNED_CHANNEL } from '../src/infra/channels/match-assigned-channel.interface';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';
import { USER_ID_DIRECTORY } from '../src/infra/cluster-directory/user-id-directory.interface';

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
    expiresAt: new Date(Date.now() + 3600 * 1000).toISOString(),
  }),
};

const testConfig = { minWaitMs: 0 };

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
        { provide: 'MatchQueue', useClass: InMemoryMatchQueue },
        { provide: 'MatchStrategy', useClass: DefaultMatchStrategy },
        { provide: 'ProvisioningClientPort', useValue: mockProvisioning },
        { provide: 'MatchmakingConfig', useValue: testConfig },
        { provide: getQueueToken('enqueueTicket'), useValue: mockEnqueueTicketQueue },
        { provide: MATCH_ASSIGNED_CHANNEL, useValue: mockMatchAssignedChannel },
        { provide: NODE_INBOX_CHANNEL, useValue: mockNodeInboxChannel },
        { provide: USER_ID_DIRECTORY, useValue: mockClusterDirectory },
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
