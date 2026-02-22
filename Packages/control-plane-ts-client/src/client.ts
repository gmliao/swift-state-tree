import type {
  CancelResponse,
  EnqueueRequest,
  EnqueueResponse,
  StatusResponse,
} from './types.js';

export interface ControlPlaneClientOptions {
  fetch?: typeof globalThis.fetch;
  adminApiKey?: string;
}

export class ControlPlaneClient {
  private readonly baseUrl: string;
  private readonly fetch: typeof globalThis.fetch;

  constructor(
    baseUrl: string,
    options?: ControlPlaneClientOptions,
  ) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.fetch = options?.fetch ?? globalThis.fetch;
  }

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const url = this.baseUrl + path;
    const response = await this.fetch(url, init);
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
}
