import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Assignment } from './types.js';
import type { ControlPlaneClient } from './client.js';
import type { RealtimeSocket } from './realtime.js';
import { findMatch, FindMatchTimeoutError } from './findMatch.js';

const stubAssignment: Assignment = {
  assignmentId: 'a1',
  matchToken: 'token1',
  connectUrl: 'http://localhost:8080',
  landId: 'land1',
  serverId: 's1',
  expiresAt: '2025-12-31T00:00:00Z',
};

function createMockSocket(): RealtimeSocket & {
  emitMatchAssigned: (a: Assignment) => void;
  emitError: (err: Error | string) => void;
} {
  const assignedCbs: ((a: Assignment) => void)[] = [];
  const errorCbs: ((err: Error | string) => void)[] = [];
  return {
    on(event: string, cb: (a: Assignment) => void | ((err: Error | string) => void)) {
      if (event === 'match.assigned') assignedCbs.push(cb as (a: Assignment) => void);
      if (event === 'error') errorCbs.push(cb as (err: Error | string) => void);
    },
    close: vi.fn(),
    sendEnqueue: vi.fn(),
    emitMatchAssigned(assignment: Assignment) {
      for (const cb of assignedCbs) cb(assignment);
    },
    emitError(err: Error | string) {
      for (const cb of errorCbs) cb(err);
    },
  };
}

function createMockClient(socket: RealtimeSocket): ControlPlaneClient {
  return {
    enqueue: vi.fn().mockResolvedValue({ ticketId: 't1', status: 'queued' as const }),
    openRealtimeSocket: vi.fn().mockResolvedValue(socket),
  } as unknown as ControlPlaneClient;
}

describe('findMatch', () => {
  it('resolves with assignment when match.assigned is emitted', async () => {
    const mockSocket = createMockSocket();
    const client = createMockClient(mockSocket);

    const resultP = findMatch(client, {
      queueKey: 'q',
      members: ['p1'],
      groupSize: 1,
    });
    // Allow enqueue and openRealtimeSocket to resolve and executor to register listener
    await Promise.resolve();
    await Promise.resolve();
    mockSocket.emitMatchAssigned(stubAssignment);

    const result = await resultP;
    expect(result).toEqual(stubAssignment);
    expect(client.enqueue).toHaveBeenCalledWith(
      expect.objectContaining({ queueKey: 'q', members: ['p1'], groupSize: 1 }),
    );
    expect(client.openRealtimeSocket).toHaveBeenCalledWith('t1');
    expect(mockSocket.close).toHaveBeenCalled();
  });

  it('rejects with FindMatchTimeoutError when timeout is reached', async () => {
    vi.useFakeTimers();
    const mockSocket = createMockSocket();
    const client = createMockClient(mockSocket);

    const resultP = findMatch(client, {
      queueKey: 'q',
      members: ['p1'],
      groupSize: 1,
      timeoutMs: 50,
    });
    const expectP = expect(resultP).rejects.toThrow(FindMatchTimeoutError);
    const expectMessageP = expect(resultP).rejects.toMatchObject({ message: /timed out/i });
    await vi.advanceTimersByTimeAsync(50);
    await expectP;
    await expectMessageP;
    expect(mockSocket.close).toHaveBeenCalled();
    vi.useRealTimers();
  });

  it('rejects with AbortError when signal is aborted', async () => {
    const mockSocket = createMockSocket();
    const client = createMockClient(mockSocket);
    const controller = new AbortController();

    const resultP = findMatch(client, {
      queueKey: 'q',
      members: ['p1'],
      groupSize: 1,
      signal: controller.signal,
    });
    controller.abort();

    await expect(resultP).rejects.toMatchObject({
      name: 'AbortError',
      message: expect.stringMatching(/abort/i),
    });
    expect(mockSocket.close).toHaveBeenCalled();
  });

  it('rejects when socket emits error', async () => {
    const mockSocket = createMockSocket();
    const client = createMockClient(mockSocket);

    const resultP = findMatch(client, {
      queueKey: 'q',
      members: ['p1'],
      groupSize: 1,
      timeoutMs: 60_000,
    });
    await Promise.resolve();
    await Promise.resolve();
    const err = new Error('Server rejected ticket');
    mockSocket.emitError(err);

    await expect(resultP).rejects.toThrow('Server rejected ticket');
    expect(mockSocket.close).toHaveBeenCalled();
  });
});
