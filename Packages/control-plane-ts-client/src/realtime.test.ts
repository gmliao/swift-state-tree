import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ControlPlaneClient } from './client.js';
import { RealtimeSocket } from './realtime.js';

/** Fake WebSocket: stores onmessage and exposes simulateMessage + close for tests. */
class FakeWebSocket {
  onmessage: ((event: MessageEvent) => void) | null = null;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  close = vi.fn();
  send = vi.fn();
  readonly url: string;

  constructor(url: string) {
    this.url = url;
  }

  simulateOpen(): void {
    if (this.onopen) this.onopen();
  }

  simulateMessage(data: string | object): void {
    const payload = typeof data === 'string' ? data : JSON.stringify(data);
    if (this.onmessage) this.onmessage(new MessageEvent('message', { data: payload }));
  }

  simulateError(): void {
    if (this.onerror) this.onerror();
  }
}

const BASE_URL = 'http://localhost:3000';

describe('RealtimeSocket', () => {
  let fakeWs: FakeWebSocket;

  beforeEach(() => {
    fakeWs = new FakeWebSocket('ws://localhost:3000/realtime');
  });

  describe('on message', () => {
    it('invokes match.assigned callback with data.assignment when type is match.assigned', () => {
      const assignment = {
        assignmentId: 'a1',
        matchToken: 'tok',
        connectUrl: 'ws://x',
        landId: 'l1',
        serverId: 's1',
        expiresAt: '2025-01-01',
      };
      const socket = new RealtimeSocket(fakeWs as unknown as WebSocket);
      const cb = vi.fn();
      socket.on('match.assigned', cb);

      fakeWs.simulateMessage({
        type: 'match.assigned',
        v: 1,
        data: { ticketId: 't1', assignment },
      });

      expect(cb).toHaveBeenCalledTimes(1);
      expect(cb).toHaveBeenCalledWith(assignment);
    });

    it('invokes enqueued callback with ticketId and status when type is enqueued', () => {
      const socket = new RealtimeSocket(fakeWs as unknown as WebSocket);
      const cb = vi.fn();
      socket.on('enqueued', cb);

      fakeWs.simulateMessage({
        type: 'enqueued',
        v: 1,
        data: { ticketId: 't1', status: 'queued' },
      });

      expect(cb).toHaveBeenCalledTimes(1);
      expect(cb).toHaveBeenCalledWith({ ticketId: 't1', status: 'queued' });
    });

    it('invokes error callback when type is error', () => {
      const socket = new RealtimeSocket(fakeWs as unknown as WebSocket);
      const cb = vi.fn();
      socket.on('error', cb);

      fakeWs.simulateMessage({ type: 'error', message: 'Something went wrong' });

      expect(cb).toHaveBeenCalledTimes(1);
      expect(cb).toHaveBeenCalledWith(expect.any(Error));
      expect((cb.mock.calls[0][0] as Error).message).toBe('Something went wrong');
    });
  });

  describe('sendEnqueue', () => {
    it('sends JSON with action enqueue and params', () => {
      const socket = new RealtimeSocket(fakeWs as unknown as WebSocket);
      socket.sendEnqueue({
        queueKey: 'q1',
        members: ['p1', 'p2'],
        groupSize: 2,
        groupId: 'g1',
        region: 'asia',
      });

      expect(fakeWs.send).toHaveBeenCalledTimes(1);
      const sent = JSON.parse(fakeWs.send.mock.calls[0][0]);
      expect(sent).toMatchObject({
        action: 'enqueue',
        queueKey: 'q1',
        members: ['p1', 'p2'],
        groupSize: 2,
        groupId: 'g1',
        region: 'asia',
      });
    });
  });

  describe('close', () => {
    it('closes the underlying WebSocket', () => {
      const socket = new RealtimeSocket(fakeWs as unknown as WebSocket);
      socket.close();
      expect(fakeWs.close).toHaveBeenCalledTimes(1);
    });
  });
});

describe('ControlPlaneClient.openRealtimeSocket', () => {
  let OriginalWebSocket: typeof WebSocket;
  /** Same instances the client receives, so we can simulateOpen/simulateMessage on them. */
  let wsInstances: Array<FakeWebSocket & { simulateOpen(): void; simulateMessage(data: string | object): void; simulateError(): void }>;

  beforeEach(() => {
    wsInstances = [];
    OriginalWebSocket = globalThis.WebSocket;
    (globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = class MockWs extends FakeWebSocket {
      constructor(url: string) {
        super(url);
        wsInstances.push(this);
      }
    } as unknown as typeof WebSocket;
  });

  afterEach(() => {
    (globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = OriginalWebSocket;
    vi.unstubAllGlobals();
  });

  it('resolves with RealtimeSocket when WebSocket opens', async () => {
    const client = new ControlPlaneClient(BASE_URL);
    const p = client.openRealtimeSocket();
    expect(wsInstances.length).toBe(1);
    expect(wsInstances[0].url).toBe('ws://localhost:3000/realtime');
    wsInstances[0].simulateOpen();
    const socket = await p;
    expect(socket).toBeInstanceOf(RealtimeSocket);
  });

  it('appends ticketId as query param when provided', async () => {
    const client = new ControlPlaneClient(BASE_URL);
    client.openRealtimeSocket('ticket-123');
    expect(wsInstances.length).toBe(1);
    expect(wsInstances[0].url).toContain('ticketId=');
    expect(wsInstances[0].url).toContain('ticket-123');
    wsInstances[0].simulateOpen();
  });

  it('rejects when WebSocket errors before open', async () => {
    const client = new ControlPlaneClient(BASE_URL);
    const p = client.openRealtimeSocket();
    wsInstances[0].simulateError();
    await expect(p).rejects.toThrow('WebSocket connection failed');
  });

  it('builds wss URL when baseUrl is https', async () => {
    const client = new ControlPlaneClient('https://api.example.com');
    client.openRealtimeSocket();
    expect(wsInstances[0].url).toBe('wss://api.example.com/realtime');
    wsInstances[0].simulateOpen();
  });
});
