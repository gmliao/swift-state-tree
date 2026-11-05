import { describe, it, expect } from "vitest";
import { encode } from "@msgpack/msgpack";
import { DynamicKeyTracker, decodeRaw } from "../src/protocol";
import { decodeFailuresOf } from "../src/report/render-html";
import { aggregateReports, decodeErrorBreakdown } from "../src/run";
import { WorkerSession } from "../src/worker";

// Opcodes: 107 merged broadcast frame; 1 firstSync, 2 diff; patch op 1 = set.
const merged = (state: unknown[]) => [107, state, []];

describe("DynamicKeyTracker (the SDK's dynamic key rules)", () => {
    it("accepts a slot defined earlier in the same scope", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe(merged([2, [111, [0, "monster-1"], 1, 5]]));
        tracker.observe(merged([2, [111, 0, 1, 6]]));
        expect(tracker.errors).toBe(0);
    });

    it("counts a broadcast slot that was never defined for this client (#90)", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe(merged([2, [111, 0, 1, 6]]));
        expect(tracker.errors).toBe(1);
        expect(tracker.firstError).toContain("slot 0 used before definition");
    });

    it("keeps the broadcast and per-player scopes apart", () => {
        const tracker = new DynamicKeyTracker();
        // Defined in a per-player firstSync: not known to the broadcast scope.
        tracker.observe([1, [111, [0, "monster-1"], 1, 5]]);
        tracker.observe(merged([2, [111, 0, 1, 6]]));
        expect(tracker.errors).toBe(1);
    });

    it("clears a scope on its firstSync, as the SDK does", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe(merged([2, [111, [0, "a"], 1, 1]]));
        tracker.observe(merged([1, [111, [3, "b"], 1, 1]]));
        tracker.observe(merged([2, [111, 0, 1, 2]]));
        expect(tracker.errors).toBe(1);
    });

    it("resolves multi-key patches and counts one error per frame", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe([2, [111, [[0, "p"], [1, "q"]], 1, 1]]);
        tracker.observe([2, [111, [0, 1], 1, 1]]);
        expect(tracker.errors).toBe(0);
        tracker.observe([2, [111, [0, 7], 1, 1], [111, 9, 1, 1]]);
        expect(tracker.errors).toBe(1);
    });

    it("ignores transport messages, legacy string paths and jsonObject frames", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe([102, "r1", {}]);
        tracker.observe([2, ["/score", 1, 3]]);
        tracker.observe({ type: "diff", patches: [] });
        expect(tracker.errors).toBe(0);
    });

    it("reads MessagePack frames through decodeRaw", () => {
        const tracker = new DynamicKeyTracker();
        tracker.observe(decodeRaw(encode(merged([2, [111, 4, 1, 6]]))));
        expect(tracker.errors).toBe(1);
    });
});

describe("decode errors in the report", () => {
    const report = (decodeErrorAt: number[]) =>
        ({ rttMs: [], rttAt: [], stateUpdateIntervalsMs: [], updateAt: [], sentAt: [], errorAt: [], closes: [], decodeErrorAt }) as any;

    it("counts only errors inside the measured window", () => {
        expect(aggregateReports([report([5, 15, 25])], 10, 20).decodeErrorCount).toBe(1);
    });

    it("splits errors around the window and keeps after-leave errors apart", () => {
        const r = { ...report([5, 15, 25]), decodeErrorsAfterLeave: 2 };
        expect(decodeErrorBreakdown([r], 10, 20)).toEqual({ beforeWindow: 1, inWindow: 1, afterWindow: 1, afterLeave: 2 });
    });

    it("fails a phase on an error before leave even outside the measured window (a ramp join)", () => {
        const phase = {
            report: { decodeErrorCount: 0 },
            phaseTotals: {
                decodeErrorCount: 2,
                decodeErrors: { beforeWindow: 2, inWindow: 0, afterWindow: 0, afterLeave: 0 },
                firstDecodeError: "Dynamic key slot 0 used before definition"
            }
        } as any;
        expect(decodeFailuresOf(phase)).toEqual([
            "decodeErrors 2 > 0 before leave (before window 2, in window 0, after window 0); first: Dynamic key slot 0 used before definition"
        ]);
    });

    it("does not fail on errors after the clients began to close", () => {
        const phase = {
            report: { decodeErrorCount: 0 },
            phaseTotals: { decodeErrorCount: 0, decodeErrors: { beforeWindow: 0, inWindow: 0, afterWindow: 0, afterLeave: 3 } }
        } as any;
        expect(decodeFailuresOf(phase)).toEqual([]);
    });

    it("records an error after leave separately in the session", () => {
        const session = new WorkerSession();
        session.recordDecodeError(1, "a");
        session.recordDecodeError(2, "b", true);
        const m = (session as any).metrics;
        expect(m.decodeErrorAt).toEqual([1]);
        expect(m.decodeErrorsAfterLeave).toBe(1);
        expect(m.firstDecodeError).toBe("a");
    });
});
