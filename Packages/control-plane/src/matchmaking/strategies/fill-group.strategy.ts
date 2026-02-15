import { QueuedTicket } from '../../storage/match-queue.port';
import {
  MatchStrategyPort,
  MatchableGroup,
} from '../match-strategy.port';
import { QueueConfig } from '../queue-config';

/**
 * Fill-group strategy: forms groups where sum of ticket groupSizes
 * is within [minGroupSize, maxGroupSize]. FIFO; respects minWaitMs and relaxAfterMs.
 */
export class FillGroupStrategy implements MatchStrategyPort {
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
    const now = Date.now();
    const groups: MatchableGroup[] = [];
    const used = new Set<string>();

    for (const t of queuedTickets) {
      if (used.has(t.ticketId)) continue;
      const waited = now - t.createdAt.getTime();
      const canRelax = waited >= config.relaxAfterMs;
      const minSize = canRelax ? 1 : config.minGroupSize;
      const maxSize = config.maxGroupSize;

      if (waited < config.minWaitMs && !canRelax) continue;

      const group: QueuedTicket[] = [t];
      let total = t.groupSize;
      used.add(t.ticketId);

      if (total >= minSize && total <= maxSize) {
        groups.push({ tickets: [...group], totalSize: total });
        continue;
      }

      for (const next of queuedTickets) {
        if (used.has(next.ticketId)) continue;
        const nextWaited = now - next.createdAt.getTime();
        if (nextWaited < config.minWaitMs && !canRelax) continue;
        const newTotal = total + next.groupSize;
        if (newTotal > maxSize) continue;
        group.push(next);
        total = newTotal;
        used.add(next.ticketId);
        if (total >= minSize) {
          groups.push({ tickets: [...group], totalSize: total });
          break;
        }
      }
    }
    return groups;
  }
}
