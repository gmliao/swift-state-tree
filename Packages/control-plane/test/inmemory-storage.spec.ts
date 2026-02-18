import { InMemoryMatchQueue } from '../src/modules/matchmaking/storage/inmemory-match-queue';

describe('InMemoryMatchQueue', () => {
  let queue: InMemoryMatchQueue;
  const group = {
    groupId: 'solo-p1',
    queueKey: 'standard:asia',
    members: ['p1'],
    groupSize: 1,
  };

  beforeEach(() => {
    queue = new InMemoryMatchQueue();
  });

  it('deduplicates active group ticket by groupId', async () => {
    const first = await queue.enqueue(group);
    const second = await queue.enqueue(group);
    expect(second.ticketId).toBe(first.ticketId);
  });

  it('creates new ticket for different groupId', async () => {
    const first = await queue.enqueue(group);
    const second = await queue.enqueue({ ...group, groupId: 'solo-p2' });
    expect(second.ticketId).not.toBe(first.ticketId);
  });

  it('returns ticket status', async () => {
    const ticket = await queue.enqueue(group);
    const status = await queue.getStatus(ticket.ticketId);
    expect(status).not.toBeNull();
    expect(status!.ticketId).toBe(ticket.ticketId);
    expect(status!.status).toBe('queued');
  });

  it('returns null for unknown ticketId', async () => {
    const status = await queue.getStatus('unknown-ticket');
    expect(status).toBeNull();
  });

  it('cancels queued ticket', async () => {
    const ticket = await queue.enqueue(group);
    const ok = await queue.cancel(ticket.ticketId);
    expect(ok).toBe(true);
    const status = await queue.getStatus(ticket.ticketId);
    expect(status!.status).toBe('cancelled');
  });

  it('returns false when cancelling non-existent ticket', async () => {
    const ok = await queue.cancel('unknown-ticket');
    expect(ok).toBe(false);
  });

  it('updates assignment', async () => {
    const ticket = await queue.enqueue(group);
    await queue.updateAssignment(ticket.ticketId, {
      assignmentId: 'a1',
      matchToken: 'token',
      connectUrl: 'ws://test',
      landId: 'land1',
      serverId: 's1',
      expiresAt: new Date().toISOString(),
    });
    const status = await queue.getStatus(ticket.ticketId);
    expect(status!.status).toBe('assigned');
    expect(status!.assignment?.assignmentId).toBe('a1');
  });

  it('lists queued tickets by queueKey', async () => {
    await queue.enqueue(group);
    await queue.enqueue({ ...group, groupId: 'solo-p2' });
    const queued = await queue.listQueuedByQueue('standard:asia');
    expect(queued).toHaveLength(2);
  });

  it('lists queue keys with queued tickets', async () => {
    await queue.enqueue(group);
    await queue.enqueue({ ...group, queueKey: 'other:queue', groupId: 'g2' });
    const keys = await queue.listQueueKeysWithQueued();
    expect(keys).toContain('standard:asia');
    expect(keys).toContain('other:queue');
    expect(keys).toHaveLength(2);
  });
});
