import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { getRedisConfig } from '../config/env.config';
import { getMatchmakingRole, isApiEnabled } from '../../modules/matchmaking/matchmaking-role';
import { nodeInboxChannel } from './channels';
import type { NodeInboxChannel as NodeInboxChannelInterface, NodeInboxPayload } from './node-inbox-channel.interface';

/**
 * Redis-backed NodeInboxChannel implementation.
 * Uses Redis Pub/Sub with channel cd:inbox:{nodeId}. Only API instances subscribe.
 */
@Injectable()
export class RedisNodeInboxChannelService implements NodeInboxChannelInterface, OnModuleDestroy {
  private pubClient: Redis | null = null;
  private subClient: Redis | null = null;

  private ensurePubClient(): Redis {
    if (!this.pubClient) {
      const { host, port } = getRedisConfig();
      this.pubClient = new Redis({ host, port });
    }
    return this.pubClient;
  }

  async publish(nodeId: string, payload: NodeInboxPayload): Promise<void> {
    const client = this.ensurePubClient();
    await client.publish(nodeInboxChannel(nodeId), JSON.stringify(payload));
  }

  subscribe(nodeId: string, handler: (payload: NodeInboxPayload) => void): void {
    if (!isApiEnabled(getMatchmakingRole())) return;
    const { host, port } = getRedisConfig();
    this.subClient = new Redis({ host, port });
    this.subClient.subscribe(nodeInboxChannel(nodeId));
    this.subClient.on('message', (_ch, msg) => {
      try {
        handler(JSON.parse(msg) as NodeInboxPayload);
      } catch (e) {
        console.error('[NodeInboxChannel] parse error:', e);
      }
    });
  }

  async onModuleDestroy(): Promise<void> {
    await this.pubClient?.quit();
    await this.subClient?.quit();
    this.pubClient = null;
    this.subClient = null;
  }
}
