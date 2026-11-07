import { describe, expect, it } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { COLYSEUS_FORMAT, convertCapture, FieldRanges, observeProjection, TYPINGS } from "../src/colyseus-baseline";
import { loadSdkCore } from "../src/reconstruction";
import { captureStreams, summarize, timeStream } from "../src/time-decode";
import { verifyCapture } from "../src/verify-views";

// The @colyseus/schema baseline over a hand-built capture: the optional fields' transitions
// (nil, present at zero, present, nil again), a turret whose string owner comes and goes, an
// entity removed, then the gate and the decode timer over the converted capture.

const base = (health: number) => ({ health, maxHealth: 100, position: { v: { x: 64000, y: 36000 } }, radius: 3 });
const player = (x: number, target: [number, number] | null, resources = 0) => ({
    health: 120, maxHealth: 120, position: { v: { x, y: 36239 } }, resources, rotation: { degrees: -90 },
    targetPosition: target === null ? null : { v: { x: target[0], y: target[1] } }, weaponLevel: 1
});
const monster = (id: number, x: number) => ({ health: 10, id, maxHealth: 10, position: { v: { x, y: 100 } }, rotation: { degrees: 45 } });
const turret = (owner: string | null) => ({ id: 1, level: 0, ownerID: owner, position: { v: { x: 5000, y: 6000 } }, rotation: { degrees: 0 } });

/** One projection per checkpoint; every player sees the same one. */
const SEQUENCE = [
    { base: base(100), monsters: { "1": monster(1, 0), "2": monster(2, 200) }, players: { a: player(128000, null) }, score: 0, turrets: {} },
    { base: base(100), monsters: { "1": monster(1, 10), "2": monster(2, 210) }, players: { a: player(127000, [0, 0]) }, score: 0, turrets: { "1": turret(null) } },
    { base: base(90), monsters: { "2": monster(2, 220) }, players: { a: player(126000, [5, 7], 3) }, score: 5, turrets: { "1": turret("room0-player-1") } },
    { base: base(90), monsters: { "2": monster(2, 230) }, players: { a: player(126000, null, 3) }, score: 5, turrets: { "1": turret(null) } },
    { base: base(80), monsters: {}, players: { a: player(125000, [0, 0], 3) }, score: 9, turrets: {} }
];

function capture(sequence: object[], edit: (lines: any[]) => void = () => {}): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "colyseus-src-"));
    const run = path.join(dir, "messagepack-pathhash-delta-r1-p2-m0-serial");
    fs.mkdirSync(run);
    const header = {
        landID: "hero-defense:room0", format: "messagepack-pathhash", message: "messagepack", stateUpdate: "opcodeMessagePack",
        syncStrategy: "delta", sessions: { "room0-session-0": "room0-player-0", "room0-session-1": "room0-player-1" }, schema: {}
    };
    const lines: any[] = [header, ...sequence.map((p, sync) => ({ sync, frames: [], projections: { "room0-player-0": p, "room0-player-1": p } }))];
    edit(lines);
    fs.writeFileSync(path.join(run, "room-0.ndjson"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
    return dir;
}

const out = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), "colyseus-out-")), "capture");

const quiet = <T>(f: () => T): T => {
    const log = console.log;
    console.log = () => {};
    try {
        return f();
    } finally {
        console.log = log;
    }
};

describe("colyseus-baseline", () => {
    for (const typing of TYPINGS) {
        it(`${typing}: every recipient's decoded state equals its projection after every sync`, async () => {
            const sdk = await loadSdkCore();
            const dir = out();
            const report = convertCapture(capture(SEQUENCE), dir, typing);
            expect(report.version).toBe("5.0.42");
            const result = quiet(() => verifyCapture(sdk, dir));
            expect(result.totals).toMatchObject({ rooms: 1, syncs: 5, comparisons: 10, differences: 0, decodeErrors: 0 });
            expect(result.passed).toBe(true);
            const header = JSON.parse(fs.readFileSync(path.join(dir, Object.keys(report.runs)[0], "room-0.ndjson"), "utf8").split("\n")[0]);
            expect(header).toMatchObject({ format: COLYSEUS_FORMAT, colyseus: { package: "@colyseus/schema", version: "5.0.42", typing } });
        });
    }

    it("addresses each frame to every session and counts the join state apart", () => {
        const dir = out();
        const report = convertCapture(capture(SEQUENCE), dir, "number");
        const run = Object.values(report.runs)[0];
        const lines = fs.readFileSync(path.join(dir, Object.keys(report.runs)[0], "room-0.ndjson"), "utf8").trim().split("\n").slice(1).map((l) => JSON.parse(l));
        expect(lines.every((l) => l.frames.every((f: any) => f.to === "*"))).toBe(true);
        expect(run.firstSyncBytes).toBe(2 * Buffer.from(lines[0].frames[0].data, "base64").length);
        expect(run.syncs).toBe(4);
    });

    it("refuses a sync where two players' projections differ", () => {
        const src = capture(SEQUENCE, (lines) => {
            lines[3].projections["room0-player-1"] = { ...SEQUENCE[2], score: 6 };
        });
        expect(() => convertCapture(src, out(), "number")).toThrow(/projections differ/);
    });

    it("tunes each field to the narrowest fixed type its values fit", () => {
        const ranges = new FieldRanges();
        for (const p of SEQUENCE) observeProjection(ranges, p);
        observeProjection(ranges, { ...SEQUENCE[0], base: { ...base(100), radius: 3.5 } });
        const types = ranges.tuned();
        expect(types.Player).toMatchObject({ x: "uint32", y: "uint16", rotation: "int8", targetX: "uint8", health: "uint8", resources: "uint8" });
        expect(types.Base.radius).toBe("float32");
        expect(types.Turret.ownerID).toBe("string");
        // A field no value reached keeps Colyseus's default.
        const empty = new FieldRanges().tuned();
        expect(empty.Monster.x).toBe("number");
    });

    it("times Decoder.decode alone: decode-and-apply only", async () => {
        const sdk = await loadSdkCore();
        const dir = out();
        const report = convertCapture(capture(SEQUENCE), dir, "tuned");
        const streams = captureStreams(path.join(dir, Object.keys(report.runs)[0], "room-0.ndjson"));
        expect(streams.map((s) => s.decoder)).toEqual(["colyseus-schema", "colyseus-schema"]);
        let t = 0n;
        const timing = timeStream(sdk, streams[0], { passes: 2, warmup: 1, now: () => (t += 1000n) });
        expect(timing.decodeApplyUsPerPass).toEqual([1, 1]);
        expect(summarize([timing], { passes: 2, warmup: 1 }).decode).toBeNull();
    });
});
