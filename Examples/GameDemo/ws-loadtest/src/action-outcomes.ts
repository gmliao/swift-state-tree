/**
 * Outcomes of the actions a client sent, for runs that inject resolver failures
 * (`scenarios/resolver-test`, design `Notes/plans/2026-11-08-external-input-failure-experiment-design.md`).
 *
 * The server answers every failed action with `ACTION_HANDLER_ERROR` and the error's description
 * as its message (#304 asks for structured codes), so an injected failure is told by its message:
 * - `failed`: the simulated service threw (`SimulatedServiceFailure`) or ran past its own deadline
 *   (`ResolverDeadlineExceeded`), as `Resolver 'ServiceCallResolver' failed: ...`;
 * - `timedOut`: the framework's resolver deadline fired (`Resolvers timed out after ...`).
 * The strings are pinned in `tests/fixtures/resolver-failure-messages.json`, which a GameContent
 * test checks against the server. Any other error, with any message, is not one a run injects:
 * it stays an error (`errorCount`).
 */

export const ACTION_HANDLER_ERROR = "ACTION_HANDLER_ERROR";
export const SERVICE_RESOLVER = "ServiceCallResolver";
const FAILED = new RegExp(`^Resolver '${SERVICE_RESOLVER}' failed: (SimulatedServiceFailure|ResolverDeadlineExceeded)\\(`);
const TIMED_OUT = new RegExp(`^Resolvers timed out after [^:]+: (.+, )?${SERVICE_RESOLVER}(, |$)`);

export type InjectedFailure = "failed" | "timedOut";
/** `errored`: any other error answer; it is also in `errorCount`. */
export type ActionOutcome = "applied" | InjectedFailure | "errored";

/** The injected failure an error names, or undefined for an error no run injects. */
export function injectedFailure(code: unknown, message: unknown): InjectedFailure | undefined {
    if (code !== ACTION_HANDLER_ERROR || typeof message !== "string") return undefined;
    if (FAILED.test(message)) return "failed";
    if (TIMED_OUT.test(message)) return "timedOut";
    return undefined;
}

/**
 * Per connection and phase: the first answer of each request, by outcome, in the phase it
 * arrives in. A request a phase end left unanswered takes its outcome when its answer comes in
 * a later phase, and is also counted in `answeredAfterPhaseEnd`. Over a run, every request sent
 * has one outcome, or is still unanswered at the last phase's end (its `pendingAtEnd`):
 * `Σ actionsSent = Σ (applied + failed + timedOut + errored) + last pendingAtEnd`.
 */
export interface ActionOutcomeCounts {
    /** Action responses. */
    applied: number;
    failed: number;
    timedOut: number;
    /** Error answers that aren't injected failures (also counted in `errorCount`). */
    errored: number;
    /** Of the above, answers to requests an earlier phase end left unanswered. */
    answeredAfterPhaseEnd: number;
    /** Answers that aren't a request's first: a second answer, or one to an unknown request. */
    unmatched: number;
}

export function emptyActionOutcomes(): ActionOutcomeCounts {
    return { applied: 0, failed: 0, timedOut: 0, errored: 0, answeredAfterPhaseEnd: 0, unmatched: 0 };
}

export function sumActionOutcomes(all: ReadonlyArray<ActionOutcomeCounts | undefined>): ActionOutcomeCounts {
    const sum = emptyActionOutcomes();
    for (const counts of all) {
        if (!counts) continue;
        sum.applied += counts.applied;
        sum.failed += counts.failed;
        sum.timedOut += counts.timedOut;
        sum.errored += counts.errored ?? 0;
        sum.answeredAfterPhaseEnd += counts.answeredAfterPhaseEnd;
        sum.unmatched += counts.unmatched;
    }
    return sum;
}
