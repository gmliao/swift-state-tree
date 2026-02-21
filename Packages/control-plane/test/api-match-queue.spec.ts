import { getQueueToken } from '@nestjs/bullmq';
import { Test, TestingModule } from '@nestjs/testing';
import { ApiMatchQueue, CANCEL_JOB } from '../src/modules/matchmaking/storage/api-match-queue';
import { QueuedTicket } from '../src/modules/matchmaking/match-queue';
import { MatchmakingStore } from '../src/modules/matchmaking/matchmaking-store';

const mockStore: MatchmakingStore = {
  getGroupTicket: jest.fn(),
  setGroupTicket: jest.fn().mockResolvedValue(undefined),
  removeGroupTicket: jest.fn().mockResolvedValue(undefined),
  getAssignedTicket: jest.fn().mockResolvedValue(null),
  setAssignedTicket: jest.fn().mockResolvedValue(undefined),
  getQueuedTicket: jest.fn(),
  setQueuedTicket: jest.fn().mockResolvedValue(undefined),
  removeQueuedTicket: jest.fn().mockResolvedValue(undefined),
  listAllQueuedTickets: jest.fn().mockResolvedValue([]),
};

const mockQueue = {
  add: jest.fn().mockResolvedValue({}),
};

describe('ApiMatchQueue', () => {
  let queue: ApiMatchQueue;

  beforeEach(async () => {
    jest.clearAllMocks();
    (mockStore.getGroupTicket as jest.Mock).mockResolvedValue(null);
    (mockStore.getAssignedTicket as jest.Mock).mockResolvedValue(null);
    (mockStore.getQueuedTicket as jest.Mock).mockResolvedValue(null);

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ApiMatchQueue,
        { provide: 'MatchmakingStore', useValue: mockStore },
        { provide: getQueueToken('enqueueTicket'), useValue: mockQueue },
      ],
    }).compile();

    queue = module.get(ApiMatchQueue);
  });

  describe('cancel', () => {
    it('updates store immediately before adding cancel job', async () => {
      const ticket: QueuedTicket = {
        ticketId: 'ticket-abc123',
        groupId: 'solo-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
        status: 'queued',
        createdAt: new Date(),
      };
      (mockStore.getQueuedTicket as jest.Mock).mockResolvedValue(ticket);
      (mockStore.getAssignedTicket as jest.Mock).mockResolvedValue(null);

      const result = await queue.cancel('ticket-abc123');

      expect(result).toBe(true);
      expect(mockStore.removeQueuedTicket).toHaveBeenCalledWith('ticket-abc123');
      expect(mockStore.removeGroupTicket).toHaveBeenCalledWith('solo-p1');
      expect(mockQueue.add).toHaveBeenCalledWith(CANCEL_JOB, { ticketId: 'ticket-abc123' });
    });

    it('getStatus returns null after cancel (store updated immediately)', async () => {
      const ticket: QueuedTicket = {
        ticketId: 'ticket-xyz',
        groupId: 'g1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
        status: 'queued',
        createdAt: new Date(),
      };
      (mockStore.getQueuedTicket as jest.Mock)
        .mockResolvedValueOnce(ticket)
        .mockResolvedValueOnce(null);
      (mockStore.getAssignedTicket as jest.Mock).mockResolvedValue(null);

      await queue.cancel('ticket-xyz');

      const status = await queue.getStatus('ticket-xyz');
      expect(status).toBeNull();
    });

    it('returns false when ticket not found', async () => {
      (mockStore.getQueuedTicket as jest.Mock).mockResolvedValue(null);
      (mockStore.getAssignedTicket as jest.Mock).mockResolvedValue(null);

      const result = await queue.cancel('unknown-ticket');

      expect(result).toBe(false);
      expect(mockStore.removeQueuedTicket).not.toHaveBeenCalled();
      expect(mockStore.removeGroupTicket).not.toHaveBeenCalled();
      expect(mockQueue.add).not.toHaveBeenCalled();
    });

    it('returns false when ticket already assigned', async () => {
      const assigned: QueuedTicket = {
        ticketId: 'ticket-assigned',
        groupId: 'g1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
        status: 'assigned',
        createdAt: new Date(),
        assignment: {
          assignmentId: 'a1',
          matchToken: 't',
          connectUrl: 'ws://test',
          landId: 'l1',
          serverId: 's1',
          expiresAt: new Date().toISOString(),
        },
      };
      (mockStore.getAssignedTicket as jest.Mock).mockResolvedValue(assigned);

      const result = await queue.cancel('ticket-assigned');

      expect(result).toBe(false);
      expect(mockStore.removeQueuedTicket).not.toHaveBeenCalled();
      expect(mockQueue.add).not.toHaveBeenCalled();
    });
  });
});
