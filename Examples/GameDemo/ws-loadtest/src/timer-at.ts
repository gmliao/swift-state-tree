/**
 * Runs `fn` once the wall clock reaches `at`. Node timers run on a monotonic clock and can fire
 * up to a millisecond before the `Date.now()` target, so a timer that fires early re-arms for
 * the rest: a read taken in `fn` is never before `at`.
 */
export function timerAt<Handle>(
    at: number,
    fn: () => void,
    now: () => number = Date.now,
    schedule: (fn: () => void, ms: number) => Handle = setTimeout as unknown as (fn: () => void, ms: number) => Handle,
    clear: (handle: Handle) => void = clearTimeout as unknown as (handle: Handle) => void
): { cancel(): void } {
    let cancelled = false;
    let handle: Handle;
    const arm = () => {
        handle = schedule(() => {
            if (cancelled) return;
            if (now() < at) {
                arm();
            } else {
                fn();
            }
        }, Math.max(0, at - now()));
    };
    arm();
    return {
        cancel() {
            cancelled = true;
            clear(handle);
        }
    };
}

/** Resolves once the wall clock reaches `at` (`timerAt`: never before it). */
export function untilWallClock(
    at: number,
    now: () => number = Date.now,
    schedule?: (fn: () => void, ms: number) => unknown
): Promise<void> {
    return new Promise((resolve) => {
        timerAt(at, resolve, now, schedule);
    });
}

/**
 * Waits for `--start-at`: resolves once the wall clock reaches `startAt`, never before it, so the
 * time the first phase records as started is never earlier than the barrier the other instance
 * waits for. A time already past is refused (a late start would break that barrier).
 */
export async function waitForStartAt(
    startAt: number,
    now: () => number = Date.now,
    schedule?: (fn: () => void, ms: number) => unknown
): Promise<void> {
    const waitMs = startAt - now();
    if (waitMs < 0) {
        throw new Error(`--start-at ${startAt} is ${-waitMs} ms in the past once the workers are up`);
    }
    await untilWallClock(startAt, now, schedule);
}
