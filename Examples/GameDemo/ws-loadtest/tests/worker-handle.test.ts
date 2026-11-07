import { describe, expect, it } from "vitest";
import path from "node:path";
import { startWorkers } from "../src/run";

// A convergence driver's control command must never cost the run its report: a worker too busy
// to answer within the control timeout makes that command fail, and the worker keeps running,
// so its phase report and shutdown report still arrive (a saturated client once lost its
// report this way, though for another reason; this pins the control path).
describe("worker handle", () => {
    it("a worker busy past the control timeout fails that command and still sends its reports", async () => {
        process.env.BUSY_MS = "400";
        const [worker] = startWorkers(1, { scriptPath: path.join(__dirname, "fixtures", "busy-control-worker.cjs"), execArgv: [] });
        try {
            await expect(worker.control({ name: "stopSending" } as any, 100)).rejects.toThrow(/no control reply within 100 ms/);
            // The late reply arrives while the run goes on; it must not be taken for another reply.
            const report = await worker.request<{ ok: boolean }>({ type: "start" }, "report", 5_000);
            expect(report).toEqual({ ok: true });
            const closes = await worker.request<unknown[]>({ type: "shutdown" }, "shutdownReport", 5_000, "closes");
            expect(closes).toEqual([]);
            await worker.exited(5_000);
        } finally {
            worker.kill();
            delete process.env.BUSY_MS;
        }
    });
});
