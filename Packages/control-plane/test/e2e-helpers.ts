import { INestApplication } from '@nestjs/common';

const CLOSE_TIMEOUT_MS = 5000;

/**
 * Closes the NestJS app and waits for BullMQ Worker/Redis connections to shut down.
 * Uses a timeout to prevent Jest from hanging indefinitely.
 */
export async function closeApp(app: INestApplication): Promise<void> {
  let timeoutId: ReturnType<typeof setTimeout>;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error('App close timeout')), CLOSE_TIMEOUT_MS);
  });
  try {
    await Promise.race([app.close(), timeoutPromise]);
  } catch (err) {
    if (err instanceof Error && err.message === 'App close timeout') {
      console.warn(
        '[e2e] app.close() timed out - BullMQ connections may still be closing',
      );
    } else {
      throw err;
    }
  } finally {
    clearTimeout(timeoutId!);
  }
}
