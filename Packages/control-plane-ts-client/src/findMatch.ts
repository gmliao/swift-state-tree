import type { ControlPlaneClient } from './client.js';
import type { Assignment, EnqueueRequest } from './types.js';

export interface FindMatchOptions extends EnqueueRequest {
  /** Timeout in milliseconds; default 60_000. */
  timeoutMs?: number;
  /** Optional AbortSignal to cancel the operation. */
  signal?: AbortSignal;
}

const DEFAULT_TIMEOUT_MS = 60_000;

/** Thrown when findMatch does not receive a match within the configured timeout. */
export class FindMatchTimeoutError extends Error {
  constructor(message = 'Matchmaking timed out') {
    super(message);
    this.name = 'FindMatchTimeoutError';
    Object.setPrototypeOf(this, FindMatchTimeoutError.prototype);
  }
}

/**
 * Enqueues for matchmaking and waits for an assignment via the realtime WebSocket.
 * Resolves with the assignment on 'match.assigned'; rejects on timeout, abort, or error.
 */
export async function findMatch(
  client: ControlPlaneClient,
  options: FindMatchOptions,
): Promise<Assignment> {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const { signal } = options;

  const enqueuePayload: EnqueueRequest = {
    queueKey: options.queueKey,
    members: options.members,
    groupSize: options.groupSize,
    ...(options.groupId != null && { groupId: options.groupId }),
    ...(options.region != null && { region: options.region }),
    ...(options.constraints != null && { constraints: options.constraints }),
  };

  const { ticketId } = await client.enqueue(enqueuePayload);
  const socket = await client.openRealtimeSocket(ticketId);

  return new Promise<Assignment>((resolve, reject) => {
    let timeoutId: ReturnType<typeof setTimeout> | null = null;
    let settled = false;

    function finish(): void {
      if (settled) return;
      settled = true;
      if (timeoutId != null) {
        clearTimeout(timeoutId);
        timeoutId = null;
      }
      if (signal != null) {
        signal.removeEventListener('abort', onAbort);
      }
      socket.close();
    }

    function onAbort(): void {
      finish();
      const err =
        signal?.reason !== undefined
          ? signal.reason instanceof Error
            ? signal.reason
            : new Error(String(signal.reason))
          : new DOMException('Aborted', 'AbortError');
      reject(err);
    }

    function onAssigned(assignment: Assignment): void {
      finish();
      resolve(assignment);
    }

    socket.on('match.assigned', onAssigned);

    if (signal?.aborted) {
      onAbort();
      return;
    }

    if (signal != null) {
      signal.addEventListener('abort', onAbort);
    }

    timeoutId = setTimeout(() => {
      finish();
      reject(new FindMatchTimeoutError());
    }, timeoutMs);
  });
}
