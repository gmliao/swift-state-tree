import { QueuedTicket } from '../storage/match-storage.port';

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
}
