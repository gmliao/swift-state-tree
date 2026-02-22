import { Injectable, OnModuleDestroy } from '@nestjs/common';
import Redis from 'ioredis';
import { getRedisConfig } from '../config/env.config';
import type { ServerEntry } from '../contracts/server-entry.dto';
import { SERVER_TTL_MS } from '../contracts/server-entry.dto';
import type { ServerIdDirectory } from './server-id-directory.interface';

const KEY_BYID = 'cd:server:byid:';
const KEY_LAND = 'cd:server:';
const KEY_IDS = 'cd:server:ids';
const KEY_RR = 'cd:server:rr:';

@Injectable()
export class RedisServerIdDirectoryService implements ServerIdDirectory, OnModuleDestroy {
  private client: Redis | null = null;

  private ensureClient(): Redis {
    if (!this.client) {
      this.client = new Redis(getRedisConfig());
    }
    return this.client;
  }

  async register(
    serverId: string,
    host: string,
    port: number,
    landType: string,
    opts?: { connectHost?: string; connectPort?: number; connectScheme?: 'ws' | 'wss' },
  ): Promise<void> {
    const now = new Date();
    const entry: ServerEntry = {
      serverId,
      host,
      port,
      landType,
      connectHost: opts?.connectHost,
      connectPort: opts?.connectPort,
      connectScheme: opts?.connectScheme,
      registeredAt: now,
      lastSeenAt: now,
    };

    const client = this.ensureClient();
    const oldJson = await client.get(KEY_BYID + serverId);
    if (oldJson) {
      try {
        const old = JSON.parse(oldJson) as ServerEntry;
        if (old.landType !== landType) {
          await client.hdel(KEY_LAND + old.landType, serverId);
        }
      } catch {
        // ignore parse error
      }
    }

    const json = JSON.stringify({
      ...entry,
      registeredAt: entry.registeredAt.toISOString(),
      lastSeenAt: entry.lastSeenAt.toISOString(),
    });
    await client.set(KEY_BYID + serverId, json);
    await client.hset(KEY_LAND + landType, serverId, json);
    await client.sadd(KEY_IDS, serverId);
  }

  async deregister(serverId: string): Promise<void> {
    const client = this.ensureClient();
    const json = await client.get(KEY_BYID + serverId);
    if (!json) return;
    const entry = JSON.parse(json) as ServerEntry;
    await client.del(KEY_BYID + serverId);
    await client.hdel(KEY_LAND + entry.landType, serverId);
    await client.srem(KEY_IDS, serverId);
  }

  async pickServer(landType: string, ttlMs = SERVER_TTL_MS): Promise<ServerEntry | null> {
    const client = this.ensureClient();
    const map = await client.hgetall(KEY_LAND + landType);
    if (!map || Object.keys(map).length === 0) return null;

    const cutoff = Date.now() - ttlMs;
    const alive: ServerEntry[] = [];
    for (const json of Object.values(map)) {
      const e = this.parseEntry(json);
      if (e && e.lastSeenAt.getTime() > cutoff) {
        alive.push(e);
      }
    }
    if (alive.length === 0) return null;

    const idx = await client.incr(KEY_RR + landType);
    return alive[(idx - 1) % alive.length];
  }

  async listAllServers(): Promise<(ServerEntry & { isStale: boolean })[]> {
    const client = this.ensureClient();
    const ids = await client.smembers(KEY_IDS);
    const cutoff = Date.now() - SERVER_TTL_MS;
    const result: (ServerEntry & { isStale: boolean })[] = [];
    for (const serverId of ids) {
      const json = await client.get(KEY_BYID + serverId);
      if (json) {
        const e = this.parseEntry(json);
        if (e) {
          result.push({ ...e, isStale: e.lastSeenAt.getTime() < cutoff });
        }
      }
    }
    return result;
  }

  private parseEntry(json: string): ServerEntry | null {
    try {
      const o = JSON.parse(json);
      return {
        ...o,
        registeredAt: new Date(o.registeredAt),
        lastSeenAt: new Date(o.lastSeenAt),
      };
    } catch {
      return null;
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.client?.quit();
    this.client = null;
  }
}
