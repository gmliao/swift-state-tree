import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { ACTION_HANDLER_ERROR, injectedFailure, isInjectedJoinFailure, sumActionOutcomes } from "../src/action-outcomes";
import { summarizeJoinFailures } from "../src/run";
import { WorkerSession } from "../src/worker";

// The server's messages for resolver-test's failures; GameContentTests checks the server still
// produces them (ResolverTestLandTests, "Failed actions' error messages ...").
const messages = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/resolver-failure-messages.json"), "utf8"));

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
        expect(session.metrics.actionOutcomes).toEqual({ applied: 1, failed: 2, timedOut: 1, errored: 1, answeredAfterPhaseEnd: 0, unmatched: 2 });
        // The real error and the unmatched injected-looking one.
        expect(session.metrics.errorCount).toBe(2);
        expect(session.metrics.rttMs).toHaveLength(5);
        // Only the applied answer's RTT is an applied RTT.
        expect(session.metrics.appliedRttMs).toEqual([10]);
        expect(session.takePending()).toEqual([]);
    });

    it("gives a request a phase end left unanswered its outcome when its answer comes later", () => {
        const session = new WorkerSession();
        session.recordSend("late-ok", 0);
        session.recordSend("late-fail", 0);
        expect(session.takePending()).toHaveLength(2);
        session.resetMetrics();
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "late-ok" }, 7000);
        session.handleDecodedMessage({ kind: "error", code: ACTION_HANDLER_ERROR, message: messages.failed, details: { requestID: "late-fail" } }, 7000);
        // A second answer to a forgotten request is no longer its first.
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "late-ok" }, 7001);
        expect(session.metrics.actionOutcomes).toEqual({ applied: 1, failed: 1, timedOut: 0, errored: 0, answeredAfterPhaseEnd: 2, unmatched: 1 });
        expect(session.metrics.errorCount).toBe(0);
        expect(session.metrics.rttMs).toEqual([]);
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
        const one = { applied: 1, failed: 2, timedOut: 3, errored: 2, answeredAfterPhaseEnd: 1, unmatched: 0 };
        const two = { applied: 4, failed: 0, timedOut: 0, errored: 0, answeredAfterPhaseEnd: 0, unmatched: 1 };
        expect(sumActionOutcomes([one, undefined, two])).toEqual({ applied: 5, failed: 2, timedOut: 3, errored: 2, answeredAfterPhaseEnd: 1, unmatched: 1 });
    });
});
