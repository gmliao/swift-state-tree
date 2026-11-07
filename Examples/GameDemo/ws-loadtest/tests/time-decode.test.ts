import { describe, expect, it } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { loadSdkCore, type SdkCore } from "../src/reconstruction";
import { captureStreams, frameSizes, recordingStreams, summarize, timeStream } from "../src/time-decode";

// The decode timer over a `--capture-views` room (tests/fixtures/view-capture-*: 5 players, the
// joins and warm-up, then 5 syncs) and over a GameServer recording (hero-defense-frames-*).

const fixtures = path.join(__dirname, "fixtures");

function captureFile(name: string, edit: (lines: any[]) => void = () => {}): string {
    const text = zlib.gunzipSync(fs.readFileSync(path.join(fixtures, `view-capture-${name}.ndjson.gz`))).toString("utf8");
    const lines = text.split("\n").filter((l) => l).map((l) => JSON.parse(l));
    edit(lines);
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "decode-")), "room-0.ndjson");
    fs.writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return file;
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

/** A clock that advances 1 µs per read: each timed span is then 1 µs, whatever it does. */
const tickingClock = () => {
    let t = 0n;
    return () => (t += 1000n);
};

describe("time-decode", () => {
    it("splits a capture into each recipient's stream, in order", () => {
        const file = captureFile("messagepack-pathhash-delta");
        const streams = captureStreams(file);
        const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l).map((l) => JSON.parse(l));
        expect(streams.map((s) => s.playerID).sort()).toEqual(Object.values(lines[0].sessions).sort());
        for (const s of streams) {
            const session = s.name.split("#")[1];
            const expected = lines.slice(1).flatMap((l: any) => l.frames.filter((f: any) => f.to === "*" || f.to === `s:${session}` || f.to === `p:${s.playerID}`));
            expect(s.frames.length).toBe(expected.length);
            expect(s.syncs).toBe(6);
            expect(s.frames[0]).toBeInstanceOf(Uint8Array);
        }
        expect(captureStreams(captureFile("json-object-full-snapshot"))[0].frames[0]).toBeTypeOf("string");
    });

    it("excludes the warm-up passes and takes the median pass", async () => {
        const sdk = await loadSdkCore();
        const stream = captureStreams(captureFile("messagepack-pathhash-delta"))[0];
        const timing = quiet(() => timeStream(sdk, stream, { passes: 5, warmup: 2, now: tickingClock() }));
        expect(timing.decodeUsPerPass).toEqual([1, 1, 1, 1, 1]);
        expect(timing.decodeApplyUsPerPass).toHaveLength(5);
        const summary = summarize([timing, timing], { passes: 5, warmup: 2 });
        expect(summary).toMatchObject({ streams: 2, frames: 2 * stream.frames.length, syncs: 12, passes: 5, warmup: 2 });
        expect(summary.decode.usPerFrame).toBeCloseTo(2 / (2 * stream.frames.length));
        expect(summary.decode.usPerSync).toBeCloseTo(2 / 12);
    });

    it("starts every pass from fresh key tables and decodes every frame", async () => {
        const sdk = await loadSdkCore();
        const tables = new Set<unknown>();
        let calls = 0;
        const spy: SdkCore = { ...sdk, decodeMessage: (data, config, keyMaps) => { tables.add(keyMaps); calls += 1; return sdk.decodeMessage(data, config, keyMaps); } };
        const stream = captureStreams(captureFile("messagepack-pathhash-delta"))[0];
        quiet(() => timeStream(spy, stream, { passes: 3, warmup: 1 }));
        // Both figures decode through the spy: per pass, the decode-alone loop and the
        // reconstruction each decode every frame, each with key tables of its own.
        expect(calls).toBe(2 * 4 * stream.frames.length);
        expect(tables.size).toBe(2 * 4);
    });

    it("fails on a frame the SDK can't decode", async () => {
        const sdk = await loadSdkCore();
        const file = captureFile("messagepack-pathhash-delta", (lines) => {
            lines[2].frames[0].data = Buffer.from([0xc1, 0xc1, 0xc1]).toString("base64");
        });
        const stream = captureStreams(file).find((s) => s.name.endsWith(`#${JSON.parse(fs.readFileSync(file, "utf8").split("\n")[2]).frames[0].to.slice(2)}`))!;
        expect(() => quiet(() => timeStream(sdk, stream, { passes: 1, warmup: 0 }))).toThrow(/failed to decode/);
    });

    it("times a GameServer recording from after each join response, with its encoding", async () => {
        const sdk = await loadSdkCore();
        const file = path.join(fixtures, "hero-defense-frames-messagepack.json.gz");
        const recording = JSON.parse(zlib.gunzipSync(fs.readFileSync(file)).toString("utf8"));
        const streams = quiet(() => recordingStreams(sdk, file));
        expect(streams.map((s) => s.playerID)).toEqual(recording.connections.map((c: any) => c.name));
        for (const [i, s] of streams.entries()) {
            expect(s.encoding.message).toBe("messagepack");
            expect(s.frames.length).toBe(recording.connections[i].frames.length - 1);
        }
        const timing = quiet(() => timeStream(sdk, streams[0], { passes: 2, warmup: 1 }));
        expect(timing.decodeUsPerPass).toHaveLength(2);
    });

    it("reports the frame-size distribution", () => {
        const sizes = frameSizes([{ frames: [new Uint8Array(1), "abc", new Uint8Array(10), "xy"] } as any]);
        expect(sizes).toEqual({ frames: 4, min: 1, median: 2, p95: 3, max: 10, mean: 4 });
    });
});
