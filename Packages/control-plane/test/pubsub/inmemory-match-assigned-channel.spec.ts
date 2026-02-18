import { Test, TestingModule } from '@nestjs/testing';
import { InMemoryMatchAssignedChannelService } from '../../src/pubsub/inmemory-match-assigned-channel.service';
import type { MatchAssignedPayload } from '../../src/pubsub/match-assigned-channel.interface';

describe('InMemoryMatchAssignedChannelService', () => {
  let service: InMemoryMatchAssignedChannelService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [InMemoryMatchAssignedChannelService],
    }).compile();
    service = module.get(InMemoryMatchAssignedChannelService);
  });

  it('delivers payload to subscriber when publish is called', async () => {
    const received: unknown[] = [];
    service.subscribe((p: MatchAssignedPayload) => received.push(p));
    await service.publish({
      ticketId: 't1',
      envelope: {
        type: 'match.assigned',
        v: 1,
        data: {
          ticketId: 't1',
          assignment: {
            assignmentId: 'a1',
            matchToken: 'tok',
            connectUrl: 'ws://localhost/game',
            landId: 'land-1',
            serverId: 's1',
            expiresAt: new Date().toISOString(),
          },
        },
      },
    });
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ ticketId: 't1' });
  });

  it('does nothing when no subscriber', async () => {
    const payload: MatchAssignedPayload = {
      ticketId: 't1',
      envelope: {
        type: 'match.assigned',
        v: 1,
        data: {
          ticketId: 't1',
          assignment: {
            assignmentId: 'a1',
            matchToken: 'tok',
            connectUrl: 'ws://localhost/game',
            landId: 'land-1',
            serverId: 's1',
            expiresAt: new Date().toISOString(),
          },
        },
      },
    };
    await expect(service.publish(payload)).resolves.not.toThrow();
  });
});
