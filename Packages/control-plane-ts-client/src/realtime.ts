import type { Assignment } from './types.js';

/** Payload passed to the 'enqueued' callback. */
export interface EnqueuedData {
  ticketId: string;
  status: 'queued';
}

export type RealtimeEvent = 'match.assigned' | 'enqueued' | 'error';

export type RealtimeEventMap = {
  'match.assigned': (assignment: Assignment) => void;
  enqueued: (data: EnqueuedData) => void;
  error: (err: Error | string) => void;
};

/** Parameters for sendEnqueue (aligned with control-plane WsEnqueueMessage). */
export interface RealtimeEnqueueParams {
  queueKey: string;
  members: string[];
  groupSize: number;
  groupId?: string;
  region?: string;
  constraints?: Record<string, unknown>;
}

/**
 * Wraps a WebSocket for the control-plane realtime channel.
 * Parses JSON messages and dispatches to registered callbacks by message type.
 */
export class RealtimeSocket {
  private readonly ws: WebSocket;
  private readonly listeners: {
    'match.assigned': ((a: Assignment) => void)[];
    enqueued: ((d: EnqueuedData) => void)[];
    error: ((e: Error | string) => void)[];
  } = {
    'match.assigned': [],
    enqueued: [],
    error: [],
  };

  constructor(ws: WebSocket) {
    this.ws = ws;
    this.ws.onmessage = (event: MessageEvent) => {
      try {
        const msg = JSON.parse(event.data as string) as {
          type?: string;
          data?: { assignment?: Assignment; ticketId?: string; status?: 'queued' };
          message?: string;
        };
        if (msg.type === 'match.assigned' && msg.data?.assignment != null) {
          for (const cb of this.listeners['match.assigned']) {
            cb(msg.data.assignment);
          }
        } else if (msg.type === 'enqueued' && msg.data != null) {
          const { ticketId, status } = msg.data;
          if (ticketId != null && status === 'queued') {
            for (const cb of this.listeners.enqueued) {
              cb({ ticketId, status: 'queued' });
            }
          }
        } else if (msg.type === 'error') {
          const err = typeof msg.message === 'string' ? new Error(msg.message) : new Error('Unknown error');
          for (const cb of this.listeners.error) {
            cb(err);
          }
        }
      } catch (e) {
        const err = e instanceof Error ? e : new Error(String(e));
        for (const cb of this.listeners.error) {
          cb(err);
        }
      }
    };
    this.ws.onerror = () => {
      for (const cb of this.listeners.error) {
        cb(new Error('WebSocket error'));
      }
    };
  }

  on<E extends RealtimeEvent>(event: E, callback: RealtimeEventMap[E]): void {
    (this.listeners[event] as RealtimeEventMap[E][]).push(callback);
  }

  sendEnqueue(params: RealtimeEnqueueParams): void {
    this.ws.send(JSON.stringify({ action: 'enqueue', ...params }));
  }

  close(): void {
    this.ws.close();
  }
}
