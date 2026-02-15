import { QueuedTicket } from '../storage/match-queue.port';
import { QueueConfig } from './queue-config';

/** A group of tickets that can be matched together. */
export interface MatchableGroup {
  tickets: QueuedTicket[];
  totalSize: number;
}

/** Port for match strategy (decides which queued tickets are ready to match). */
export interface MatchStrategyPort {
  /**
   * Returns tickets that are ready to be matched (e.g., have waited long enough).
   * Called by the periodic matchmaking loop.
   */
  findMatchableTickets(
    queuedTickets: QueuedTicket[],
    minWaitMs: number,
  ): QueuedTicket[];

  /**
   * Returns groups of tickets that can form a match (sum of groupSize within min～max).
   * FIFO order; respects minWaitMs and relaxAfterMs.
   */
  findMatchableGroups(
    queuedTickets: QueuedTicket[],
    config: QueueConfig,
  ): MatchableGroup[];
}
