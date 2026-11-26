import { describe, it, expect } from "vitest";
import { timerAt, untilWallClock, waitForStartAt } from "../src/timer-at";

describe("timerAt", () => {
    it("re-arms when the timer fires before the wall-clock target", () => {
        let now = 1000;
        const armed: Array<{ ms: number; fn: () => void }> = [];
        const schedule = (fn: () => void, ms: number) => {
            armed.push({ fn, ms });
            return armed.length;
        };
        let firedAt: number | undefined;
        timerAt(1010, () => (firedAt = now), () => now, schedule, () => {});
        expect(armed[0].ms).toBe(10);
        now = 1009; // fired 1 ms early
        armed[0].fn();
        expect(firedAt).toBeUndefined();
        expect(armed[1].ms).toBe(1);
        now = 1010;
        armed[1].fn();
        expect(firedAt).toBe(1010);
    });

    it("does not run after cancel, even when re-armed", () => {
        let now = 0;
        const armed: Array<() => void> = [];
        const cleared: unknown[] = [];
        let fired = false;
        const timer = timerAt(5, () => (fired = true), () => now, (fn) => armed.push(fn), (h) => cleared.push(h));
        now = 4;
        armed[0]();
        timer.cancel();
        now = 5;
        armed[1]();
        expect(fired).toBe(false);
        expect(cleared).toEqual([2]);
    });

    it("untilWallClock resolves no earlier than its target", async () => {
        for (let i = 0; i < 20; i += 1) {
            const target = Date.now() + 3;
            await untilWallClock(target);
            expect(Date.now()).toBeGreaterThanOrEqual(target);
        }
    });

    it("waitForStartAt does not resolve when its timer fires 1 ms early (#916)", async () => {
        let now = 1000;
        const armed: Array<() => void> = [];
        let resolvedAt: number | undefined;
        const waiting = waitForStartAt(1010, () => now, (fn) => armed.push(fn)).then(() => (resolvedAt = now));
        now = 1009; // the timer fires 1 ms before the wall-clock target
        armed[0]();
        await Promise.resolve();
        expect(resolvedAt).toBeUndefined();
        expect(armed).toHaveLength(2); // re-armed for the remaining millisecond
        now = 1010;
        armed[1]();
        await waiting;
        expect(resolvedAt).toBe(1010);
    });

    it("waitForStartAt refuses a time already past", async () => {
        await expect(waitForStartAt(990, () => 1000)).rejects.toThrow("--start-at 990 is 10 ms in the past once the workers are up");
    });
});
