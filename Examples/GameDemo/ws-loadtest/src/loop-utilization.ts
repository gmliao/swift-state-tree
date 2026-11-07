/**
 * Load-client event-loop utilization per span of about 1 s: the share of the span this worker's
 * event loop was busy (`performance.eventLoopUtilization`), for the analysis's per-window
 * client-bound check. ELU is cumulative and diffable, so no timer of its own is added and the
 * loop-delay histogram (`loop-delay`) is left untouched: the CPU sampler's existing tick calls
 * `tick`, and a span ends at the first tick past a 1 s wall-clock boundary.
 */
import { performance, type EventLoopUtilization } from "node:perf_hooks";

/** One span's utilization: `[from, to)` ms since epoch, `elu` in [0, 1]. */
export interface LoopSpan {
    from: number;
    to: number;
    elu: number;
}

type EluReader = (a?: EventLoopUtilization, b?: EventLoopUtilization) => EventLoopUtilization;

export class LoopUtilizationSpans {
    private last: { at: number; elu: EventLoopUtilization } | undefined;

    constructor(
        private readonly emit: (span: LoopSpan) => void,
        private readonly read: EluReader = (a, b) => performance.eventLoopUtilization(a, b)
    ) {}

    /** Starts the first span at `now`. */
    start(now: number): void {
        this.last = { at: now, elu: this.read() };
    }

    /** Ends the current span when `now` has crossed a 1 s boundary since it began. */
    tick(now: number): void {
        if (this.last !== undefined && Math.floor(now / 1000) > Math.floor(this.last.at / 1000)) {
            this.close(now);
        }
    }

    /** Ends the last span at `now`. */
    stop(now: number): void {
        if (this.last !== undefined && now > this.last.at) {
            this.close(now);
        }
        this.last = undefined;
    }

    private close(now: number): void {
        const last = this.last!;
        const current = this.read();
        const elu = this.read(current, last.elu).utilization;
        this.emit({ from: last.at, to: now, elu: Math.round(elu * 1000) / 1000 });
        this.last = { at: now, elu: current };
    }
}
