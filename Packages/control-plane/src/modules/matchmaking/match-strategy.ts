import { QueuedTicket } from './match-queue';
import { QueueConfig } from './queue-config';

/** A group of tickets that can be matched together. */
export interface MatchableGroup {
  tickets: QueuedTicket[];
  totalSize: number;
}

/** Match strategy interface (decides which queued tickets are ready to match). */
export interface MatchStrategy {
  /**
   * Returns groups of tickets that can form a match (sum of groupSize within min～max).
   * FIFO order; respects minWaitMs and relaxAfterMs.
   */
  findMatchableGroups(
    queuedTickets: QueuedTicket[],
    config: QueueConfig,
  ): MatchableGroup[];
}
