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
