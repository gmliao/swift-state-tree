/**
 * Runs once before all e2e tests.
 * Flushes Redis matchmaking/BullMQ keys to avoid "No server available" from stale jobs.
 */
import Redis from 'ioredis';

export default async function globalSetup(): Promise<void> {
  const host = process.env.REDIS_HOST ?? '127.0.0.1';
  const port = parseInt(process.env.REDIS_PORT ?? '6379', 10);
  const db = parseInt(process.env.REDIS_DB ?? '1', 10);

  const redis = new Redis({ host, port, db });
  try {
    const keys = await redis.keys('bull:enqueueTicket*');
    if (keys.length > 0) {
      await redis.del(...keys);
    }
    const matchKeys = await redis.keys('matchmaking:*');
    if (matchKeys.length > 0) {
      await redis.del(...matchKeys);
    }
  } finally {
    await redis.quit();
  }
}
