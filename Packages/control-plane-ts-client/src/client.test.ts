import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ControlPlaneClient } from './client.js';

const BASE_URL = 'http://localhost:3000';

describe('ControlPlaneClient', () => {
  let mockFetch: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockFetch = vi.fn();
    vi.stubGlobal('fetch', mockFetch);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  describe('enqueue', () => {
    it('POSTs to /v1/matchmaking/enqueue with body (queueKey, members, groupSize) and returns EnqueueResponse', async () => {
      const response = { ticketId: 't1', status: 'queued' as const };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL);
      const request = {
        queueKey: 'standard:asia',
        members: ['p1', 'p2'],
        groupSize: 2,
      };
      const result = await client.enqueue(request);

      expect(result).toEqual(response);
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(String(url)).toContain('/v1/matchmaking/enqueue');
      expect(init?.method).toBe('POST');
      const headers = init?.headers as Headers;
      expect(headers.get('Content-Type')).toBe('application/json');
      const body = JSON.parse(init?.body as string);
      expect(body).toMatchObject({
        queueKey: request.queueKey,
        members: request.members,
        groupSize: request.groupSize,
      });
    });
  });

  describe('cancel', () => {
    it('POSTs to /v1/matchmaking/cancel with body (ticketId) and returns CancelResponse', async () => {
      const response = { cancelled: true };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL);
      const result = await client.cancel('t1');

      expect(result).toEqual(response);
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(String(url)).toContain('/v1/matchmaking/cancel');
      expect(init?.method).toBe('POST');
      const headers = init?.headers as Headers;
      expect(headers.get('Content-Type')).toBe('application/json');
      const body = JSON.parse(init?.body as string);
      expect(body).toEqual({ ticketId: 't1' });
    });
  });

  describe('getStatus', () => {
    it('GETs /v1/matchmaking/status/{ticketId} and returns StatusResponse', async () => {
      const response = { ticketId: 't1', status: 'queued' as const };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL);
      const result = await client.getStatus('t1');

      expect(result).toEqual(response);
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(String(url)).toContain('/v1/matchmaking/status/t1');
      expect(init?.method).toBe('GET');
    });
  });

  describe('getServers', () => {
    it('GETs /v1/admin/servers and returns ServerListResponse', async () => {
      const response = {
        servers: [
          {
            serverId: 's1',
            host: 'h',
            port: 8080,
            landType: 'hero-defense',
            registeredAt: '2026-01-01T00:00:00.000Z',
            lastSeenAt: '2026-01-01T00:01:00.000Z',
            isStale: false,
          },
        ],
      };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL);
      const result = await client.getServers();

      expect(result).toEqual(response);
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(String(url)).toContain('/v1/admin/servers');
      expect(init?.method).toBe('GET');
    });
  });

  describe('getQueueSummary', () => {
    it('GETs /v1/admin/queue/summary and returns QueueSummaryResponse', async () => {
      const response = {
        queueKeys: ['q1'],
        byQueueKey: { q1: { queuedCount: 2 } },
      };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL);
      const result = await client.getQueueSummary();

      expect(result).toEqual(response);
      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [url, init] = mockFetch.mock.calls[0];
      expect(String(url)).toContain('/v1/admin/queue/summary');
      expect(init?.method).toBe('GET');
    });
  });

  describe('admin API auth', () => {
    it('sends Authorization: Bearer when adminApiKey is set and path is /v1/admin/*', async () => {
      const response = { servers: [] };
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => response,
      });

      const client = new ControlPlaneClient(BASE_URL, { adminApiKey: 'my-admin-key' });
      await client.getServers();

      expect(mockFetch).toHaveBeenCalledTimes(1);
      const [, init] = mockFetch.mock.calls[0];
      const headers = init?.headers as Headers;
      expect(headers.get('Authorization')).toBe('Bearer my-admin-key');
    });
  });
});
