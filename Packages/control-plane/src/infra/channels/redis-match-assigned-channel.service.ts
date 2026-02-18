import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { getRedisConfig } from '../config/env.config';
import { getMatchmakingRole, isApiEnabled } from '../../modules/matchmaking/matchmaking-role';
import { CHANNEL_NAMES } from './channels';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

/**
 * Redis-backed MatchAssignedChannel implementation.
 * Broadcasts match.assigned to all API instances. Only API instances subscribe.
 */
@Injectable()
export class RedisMatchAssignedChannelService implements MatchAssignedChannel, OnModuleDestroy {
  private pubClient: Redis | null = null;
  private subClient: Redis | null = null;

  private ensurePubClient(): Redis {
    if (!this.pubClient) {
      const { host, port } = getRedisConfig();
      this.pubClient = new Redis({ host, port });
    }
    return this.pubClient;
  }

  async publish(payload: MatchAssignedPayload): Promise<void> {
    const client = this.ensurePubClient();
    await client.publish(CHANNEL_NAMES.matchAssigned, JSON.stringify(payload));
  }

  subscribe(handler: (payload: MatchAssignedPayload) => void): void {
    if (!isApiEnabled(getMatchmakingRole())) return;
    const { host, port } = getRedisConfig();
    this.subClient = new Redis({ host, port });
    this.subClient.subscribe(CHANNEL_NAMES.matchAssigned);
    this.subClient.on('message', (_ch, msg) => {
      try {
        handler(JSON.parse(msg) as MatchAssignedPayload);
      } catch (e) {
        console.error('[MatchAssignedChannel] parse error:', e);
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
