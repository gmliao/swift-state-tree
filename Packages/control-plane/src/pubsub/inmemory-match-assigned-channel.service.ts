import { Injectable } from '@nestjs/common';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

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
