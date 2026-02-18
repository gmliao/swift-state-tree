import { getMatchmakingRole as getRoleFromConfig, type MatchmakingRole } from '../../infra/config/env.config';

/**
 * Instance role for horizontal scaling.
 * - api: HTTP/WebSocket only, no queue worker (enqueue adds job, getStatus/cancel require Redis-backed queue)
 * - queue-worker: Queue worker only, processes enqueueTicket jobs (has LocalMatchQueue)
 * - all: Both API and queue-worker (default, single-instance behavior)
 */
export type { MatchmakingRole };

export function getMatchmakingRole(): MatchmakingRole {
  return getRoleFromConfig();
}

export function isApiEnabled(role: MatchmakingRole): boolean {
  return role === 'api' || role === 'all';
}

export function isWorkerEnabled(role: MatchmakingRole): boolean {
  return role === 'queue-worker' || role === 'all';
}
