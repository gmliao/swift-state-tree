import os from "node:os";
import { describe, it, expect, vi } from "vitest";
import { clientCpuCores, cpuAt, measureClientCpu, startCpuSampler, type CpuSample } from "../src/client-cpu";

describe("client CPU", () => {
    const busyHalf: CpuSample[] = [
        [1_000, 0],
        [2_000, 500],
        [3_000, 1_000]
    ];
    const busyFull: CpuSample[] = [
        [1_000, 0],
        [3_000, 2_000]
    ];

    it("interpolates CPU time between samples and refuses times outside them", () => {
        expect(cpuAt(busyHalf, 1_500)).toBe(250);
        expect(cpuAt(busyHalf, 2_000)).toBe(500);
        expect(cpuAt(busyHalf, 999)).toBeUndefined();
        expect(cpuAt(busyHalf, 3_001)).toBeUndefined();
        expect(cpuAt([], 1_000)).toBeUndefined();
    });

    it("gives each worker's share of one core in the window, and the total", () => {
        const cpu = measureClientCpu([busyHalf, busyFull], 1_500, 2_500, 8);
        expect(cpu).toEqual({ workers: 2, perWorkerPct: { min: 50, mean: 75, max: 100 }, orchestratorPct: null, totalPct: 150, cores: 8 });
    });

    it("adds the orchestrator to the total and reports it apart", () => {
        const cpu = measureClientCpu([busyHalf, busyFull], 1_500, 2_500, 8, busyHalf);
        expect(cpu).toEqual({
            workers: 2,
            perWorkerPct: { min: 50, mean: 75, max: 100 },
            orchestratorPct: 50,
            totalPct: 200,
            cores: 8
        });
        expect(measureClientCpu([busyHalf], 1_500, 2_500, 8).orchestratorPct).toBeNull();
        expect(measureClientCpu([busyHalf], 1_500, 2_500, 8, [[2_000, 0]]).orchestratorPct).toBeNull();
    });

    it("leaves out a worker whose samples do not cover the window", () => {
        const late: CpuSample[] = [
            [2_000, 0],
            [3_000, 100]
        ];
        const cpu = measureClientCpu([busyHalf, late], 1_500, 2_500, 4);
        expect(cpu.workers).toBe(1);
        expect(cpu.totalPct).toBe(50);
        expect(measureClientCpu([busyHalf], 2_000, 2_000, 4).workers).toBe(0);
    });

    it("samples this process from start to stop", async () => {
        let t = 0;
        let cpu = 0;
        const stop = startCpuSampler(5, () => (t += 10), () => (cpu += 3));
        await new Promise((resolve) => setTimeout(resolve, 30));
        const samples = stop();
        expect(samples.length).toBeGreaterThanOrEqual(3);
        for (let i = 1; i < samples.length; i += 1) {
            expect(samples[i][0]).toBeGreaterThan(samples[i - 1][0]);
            expect(samples[i][1]).toBeGreaterThan(samples[i - 1][1]);
        }
    });
});

describe("the client's CPU budget", () => {
    it("is its affinity mask, not the host's CPU count", () => {
        // As on a host with 12 CPUs whose load client is pinned to 4.
        const cpus = vi.spyOn(os, "cpus").mockReturnValue(new Array(12).fill(os.cpus()[0]));
        const allowed = vi.spyOn(os, "availableParallelism").mockReturnValue(4);
        try {
            expect(clientCpuCores()).toBe(4);
        } finally {
            cpus.mockRestore();
            allowed.mockRestore();
        }
    });
});
