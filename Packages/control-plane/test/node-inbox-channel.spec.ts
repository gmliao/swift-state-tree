import { Test, TestingModule } from '@nestjs/testing';
import { InMemoryNodeInboxChannelService } from '../src/infra/channels/inmemory-node-inbox-channel.service';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';

describe('InMemoryNodeInboxChannelService', () => {
  let service: InMemoryNodeInboxChannelService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        {
          provide: NODE_INBOX_CHANNEL,
          useClass: InMemoryNodeInboxChannelService,
        },
      ],
    }).compile();
    service = module.get(NODE_INBOX_CHANNEL);
  });

  const stubAssignment = {
    assignmentId: 'a1',
    matchToken: 'tok',
    connectUrl: 'ws://localhost/game',
    landId: 'land-1',
    serverId: 's1',
    expiresAt: new Date().toISOString(),
  };

  it('delivers payload to subscriber when publish is called', async () => {
    const received: unknown[] = [];
    service.subscribe('node-a', (p) => received.push(p));
    await service.publish('node-a', {
      ticketId: 't1',
      envelope: {
        type: 'match.assigned',
        v: 1,
        data: { ticketId: 't1', assignment: stubAssignment },
      },
    });
    expect(received).toHaveLength(1);
    expect(received[0]).toMatchObject({ ticketId: 't1' });
  });

  it('does nothing when no subscriber for nodeId', async () => {
    await expect(
      service.publish('node-unknown', {
        ticketId: 't1',
        envelope: {
          type: 'match.assigned',
          v: 1,
          data: { ticketId: 't1', assignment: stubAssignment },
        },
      }),
    ).resolves.not.toThrow();
  });

  it('delivers only to matching nodeId', async () => {
    const receivedA: unknown[] = [];
    const receivedB: unknown[] = [];
    service.subscribe('node-a', (p) => receivedA.push(p));
    service.subscribe('node-b', (p) => receivedB.push(p));
    await service.publish('node-a', {
      ticketId: 't1',
      envelope: {
        type: 'match.assigned',
        v: 1,
        data: { ticketId: 't1', assignment: stubAssignment },
      },
    });
    expect(receivedA).toHaveLength(1);
    expect(receivedB).toHaveLength(0);
  });
});
