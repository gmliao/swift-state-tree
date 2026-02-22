import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { getClusterDirectoryTtlSeconds, getRedisConfig } from '../config/env.config';
import type { UserIdDirectory } from './user-id-directory.interface';

const KEY_PREFIX = 'cd:user:';

/**
 * Redis-backed UserIdDirectory implementation.
 * Stores userId -> nodeId with TTL. Key: cd:user:{userId}.
 */
@Injectable()
export class RedisUserIdDirectoryService implements UserIdDirectory, OnModuleDestroy {
  private client: Redis | null = null;

  private ensureClient(): Redis {
    if (!this.client) {
      this.client = new Redis(getRedisConfig());
    }
    return this.client;
  }

  private key(userId: string): string {
    return `${KEY_PREFIX}${userId}`;
  }

  async registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void> {
    const client = this.ensureClient();
    const ttl = ttlSeconds ?? getClusterDirectoryTtlSeconds();
    await client.set(this.key(userId), nodeId, 'EX', ttl);
  }

  async refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void> {
    const client = this.ensureClient();
    const current = await client.get(this.key(userId));
    if (current === nodeId) {
      const ttl = ttlSeconds ?? getClusterDirectoryTtlSeconds();
      await client.expire(this.key(userId), ttl);
    }
  }

  async getNodeId(userId: string): Promise<string | null> {
    const client = this.ensureClient();
    return client.get(this.key(userId));
  }

  async unregisterSession(userId: string, nodeId: string): Promise<void> {
    const client = this.ensureClient();
    const current = await client.get(this.key(userId));
    if (current === nodeId) {
      await client.del(this.key(userId));
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.client?.quit();
    this.client = null;
  }
}
