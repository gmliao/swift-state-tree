import { RealtimeSocket } from './realtime.js';
import type {
  CancelResponse,
  EnqueueRequest,
  EnqueueResponse,
  QueueSummaryResponse,
  ServerListResponse,
  StatusResponse,
} from './types.js';

export interface ControlPlaneClientOptions {
  fetch?: typeof globalThis.fetch;
  adminApiKey?: string;
}

export class ControlPlaneClient {
  private readonly baseUrl: string;
  private readonly fetch: typeof globalThis.fetch;
  private readonly adminApiKey?: string;

  constructor(
    baseUrl: string,
    options?: ControlPlaneClientOptions,
  ) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.fetch = options?.fetch ?? globalThis.fetch;
    this.adminApiKey = options?.adminApiKey;
  }

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const url = this.baseUrl + path;
    const headers = new Headers(init?.headers);
    if (this.adminApiKey != null && path.startsWith('/v1/admin/')) {
      headers.set('Authorization', `Bearer ${this.adminApiKey}`);
    }
    const response = await this.fetch(url, { ...init, headers });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(`Control plane request failed: ${response.status} ${text}`);
    }
    return response.json() as Promise<T>;
  }

  enqueue(request: EnqueueRequest): Promise<EnqueueResponse> {
    return this.request<EnqueueResponse>('/v1/matchmaking/enqueue', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
    });
  }

  cancel(ticketId: string): Promise<CancelResponse> {
    return this.request<CancelResponse>('/v1/matchmaking/cancel', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticketId }),
    });
  }

  getStatus(ticketId: string): Promise<StatusResponse> {
    return this.request<StatusResponse>(
      '/v1/matchmaking/status/' + encodeURIComponent(ticketId),
      { method: 'GET' },
    );
  }

  getServers(): Promise<ServerListResponse> {
    return this.request<ServerListResponse>('/v1/admin/servers', {
      method: 'GET',
    });
  }

  getQueueSummary(): Promise<QueueSummaryResponse> {
    return this.request<QueueSummaryResponse>('/v1/admin/queue/summary', {
      method: 'GET',
    });
  }

  /**
   * Opens a WebSocket to the control-plane realtime channel.
   * Resolves when the socket is open; rejects on connection error.
   * @param ticketId - Optional ticket ID to subscribe to (appended as query param).
   */
  openRealtimeSocket(ticketId?: string): Promise<RealtimeSocket> {
    const base = this.baseUrl.replace(/^http:\/\//i, 'ws://').replace(/^https:\/\//i, 'wss://');
    const path = '/realtime' + (ticketId != null && ticketId !== '' ? `?ticketId=${encodeURIComponent(ticketId)}` : '');
    const wsUrl = base + path;
    const ws = new WebSocket(wsUrl);
    const socket = new RealtimeSocket(ws);
    return new Promise((resolve, reject) => {
      ws.onopen = () => resolve(socket);
      ws.onerror = () => reject(new Error('WebSocket connection failed'));
    });
  }
}
