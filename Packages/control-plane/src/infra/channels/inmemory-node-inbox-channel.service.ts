import { Injectable } from '@nestjs/common';
import type { NodeInboxChannel, NodeInboxPayload } from './node-inbox-channel.interface';

/**
 * In-memory NodeInboxChannel implementation for tests.
 * Single-process delivery; no Redis required.
 */
@Injectable()
export class InMemoryNodeInboxChannelService implements NodeInboxChannel {
  private readonly handlers = new Map<string, (payload: NodeInboxPayload) => void>();

  async publish(nodeId: string, payload: NodeInboxPayload): Promise<void> {
    this.handlers.get(nodeId)?.(payload);
  }

  subscribe(nodeId: string, handler: (payload: NodeInboxPayload) => void): void {
    this.handlers.set(nodeId, handler);
  }
}
