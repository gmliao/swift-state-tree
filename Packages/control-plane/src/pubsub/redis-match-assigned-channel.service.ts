import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { CHANNEL_NAMES } from './channels';
import { getMatchmakingRole, isApiEnabled } from '../matchmaking/matchmaking-role';
import type { MatchAssignedChannel, MatchAssignedPayload } from './match-assigned-channel.interface';

@Injectable()
export class RedisMatchAssignedChannelService implements MatchAssignedChannel, OnModuleDestroy {
  private pubClient: Redis | null = null;
  private subClient: Redis | null = null;

  private getRedisConfig(): { host: string; port: number } {
    const host = process.env.REDIS_HOST ?? 'localhost';
    const port = parseInt(process.env.REDIS_PORT ?? '6379', 10);
    return { host, port };
  }

  private ensurePubClient(): Redis {
    if (!this.pubClient) {
      const { host, port } = this.getRedisConfig();
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
    const { host, port } = this.getRedisConfig();
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
