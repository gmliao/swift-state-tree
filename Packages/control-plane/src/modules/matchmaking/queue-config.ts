import {
  getMatchmakingMinWaitMs,
  getMatchmakingRelaxAfterMs,
} from '../../infra/config/env.config';

/** Per-queue matchmaking parameters. */
export interface QueueConfig {
  minGroupSize: number;
  maxGroupSize: number;
  minWaitMs: number;
  relaxAfterMs: number;
}

/**
 * Parse queueKey to derive group size (e.g. "hero-defense:3v3" -> 3).
 * Falls back to 1 if not parseable.
 */
export function parseGroupSizeFromQueueKey(queueKey: string): number {
  const parts = queueKey.split(':');
  for (const p of parts) {
    const m = p.match(/^(\d+)v\d+$/i) ?? p.match(/^(\d+)$/);
    if (m) return Math.max(1, parseInt(m[1], 10));
  }
  return 1;
}

/** Optional overrides when building QueueConfig. */
export interface QueueConfigOverrides {
  minWaitMs?: number;
  relaxAfterMs?: number;
}

/** Build QueueConfig for a queueKey. */
export function getQueueConfig(
  queueKey: string,
  overrides?: QueueConfigOverrides,
): QueueConfig {
  const size = parseGroupSizeFromQueueKey(queueKey);
  return {
    minGroupSize: size,
    maxGroupSize: size,
    minWaitMs: overrides?.minWaitMs ?? getMatchmakingMinWaitMs(),
    relaxAfterMs: overrides?.relaxAfterMs ?? getMatchmakingRelaxAfterMs(),
  };
}
