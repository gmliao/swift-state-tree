import { describe, it, expect } from "vitest";
import { parseSendWindows, serverSendByPhase, summarizeServerSend } from "../src/server-send";
import { serverSendSection } from "../src/report/render-html";

/** A window line taken at `ts` seconds, with the send counters. */
const at = (ts: number, bytes: number, episodes: number, longestMs: number, unwritable: number, closes?: number) =>
    JSON.stringify({
        ts: ts * 1000,
        lag_ms: 0,
        counters: {
            actions: 0,
            sendBufferedBytesMax: bytes,
            sendUnwritableEpisodes: episodes,
            sendUnwritableLongestMs: longestMs,
            sendUnwritableSessions: unwritable,
            ...(closes === undefined ? {} : { sendBacklogCloses: closes })
        }
    });

describe("summarizeServerSend", () => {
    it("takes the max of bytes, longest and gauge, and sums episodes, over windows wholly inside", () => {
        // Windows (10,11] (11,12] (12,13] (13,14]; the span [11, 13.5] holds (11,12] and (12,13].
        const raw = [
            at(10, 0, 0, 0, 0),
            at(11, 999_999, 9, 9999, 9),
            at(12, 70_000, 2, 120, 1),
            at(13, 4_000, 1, 300, 0),
            at(14, 999_999, 9, 9999, 9)
        ].join("\n");
        const summary = summarizeServerSend(parseSendWindows(raw), 11_000, 13_500);
        expect(summary).toEqual({
            windows: 2,
            coveredStartAt: 11_000,
            coveredEndAt: 13_000,
            bufferedBytesMax: 70_000,
            unwritableEpisodes: 3,
            unwritableLongestMs: 300,
            unwritableSessionsMax: 1,
            backlogCloses: null
        });
    });

    it("sums sendBacklogCloses when every window inside has it, and is null otherwise", () => {
        const all = [at(10, 0, 0, 0, 0, 0), at(11, 0, 0, 0, 0, 2), at(12, 0, 0, 0, 0, 1), at(13, 0, 0, 0, 0, 7)].join("\n");
        expect(summarizeServerSend(parseSendWindows(all), 10_000, 12_500)?.backlogCloses).toBe(3);
        // A window without the field (a server before the bound) can't be counted as 0: the gate is 0.
        const mixed = [at(10, 0, 0, 0, 0), at(11, 0, 0, 0, 0), at(12, 0, 0, 0, 0, 0)].join("\n");
        expect(summarizeServerSend(parseSendWindows(mixed), 10_000, 12_000)?.backlogCloses).toBeNull();
        const phases = serverSendByPhase(all, [{ phase: "steady", startAt: 10_000, endAt: 12_500 }]);
        expect(serverSendSection(phases)).toContain("<td class=\"px-4 py-1 text-slate-300\">3</td>");
        expect(serverSendSection(serverSendByPhase(mixed, [{ phase: "p", startAt: 10_000, endAt: 12_000 }]))).toContain("n/a</td>");
    });

    it("is n/a for a profile without the send counters (an older server)", () => {
        const old = [1, 2, 3].map((s) => JSON.stringify({ ts: s * 1000, counters: { syncCycles: 1 } })).join("\n");
        expect(serverSendByPhase(old, [{ phase: "p", startAt: 0, endAt: 10_000 }])).toBeNull();
        expect(serverSendByPhase(undefined, [])).toBeNull();
        expect(serverSendSection(null)).toContain("n/a");
    });

    it("renders a phase without a window inside as n/a", () => {
        const raw = [at(1, 0, 0, 0, 0), at(2, 10, 0, 0, 0)].join("\n");
        const phases = serverSendByPhase(raw, [{ phase: "late", startAt: 5_000, endAt: 6_000 }]);
        expect(phases).toEqual([{ phase: "late", summary: null }]);
        expect(serverSendSection(phases)).toContain("n/a (no profile window inside the measured window)");
    });
});
