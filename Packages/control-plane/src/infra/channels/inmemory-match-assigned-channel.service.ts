import { Injectable } from '@nestjs/common';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

/**
 * In-memory MatchAssignedChannel implementation for tests.
 * Single-process delivery; no Redis required.
 */
@Injectable()
export class InMemoryMatchAssignedChannelService implements MatchAssignedChannel {
  private handler: ((p: MatchAssignedPayload) => void) | null = null;

  async publish(payload: MatchAssignedPayload): Promise<void> {
    this.handler?.(payload);
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    this.handler = handler;
  }
}
