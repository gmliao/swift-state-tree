import { randomUUID } from 'crypto';

/**
 * Centralized environment configuration.
 * All env keys and defaults in one place. Works with .env (local) and K8s ConfigMap/Secret.
 */

/** Redis connection config. */
export interface RedisConfig {
  host: string;
  port: number;
  /** Redis database number (0-15). Use different DB for e2e tests to isolate from dev. */
  db?: number;
}

/** Matchmaking role for horizontal scaling. */
export type MatchmakingRole = 'api' | 'queue-worker' | 'all';

/** Env key constants (for reference and K8s). */
export const EnvKeys = {
  PORT: 'PORT',
  REDIS_HOST: 'REDIS_HOST',
  REDIS_PORT: 'REDIS_PORT',
  REDIS_DB: 'REDIS_DB',
  NODE_ID: 'NODE_ID',
  MATCHMAKING_ROLE: 'MATCHMAKING_ROLE',
  MATCHMAKING_MIN_WAIT_MS: 'MATCHMAKING_MIN_WAIT_MS',
  MATCHMAKING_RELAX_AFTER_MS: 'MATCHMAKING_RELAX_AFTER_MS',
  USE_NODE_INBOX_FOR_MATCH_ASSIGNED: 'USE_NODE_INBOX_FOR_MATCH_ASSIGNED',
  CLUSTER_DIRECTORY_TTL_SECONDS: 'CLUSTER_DIRECTORY_TTL_SECONDS',
} as const;

function getEnvString(key: string, defaultValue: string): string {
  const v = process.env[key];
  return (v?.trim() ?? defaultValue);
}

function getEnvInt(key: string, defaultValue: number): number {
  const v = process.env[key];
  if (v == null || v.trim() === '') return defaultValue;
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? defaultValue : n;
}

function getEnvBool(key: string, defaultValue: boolean): boolean {
  const v = process.env[key]?.toLowerCase();
  if (v == null || v === '') return defaultValue;
  return v === 'true' || v === '1';
}

/** HTTP server port. */
export function getPort(): number {
  return getEnvInt(EnvKeys.PORT, 3000);
}

/** Redis host. */
export function getRedisHost(): string {
  return getEnvString(EnvKeys.REDIS_HOST, 'localhost');
}

/** Redis port. */
export function getRedisPort(): number {
  return getEnvInt(EnvKeys.REDIS_PORT, 6379);
}

/** Redis connection config. */
export function getRedisConfig(): RedisConfig {
  const config: RedisConfig = { host: getRedisHost(), port: getRedisPort() };
  const db = getEnvInt(EnvKeys.REDIS_DB, 0);
  if (db >= 0 && db <= 15) {
    config.db = db;
  }
  return config;
}

/** NestJS injection token for this node's unique ID. */
export const NODE_ID = 'NODE_ID' as const;

/** Node ID from env or generated UUID. Used for ClusterDirectory and NodeInbox. */
export function resolveNodeId(): string {
  const fromEnv = process.env[EnvKeys.NODE_ID];
  if (fromEnv?.trim()) return fromEnv.trim();
  return randomUUID();
}

/** Matchmaking role. */
export function getMatchmakingRole(): MatchmakingRole {
  const raw = process.env[EnvKeys.MATCHMAKING_ROLE]?.toLowerCase();
  if (raw === 'api' || raw === 'queue-worker' || raw === 'all') return raw;
  return 'all';
}

/** Matchmaking min wait (ms) before a ticket can be matched. */
export function getMatchmakingMinWaitMs(): number {
  return getEnvInt(EnvKeys.MATCHMAKING_MIN_WAIT_MS, 3000);
}

/** Matchmaking relax after (ms) - allow smaller groups. */
export function getMatchmakingRelaxAfterMs(): number {
  return getEnvInt(EnvKeys.MATCHMAKING_RELAX_AFTER_MS, 30000);
}

/** Use node inbox for match.assigned routing (vs broadcast). Default true for multi-node. */
export function getUseNodeInboxForMatchAssigned(): boolean {
  return getEnvBool(EnvKeys.USE_NODE_INBOX_FOR_MATCH_ASSIGNED, true);
}

/** ClusterDirectory session lease TTL (seconds). */
export function getClusterDirectoryTtlSeconds(): number {
  return getEnvInt(EnvKeys.CLUSTER_DIRECTORY_TTL_SECONDS, 8);
}
