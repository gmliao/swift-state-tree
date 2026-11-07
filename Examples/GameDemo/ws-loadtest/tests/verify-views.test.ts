import { describe, expect, it } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { loadSdkCore } from "../src/reconstruction";
import { reaches, sdkEncoding, verifyCapture } from "../src/verify-views";

// The reconstruction-equals-projection gate over captures from `EncodingBenchmark --capture-views`
// (hero-defense, 5 players, the joins and warm-up, then 5 syncs of one room; `tests/fixtures/view-capture-*`),
// as they are and with one thing broken: a projection, a lost frame, a frame to the wrong
// recipient. Each break must fail the gate. In hero-defense every player's projection is the
// same (no per-player fields), so a projection taken for the wrong player can't be told apart.

const fixtures = ["messagepack-pathhash-delta", "json-object-full-snapshot", "entity-delta"];

/** A capture directory with one run holding the fixture's room, after `edit` on its lines. */
function capture(name: string, edit: (lines: any[]) => void = () => {}): string {
    const text = zlib.gunzipSync(fs.readFileSync(path.join(__dirname, "fixtures", `view-capture-${name}.ndjson.gz`))).toString("utf8");
    const lines = text.split("\n").filter((l) => l).map((l) => JSON.parse(l));
    edit(lines);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "views-"));
    fs.mkdirSync(path.join(dir, name));
    fs.writeFileSync(path.join(dir, name, "room-0.ndjson"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return dir;
}

const quiet = <T>(f: () => T): T => {
    const log = console.log;
    console.log = () => {};
    try {
        return f();
    } finally {
        console.log = log;
    }
};

describe("verify-views", () => {
    for (const name of fixtures) {
        it(`${name}: every recipient's rebuilt state equals its projection after every sync`, async () => {
            const sdk = await loadSdkCore();
            const report = quiet(() => verifyCapture(sdk, capture(name)));
            expect(report.passed).toBe(true);
            expect(report.totals).toMatchObject({ rooms: 1, syncs: 6, comparisons: 30, differences: 0, decodeErrors: 0 });
        });

        it(`${name}: a projection that differs fails at its sync`, async () => {
            const sdk = await loadSdkCore();
            const report = quiet(() =>
                verifyCapture(sdk, capture(name, (lines) => {
                    const projections = lines[4].projections;
                    const player = Object.keys(projections)[2];
                    projections[player] = { ...projections[player], score: 987654 };
                }))
            );
            expect(report.passed).toBe(false);
            const room = Object.values(report.runs)[0][0];
            expect(room.differences.map((d) => [d.sync, d.player])).toEqual([[3, "room0-player-2"]]);
            expect(room.differences[0].paths[0].path).toBe("/score");
        });

        it(`${name}: a lost frame fails`, async () => {
            const sdk = await loadSdkCore();
            // Drop the third sync's frame to one session; that session's view lags from there.
            const report = quiet(() => verifyCapture(sdk, capture(name, (lines) => lines[3].frames.splice(1, 1))));
            expect(report.passed).toBe(false);
            expect(report.totals.differences).toBeGreaterThan(0);
        });

        it(`${name}: a frame delivered to the wrong session fails`, async () => {
            const sdk = await loadSdkCore();
            const report = quiet(() =>
                verifyCapture(sdk, capture(name, (lines) => {
                    const frame = lines[3].frames[1];
                    frame.to = lines[3].frames[0].to;
                }))
            );
            expect(report.passed).toBe(false);
        });
    }

    it("fails an empty capture", async () => {
        const sdk = await loadSdkCore();
        const report = verifyCapture(sdk, fs.mkdtempSync(path.join(os.tmpdir(), "views-")));
        expect(report).toMatchObject({ passed: false, totals: { rooms: 0 } });
    });

    it("routes frames by target and maps the Swift encodings", () => {
        expect(reaches("*", "s1", "p1")).toBe(true);
        expect([reaches("s:s1", "s1", "p1"), reaches("s:s2", "s1", "p1")]).toEqual([true, false]);
        expect([reaches("p:p1", "s1", "p1"), reaches("p:p2", "s1", "p1")]).toEqual([true, false]);
        expect([reaches("!s1", "s1", "p1"), reaches("!s2", "s1", "p1")]).toEqual([false, true]);
        expect(() => reaches("?x", "s1", "p1")).toThrow(/unknown frame target/);
        expect(sdkEncoding("messagepack", "opcodeMessagePack").stateUpdate).toBe("opcodeJsonArray");
        expect(sdkEncoding("json", "opcodeJsonArrayLegacy").stateUpdate).toBe("opcodeJsonArray");
        expect(sdkEncoding("json", "jsonObject").stateUpdate).toBe("jsonObject");
        expect(() => sdkEncoding("json", "binary")).toThrow(/unknown state update/);
    });
});
