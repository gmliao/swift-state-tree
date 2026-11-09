import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { ACTION_HANDLER_ERROR, injectedFailure, isInjectedJoinFailure, limitRejection, sumActionOutcomes } from "../src/action-outcomes";
import { summarizeJoinFailures } from "../src/run";
import { WorkerSession } from "../src/worker";

// The server's messages for resolver-test's failures; GameContentTests checks the server still
// produces them (ResolverTestLandTests, "Failed actions' error messages ...").
const messages = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/resolver-failure-messages.json"), "utf8"));

// The action-job caps' rejection messages, from the Swift source (`ActionLimitRejection.description`),
// with a limit filled in: the classifier must match what the server sends.
const limitsSource = fs.readFileSync(path.join(__dirname, "../../../../Sources/SwiftStateTree/Resolver/ActionJobLimits.swift"), "utf8");
function limitMessage(caseName: string, limit: number): string {
    const m = limitsSource.match(new RegExp(String.raw`case \.${caseName}\(let limit\):\s*return "([^"]*)"`));
    if (!m) throw new Error(`no ${caseName} message in ActionJobLimits.swift`);
    return m[1].replace(String.raw`\(limit)`, String(limit));
}
const zero = { applied: 0, failed: 0, timedOut: 0, abandonedLimitRejected: 0, inFlightLimitRejected: 0, errored: 0, answeredAfterPhaseEnd: 0, unmatched: 0 };

