import { hash32 } from "./connect-schedule";

/**
 * How clients send actions.
 * - `spread` (default): each client sends on its own schedule, `origin + offset + n · period`,
 *   with a stable per-client offset in `[0, period)`. RTT is measured from the intended send
 *   time, so a client-side stall shows up as larger RTT, not as missing samples.
 * - `lockstep`: the legacy behaviour; one timer per worker sends for every joined client at
 *   once, and RTT is measured from the actual send.
 */
export type SendMode = "spread" | "lockstep";

export const SEND_MODES: readonly SendMode[] = ["spread", "lockstep"];

/** Stable send offset in `[0, periodMs)` for a connection key. */
export function sendOffsetMs(key: string, periodMs: number): number {
    return (hash32(`send:${key}`) / 0x1_0000_0000) * periodMs;
}

/**
 * One client's intended send times: `origin + offset + n · period` for n ≥ 0. `takeDue(now)`
 * returns every intended time up to `now` that hasn't been taken, so a late timer catches up
 * with the sends it missed instead of dropping them.
 */
export class SendSchedule {
    private nextIndex = 0;

    constructor(
        private readonly originMs: number,
        private readonly periodMs: number,
        private readonly offsetMs: number
    ) {}

    /** Skips the slots before `t` (the client joined at `t`). */
    startAt(t: number): void {
        const first = Math.ceil((t - this.originMs - this.offsetMs) / this.periodMs);
        this.nextIndex = Math.max(this.nextIndex, first);
    }

    nextDueMs(): number {
        return this.originMs + this.offsetMs + this.nextIndex * this.periodMs;
    }

    /** Intended times ≤ `now` not taken yet, oldest first, and only those before `endMs`. */
    takeDue(now: number, endMs = Number.POSITIVE_INFINITY): number[] {
        const due: number[] = [];
        while (this.nextDueMs() <= now && this.nextDueMs() < endMs) {
            due.push(this.nextDueMs());
            this.nextIndex += 1;
        }
        return due;
    }
}

/** Default warm-up: the connect ramp plus 2 s for joins and first syncs, at most half the phase. */
export const DEFAULT_WARMUP_EXTRA_MS = 2000;

export function defaultWarmupMs(connectRampMs: number, durationMs: number): number {
    return Math.min(Math.max(0, connectRampMs) + DEFAULT_WARMUP_EXTRA_MS, durationMs / 2);
}

export const DEFAULT_WINDOW_MS = 1000;
