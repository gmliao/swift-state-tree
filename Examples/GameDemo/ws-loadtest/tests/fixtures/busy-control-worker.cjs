// A stand-in worker for tests/worker-handle.test.ts: it answers a control command only after
// being busy for `busyMs` (a worker whose loop is saturated), and a "start" with its report.
process.on("message", (message) => {
    if (message.type === "control") {
        const until = Date.now() + Number(process.env.BUSY_MS ?? 300);
        while (Date.now() < until) {
            // busy: no event-loop turn until the deadline
        }
        process.send({ type: "controlReply", id: message.id, result: { stopped: true } });
    } else if (message.type === "start") {
        process.send({ type: "report", report: { ok: true } });
    } else if (message.type === "shutdown") {
        process.send({ type: "shutdownReport", closes: [] });
        process.disconnect();
    }
});
