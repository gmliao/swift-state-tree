import { describe, it, expect } from "vitest";
import { SendSchedule, sendOffsetMs, defaultWarmupMs } from "../src/send-schedule";

describe("sendOffsetMs", () => {
    it("spreads K clients over [0, P) and is stable per key", () => {
        const period = 1000;
        const offsets = Array.from({ length: 200 }, (_, i) => sendOffsetMs(`room-p5-${Math.floor(i / 5)}-s${i % 5}`, period));
        expect(offsets.every((o) => o >= 0 && o < period)).toBe(true);
        expect(new Set(offsets.map((o) => Math.floor(o))).size).toBeGreaterThan(150);
        // Roughly uniform: every 100 ms tenth gets some clients.
        const tenths = new Set(offsets.map((o) => Math.floor(o / 100)));
        expect(tenths.size).toBe(10);
        expect(sendOffsetMs("room-p5-0-s0", period)).toBe(offsets[0]);
    });

    it("spreads keys that differ only in their last character", () => {
        // One room's five players: their offsets must not cluster.
        const period = 200;
        const offsets = Array.from({ length: 5 }, (_, s) => sendOffsetMs(`rabc1234-room-p5-7-s${s}`, period)).sort((a, b) => a - b);
        const minGap = Math.min(...offsets.slice(1).map((o, i) => o - offsets[i]));
        expect(minGap).toBeGreaterThan(2);
        // Over many rooms, no 2 ms slot of the period holds more than a few of 100 clients.
        const many = Array.from({ length: 100 }, (_, i) => sendOffsetMs(`rabc1234-room-p5-${Math.floor(i / 5)}-s${i % 5}`, period));
        const perSlot = new Map<number, number>();
        for (const o of many) perSlot.set(Math.floor(o / 2), (perSlot.get(Math.floor(o / 2)) ?? 0) + 1);
        expect(Math.max(...perSlot.values())).toBeLessThanOrEqual(5);
    });
});

describe("SendSchedule", () => {
    it("yields origin + offset + n·period, starting at the first slot after the join", () => {
        const s = new SendSchedule(10_000, 100, 30);
        s.startAt(10_250);
        expect(s.nextDueMs()).toBe(10_330);
        expect(s.takeDue(10_329)).toEqual([]);
        expect(s.takeDue(10_330)).toEqual([10_330]);
        expect(s.nextDueMs()).toBe(10_430);
    });

    it("turns a stalled timer into late intended sends, not missing ones", () => {
        const s = new SendSchedule(0, 100, 0);
        s.startAt(0);
        expect(s.takeDue(0)).toEqual([0]);
        // The event loop stalls for 350 ms: the slots it missed are all still sent, each with
        // its own intended time, so RTT from intended time includes the stall.
        expect(s.takeDue(350)).toEqual([100, 200, 300]);
        expect(s.takeDue(350)).toEqual([]);
        expect(s.nextDueMs()).toBe(400);
    });

    it("stops at the phase end", () => {
        const s = new SendSchedule(0, 100, 50);
        s.startAt(0);
        expect(s.takeDue(1000, 300)).toEqual([50, 150, 250]);
    });
});

describe("defaultWarmupMs", () => {
    it("is the ramp plus 2 s, at most half the phase", () => {
        expect(defaultWarmupMs(500, 60_000)).toBe(2500);
        expect(defaultWarmupMs(0, 3_000)).toBe(1500);
    });
});
