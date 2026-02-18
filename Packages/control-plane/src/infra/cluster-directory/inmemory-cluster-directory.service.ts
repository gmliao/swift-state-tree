import { Injectable } from '@nestjs/common';
import type { ClusterDirectory } from './cluster-directory.interface';

/** Lease entry with expiry. */
interface Lease {
  nodeId: string;
  expiresAt: number;
}

const DEFAULT_TTL_MS = 8000;

/**
 * In-memory ClusterDirectory implementation for tests.
 * Single-process; no Redis required.
 */
@Injectable()
export class InMemoryClusterDirectoryService implements ClusterDirectory {
  private readonly sessions = new Map<string, Lease>();
  private ttlMs = DEFAULT_TTL_MS;

  setTtlMs(ms: number): void {
    this.ttlMs = ms;
  }

  private ttlToMs(ttlSeconds?: number): number {
    return ttlSeconds ? ttlSeconds * 1000 : this.ttlMs;
  }

  async registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void> {
    const ms = this.ttlToMs(ttlSeconds);
    this.sessions.set(userId, {
      nodeId,
      expiresAt: Date.now() + ms,
    });
  }

  async refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void> {
    const lease = this.sessions.get(userId);
    if (lease && lease.nodeId === nodeId) {
      const ms = this.ttlToMs(ttlSeconds);
      lease.expiresAt = Date.now() + ms;
    }
  }

  async getNodeId(userId: string): Promise<string | null> {
    const lease = this.sessions.get(userId);
    if (!lease) return null;
    if (lease.expiresAt < Date.now()) {
      this.sessions.delete(userId);
      return null;
    }
    return lease.nodeId;
  }

  async unregisterSession(userId: string, nodeId: string): Promise<void> {
    const lease = this.sessions.get(userId);
    if (lease?.nodeId === nodeId) {
      this.sessions.delete(userId);
    }
  }
}
