import { QueuedTicket } from '../../storage/match-storage.port';
import { MatchStrategyPort } from '../match-strategy.port';

/**
 * Default match strategy: any ticket with groupSize >= 1 that has waited >= minWaitMs.
 */
export class DefaultMatchStrategy implements MatchStrategyPort {
  findMatchableTickets(
    queuedTickets: QueuedTicket[],
    minWaitMs: number,
  ): QueuedTicket[] {
    const now = Date.now();
    return queuedTickets.filter(
      (t) =>
        t.groupSize >= 1 &&
        now - t.createdAt.getTime() >= minWaitMs,
    );
  }
}