describe("action outcomes", () => {
    it("classifies the server's injected failures by their pinned messages", () => {
        expect(injectedFailure(ACTION_HANDLER_ERROR, messages.failed)).toBe("failed");
        expect(injectedFailure(ACTION_HANDLER_ERROR, messages.serviceDeadline)).toBe("failed");
        expect(injectedFailure(ACTION_HANDLER_ERROR, messages.timedOut)).toBe("timedOut");
        expect(injectedFailure(ACTION_HANDLER_ERROR, "Resolvers timed out after 0.5 seconds: OtherResolver, ServiceCallResolver")).toBe("timedOut");
    });

    it("leaves every other error unclassified", () => {
        expect(injectedFailure("ACTION_INVALID_PAYLOAD", messages.failed)).toBeUndefined();
        expect(injectedFailure(ACTION_HANDLER_ERROR, "Resolver 'OtherResolver' failed: SimulatedServiceFailure(callIndex: 0)")).toBeUndefined();
        expect(injectedFailure(ACTION_HANDLER_ERROR, "Resolver 'ServiceCallResolver' failed: missingParameter(\"CallServiceAction\")")).toBeUndefined();
        expect(injectedFailure(ACTION_HANDLER_ERROR, "Resolvers timed out after 1.0 seconds: ServiceCallResolverX")).toBeUndefined();
        expect(injectedFailure(ACTION_HANDLER_ERROR, "boom")).toBeUndefined();
        expect(injectedFailure(ACTION_HANDLER_ERROR, undefined)).toBeUndefined();
    });

    it("classifies the action-job caps' rejections by the server's messages", () => {
        const abandoned = limitMessage("abandonedResolverLimit", 256);
        const inFlight = limitMessage("inFlightLimit", 8);
        expect(abandoned).toBe("action rejected: abandoned-resolver limit reached (256 in the process)");
        expect(inFlight).toBe("action rejected: in-flight limit reached (8 per session)");
        expect(limitRejection(ACTION_HANDLER_ERROR, abandoned)).toBe("abandonedLimitRejected");
        expect(limitRejection(ACTION_HANDLER_ERROR, inFlight)).toBe("inFlightLimitRejected");
        expect(injectedFailure(ACTION_HANDLER_ERROR, abandoned)).toBeUndefined();
        expect(limitRejection(ACTION_HANDLER_ERROR, messages.timedOut)).toBeUndefined();
        expect(limitRejection("ACTION_INVALID_PAYLOAD", abandoned)).toBeUndefined();
        expect(limitRejection(ACTION_HANDLER_ERROR, abandoned + " extra")).toBeUndefined();
        expect(limitRejection(ACTION_HANDLER_ERROR, undefined)).toBeUndefined();
    });

    it("counts cap rejections apart, as answers that aren't errors", () => {
        const session = new WorkerSession();
        for (const id of ["a", "b", "c"]) session.recordSend(id, 0);
        const error = (id: string, message: string) =>
            session.handleDecodedMessage({ kind: "error", code: ACTION_HANDLER_ERROR, message, details: { requestID: id } }, 10);
        error("a", limitMessage("abandonedResolverLimit", 256));
        error("b", limitMessage("abandonedResolverLimit", 256));
        error("c", limitMessage("inFlightLimit", 8));
        expect(session.metrics.actionOutcomes).toEqual({ ...zero, abandonedLimitRejected: 2, inFlightLimitRejected: 1 });
        expect(session.metrics.errorCount).toBe(0);
        expect(session.metrics.rttMs).toHaveLength(3);
    });

    it("counts each answered request once by outcome; injected failures aren't errors", () => {
        const session = new WorkerSession();
        for (const id of ["a", "b", "c", "d", "e"]) session.recordSend(id, 0);
        const error = (id: string, code: string, message: string) =>
            session.handleDecodedMessage({ kind: "error", code, message, details: { requestID: id } }, 10);
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "a" }, 10);
        error("b", ACTION_HANDLER_ERROR, messages.failed);
        error("c", ACTION_HANDLER_ERROR, messages.timedOut);
        // JSON-encoded error frames nest the payload.
        session.handleDecodedMessage(
            { kind: "error", payload: { error: { code: ACTION_HANDLER_ERROR, message: messages.serviceDeadline, details: { requestID: "d" } } } },
            10
        );
        // A real error stays an error, and is still an answer.
        error("e", "ACTION_INVALID_PAYLOAD", "bad payload");
        // Answers to requests no longer pending: a second answer, an unknown request.
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "a" }, 11);
        error("zz", ACTION_HANDLER_ERROR, messages.failed);
        expect(session.metrics.actionOutcomes).toEqual({ ...zero, applied: 1, failed: 2, timedOut: 1, errored: 1, unmatched: 2 });
        // The real error and the unmatched injected-looking one.
        expect(session.metrics.errorCount).toBe(2);
        expect(session.metrics.rttMs).toHaveLength(5);
        // Only the applied answer's RTT is an applied RTT.
        expect(session.metrics.appliedRttMs).toEqual([10]);
        expect(session.takePending()).toEqual([]);
    });

    it("gives a request a phase end left unanswered its outcome when its answer comes later", () => {
        const session = new WorkerSession();
        const records: unknown[] = [];
        session.attachSamples((r) => records.push(r), "k1", "p1");
        session.recordSend("late-ok", 0);
        session.recordSend("late-fail", 0);
        expect(session.takePending()).toHaveLength(2);
        session.resetMetrics();
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "late-ok" }, 7000);
        session.handleDecodedMessage({ kind: "error", code: ACTION_HANDLER_ERROR, message: messages.failed, details: { requestID: "late-fail" } }, 7000);
        // A second answer to a forgotten request is no longer its first.
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "late-ok" }, 7001);
        expect(session.metrics.actionOutcomes).toEqual({ ...zero, applied: 1, failed: 1, answeredAfterPhaseEnd: 2, unmatched: 1 });
        expect(session.metrics.errorCount).toBe(0);
        expect(session.metrics.rttMs).toEqual([]);
        // The samples give each late first answer its outcome; the second answer adds nothing.
        expect(records.filter((r) => (r as { r: string }).r === "late")).toEqual([
            { r: "late", k: "k1", respondedAt: 7000, outcome: "applied" },
            { r: "late", k: "k1", respondedAt: 7000, outcome: "failed" }
        ]);
    });

    it("tells an injected join failure by its pinned JOIN_DENIED message", () => {
        expect(isInjectedJoinFailure("JOIN_DENIED", messages.joinFailed)).toBe(true);
        expect(isInjectedJoinFailure("JOIN_DENIED", messages.joinFailed.replace("index: 0", "index: 41"))).toBe(true);
        expect(isInjectedJoinFailure("JOIN_DENIED", "Join failed")).toBe(false);
        expect(isInjectedJoinFailure("JOIN_FULL", messages.joinFailed)).toBe(false);
        expect(isInjectedJoinFailure("JOIN_DENIED", messages.joinFailed.replace("JoinCheckResolver", "OtherResolver"))).toBe(false);
        const summary = summarizeJoinFailures(
            [{ joinFailures: [
                { t: 1, reason: "error", code: "JOIN_DENIED", message: messages.joinFailed },
                { t: 2, reason: "error", code: "JOIN_DENIED", message: "Join failed" },
                { t: 3, reason: "timeout" }
            ] }],
            0,
            10
        );
        expect(summary.joinFailures).toEqual({ phase: 3, measured: 3, byReason: { error: 2, timeout: 1 }, injected: 1 });
    });

    it("sums per connection, skipping reports without counts", () => {
        const one = { ...zero, applied: 1, failed: 2, timedOut: 3, abandonedLimitRejected: 4, errored: 2, answeredAfterPhaseEnd: 1 };
        // A report from before the caps' outcomes has neither key.
        const old = { applied: 4, failed: 0, timedOut: 0, errored: 0, answeredAfterPhaseEnd: 0, unmatched: 1 } as unknown as typeof zero;
        expect(sumActionOutcomes([one, undefined, old])).toEqual({ ...zero, applied: 5, failed: 2, timedOut: 3, abandonedLimitRejected: 4, errored: 2, answeredAfterPhaseEnd: 1, unmatched: 1 });
    });
});
