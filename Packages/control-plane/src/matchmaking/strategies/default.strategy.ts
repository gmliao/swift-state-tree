import { QueuedTicket } from '../../storage/match-queue.port';
import {
  MatchStrategyPort,
  MatchableGroup,
} from '../match-strategy.port';
import { QueueConfig } from '../queue-config';

/**
 * Default match strategy: any ticket with groupSize >= 1 that has waited >= minWaitMs.
 * findMatchableGroups returns each matchable ticket as a single-ticket group.
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

  findMatchableGroups(
    queuedTickets: QueuedTicket[],
    config: QueueConfig,
  ): MatchableGroup[] {
    const matchable = this.findMatchableTickets(
      queuedTickets,
      config.minWaitMs,
    );
    return matchable.map((t) => ({ tickets: [t], totalSize: t.groupSize }));
  }
}
