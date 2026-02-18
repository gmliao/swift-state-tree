import { QueuedTicket } from '../match-queue';
import {
  MatchStrategy,
  MatchableGroup,
} from '../match-strategy';
import { QueueConfig } from '../queue-config';

/**
 * Default match strategy: any ticket with groupSize >= 1 that has waited >= minWaitMs.
 * Returns each matchable ticket as a single-ticket group.
 */
export class DefaultMatchStrategy implements MatchStrategy {
  findMatchableGroups(
    queuedTickets: QueuedTicket[],
    config: QueueConfig,
  ): MatchableGroup[] {
    const now = Date.now();
    return queuedTickets
      .filter(
        (t) =>
          t.groupSize >= 1 &&
          now - t.createdAt.getTime() >= config.minWaitMs,
      )
      .map((t) => ({ tickets: [t], totalSize: t.groupSize }));
  }
}
