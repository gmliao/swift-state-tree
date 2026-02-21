import { Inject, Injectable } from '@nestjs/common';
import { MatchmakingStore } from '../matchmaking/matchmaking-store';

export interface QueueSummaryDto {
  queueKeys: string[];
  byQueueKey: Record<string, { queuedCount: number }>;
}

/**
 * Aggregates queue state for admin dashboard.
 */
@Injectable()
export class AdminQueueService {
  constructor(
    @Inject('MatchmakingStore') private readonly store: MatchmakingStore,
  ) {}

  async getQueueSummary(): Promise<QueueSummaryDto> {
    const tickets = await this.store.listAllQueuedTickets();
    const byQueueKey: Record<string, { queuedCount: number }> = {};
    for (const t of tickets) {
      const k = t.queueKey;
      if (!byQueueKey[k]) byQueueKey[k] = { queuedCount: 0 };
      byQueueKey[k].queuedCount++;
    }
    return { queueKeys: Object.keys(byQueueKey), byQueueKey };
  }
}
