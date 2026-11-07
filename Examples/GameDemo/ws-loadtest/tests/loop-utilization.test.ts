import { describe, expect, it } from "vitest";
import type { EventLoopUtilization } from "node:perf_hooks";
import { LoopUtilizationSpans, type LoopSpan } from "../src/loop-utilization";
import { startCpuSampler } from "../src/client-cpu";

/** A cumulative ELU reader whose busy time the test sets; diffs like Node's. */
function fakeElu() {
    let idle = 0;
    let active = 0;
    const read = (a?: EventLoopUtilization, b?: EventLoopUtilization): EventLoopUtilization => {
        if (a && b) {
            const di = a.idle - b.idle;
            const da = a.active - b.active;
            return { idle: di, active: da, utilization: da / (di + da) };
        }
        return { idle, active, utilization: active / (idle + active || 1) };
    };
    return { read, spend: (busyMs: number, idleMs: number) => { active += busyMs; idle += idleMs; } };
}

describe("loop utilization spans", () => {
    it("ends a span at the first tick past a 1 s boundary, with that span's share", () => {
        const elu = fakeElu();
        const spans: LoopSpan[] = [];
        const s = new LoopUtilizationSpans((span) => spans.push(span), elu.read);
        s.start(10_200);
        elu.spend(100, 200);
        s.tick(10_700); // same second: no span yet
        elu.spend(400, 0);
        s.tick(11_200); // crossed 11 s
        elu.spend(450, 50);
        s.tick(11_700);
        s.stop(11_900);
        expect(spans).toEqual([
            { from: 10_200, to: 11_200, elu: 0.714 },
            { from: 11_200, to: 11_900, elu: 0.9 }
        ]);
    });

    it("covers a stall with one longer span", () => {
        const elu = fakeElu();
        const spans: LoopSpan[] = [];
        const s = new LoopUtilizationSpans((span) => spans.push(span), elu.read);
        s.start(0);
        elu.spend(3_000, 0); // the loop was blocked; the next tick comes 3 s later
        s.tick(3_100);
        expect(spans).toEqual([{ from: 0, to: 3_100, elu: 1 }]);
    });

    it("writes nothing before start or after stop", () => {
        const spans: LoopSpan[] = [];
        const s = new LoopUtilizationSpans((span) => spans.push(span), fakeElu().read);
        s.tick(5_000);
        s.start(5_000);
        s.stop(5_000);
        s.tick(9_000);
        expect(spans).toEqual([]);
    });

    it("reads the real event loop: a busy stretch shows", async () => {
        const spans: LoopSpan[] = [];
        const s = new LoopUtilizationSpans((span) => spans.push(span));
        const t0 = Date.now();
        s.start(t0);
        while (Date.now() - t0 < 60) {
            // busy
        }
        s.stop(Date.now());
        expect(spans).toHaveLength(1);
        expect(spans[0].elu).toBeGreaterThan(0.5);
    });
});

describe("the CPU sampler's tick hook", () => {
    it("calls onTick with each sample's time, and no extra timer runs without it", async () => {
        const ticks: number[] = [];
        const stop = startCpuSampler(5, Date.now, () => 0, (t) => ticks.push(t));
        await new Promise((resolve) => setTimeout(resolve, 40));
        const samples = stop();
        expect(ticks.length).toBeGreaterThan(0);
        // Every tick is a sample's time (the first and last samples are taken outside the tick).
        expect(ticks.every((t) => samples.some(([st]) => st === t))).toBe(true);
    });
});
