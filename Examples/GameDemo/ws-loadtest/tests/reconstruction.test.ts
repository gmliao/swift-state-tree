import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { StateTreeRuntime } from "@swiftstatetree/sdk/core";
import { ConnectionReconstruction, loadSdkCore } from "../src/reconstruction";
import { DynamicKeyTracker, classifyDecoded, decodeRaw } from "../src/protocol";

// Differential test of the per-connection reconstruction: recorded GameServer frames go through
// three consumers, and they must agree.
// - the SDK's own client path (`StateTreeRuntime.handleMessage`, as its Node socket hands it
//   frames: an ArrayBuffer per frame) with one view: the reference state and decode errors;
// - `ConnectionReconstruction`, fed the frames as the load client receives them (Buffers);
// - the load client's own decode (`decodeRaw`, `classifyDecoded`, `DynamicKeyTracker`): its
//   frame classes and decode error count, which the metrics use.
// The fixtures come from `scripts/record-frames.mjs`, one per server `TRANSPORT_ENCODING`,
// recorded after #271; #278 didn't change GameDemo's schema.
// Two changes this test doesn't catch are equivalent for the state only under the tool's setup:
// dropping an opcode-107 frame's events (no event handlers are registered, and events don't
// change the state), and ignoring the join response's decoding switch (decoding stays `auto`,
// which tries both state-update formats). With event handlers or a fixed decoding they'd matter.

interface Fixture {
    land: string;
    schema: unknown;
    connections: Array<{ name: string; encoding: string; frames: Array<{ binary: boolean; data: string }> }>;
}

const fixtureDir = path.join(__dirname, "fixtures");
const fixtures = fs.existsSync(fixtureDir) ? fs.readdirSync(fixtureDir).filter((f) => /^hero-defense-frames-.*\.json\.gz$/.test(f)) : [];

function load(file: string): Fixture {
    return JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(fixtureDir, file))).toString("utf8"));
}

function toArrayBuffer(bytes: Buffer): ArrayBuffer {
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/** A decoded frame's class, comparable across the two decoders. */
function sdkClass(decoded: any): string {
    if ("kind" in decoded) return `kind:${decoded.kind}`;
    if (decoded.type === "stateUpdateWithEvents") return "stateUpdateWithEvents";
    if ("patches" in decoded) return "stateUpdate";
    if ("values" in decoded) return "snapshot";
    return "unknown";
}

function toolClass(decoded: any): string {
    if (decoded && typeof decoded === "object" && "kind" in decoded) return `kind:${decoded.kind}`;
    if (decoded?.type === "stateUpdateWithEvents") return "stateUpdateWithEvents";
    if (decoded?.type === "stateUpdate") return "stateUpdate";
    return "unknown";
}

describe("reconstruction (differential, recorded frames)", () => {
    it("has a fixture per server encoding", () => {
        expect(fixtures.sort()).toEqual([
            "hero-defense-frames-json.json.gz",
            "hero-defense-frames-jsonOpcode.json.gz",
            "hero-defense-frames-messagepack.json.gz",
            // Recorded with ROW_ADDRESSING=true: the opcode encodings carry row entries.
            "hero-defense-frames-rows-jsonOpcode.json.gz",
            "hero-defense-frames-rows-messagepack.json.gz"
        ]);
    });

    for (const file of fixtures) {
        it(`${file}: the reconstruction matches the SDK client, and the decoders agree`, async () => {
            const fixture = load(file);
            const sdk = await loadSdkCore();
            const landID = `hero-defense:${fixture.land}`;
            for (const connection of fixture.connections) {
                const runtime = new StateTreeRuntime();
                const reference = runtime.createView(landID, { schema: fixture.schema as any });
                const reconstruction = new ConnectionReconstruction(sdk, fixture.schema, landID);
                const tracker = new DynamicKeyTracker();
                const toolClasses: string[] = [];
                const sdkClasses: string[] = [];
                const sdkKeyMaps = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>(), rowTables: new sdk.RowTables() };
                let sdkEncoding: any = { message: "json", stateUpdate: "opcodeJsonArray", stateUpdateDecoding: "auto" };
                for (const frame of connection.frames) {
                    const bytes = Buffer.from(frame.data, "base64");
                    await (runtime as any).handleMessage(toArrayBuffer(bytes));
                    reconstruction.feed(bytes);
                    const raw = decodeRaw(bytes);
                    tracker.observe(raw);
                    toolClasses.push(toolClass(classifyDecoded(raw)));
                    const decoded = sdk.decodeMessage(bytes, sdkEncoding, sdkKeyMaps);
                    sdkClasses.push(sdkClass(decoded));
                    if (decoded.kind === "joinResponse") {
                        const encoding = decoded.payload?.joinResponse?.encoding ?? decoded.payload?.encoding;
                        if (encoding) sdkEncoding = { ...sdkEncoding, message: encoding, stateUpdate: encoding === "json" ? "jsonObject" : "opcodeJsonArray" };
                        // The features the server's frames use, with the land's path index table (as the SDK view sets them).
                        const features = decoded.payload?.joinResponse?.stateUpdateFeatures ?? [];
                        const pathHashes = (fixture.schema as any).lands["hero-defense"].pathHashes;
                        const pathPatterns = new Map(Object.entries(pathHashes as Record<string, number>).map(([pattern, hash]) => [hash, pattern]));
                        sdkEncoding = { ...sdkEncoding, stateUpdateFeatures: features, pathIndexTable: (sdk as any).pathIndexTableFor(pathHashes), pathPatterns };
                        // As the runtime and the worker: the row tables start again, the tracker learns the feature.
                        sdkKeyMaps.rowTables.clear();
                        tracker.rowAddressing = features.includes("rowAddressing");
                    }
                }
                const label = `${file} ${connection.name}`;
                // Non-trivial: a joined connection with a state and many state frames.
                expect(sdkClasses.filter((c) => c.startsWith("state")).length, label).toBeGreaterThan(20);
                expect(Object.keys(reference.getState()).length, label).toBeGreaterThan(0);
                expect(sdk.compareStates(reconstruction.view.getState(), reference.getState()), label).toEqual([]);
                expect(reconstruction.decodeErrors, label).toBe(runtime.decodeErrorStats().beforeLeave);
                expect(reconstruction.decodeErrors, label).toBe(0);
                expect(tracker.errors, label).toBe(0);
                expect(toolClasses, label).toEqual(sdkClasses);
                expect(reconstruction.lastFrameAt, label).toBeDefined();
                // A rows fixture is decoded with its row entries; the others carry none.
                const rows = file.includes("-rows-");
                expect(tracker.rowEntries > 0, label).toBe(rows);
                expect(reconstruction.rowPatchesApplied > 0, label).toBe(rows);
                expect(reconstruction.rowEntryViolation, label).toBeUndefined();
            }
        });
    }
});

describe("reconstruction (synthetic)", () => {
    const schema = {
        version: "1.0.0",
        lands: { "test-land": { stateType: "TestState" } },
        defs: { TestState: { type: "object", properties: { round: { type: "integer" } } } }
    };

    it("applies a jsonObject state update and records the frame time", async () => {
        const sdk = await loadSdkCore();
        const reconstruction = new ConnectionReconstruction(sdk, schema, "test-land:1", { now: () => 1234 });
        reconstruction.feed(JSON.stringify({ type: "firstSync", patches: [{ path: "/round", op: "replace", value: 3 }] }));
        expect(reconstruction.view.getState()).toEqual({ round: 3 });
        expect(reconstruction.normalizedState()).toEqual({ round: 3 });
        expect(reconstruction.lastFrameAt).toBe(1234);
    });

    it("skips the state patches of a later frame at a resync's sequence (#332), as the SDK runtime does", async () => {
        const sdk = await loadSdkCore();
        const reconstruction = new ConnectionReconstruction(sdk, schema, "test-land:1", {
            encoding: { message: "opcodeJsonArray", stateUpdate: "opcodeJsonArray", stateUpdateFeatures: ["syncSequence"] } as any
        });
        reconstruction.feed(JSON.stringify([1, 5, ["/round", 1, 1]]));
        reconstruction.feed(JSON.stringify([3, 9, ["/round", 1, 4]]));
        // The merged broadcast frame after the snapshot, at the same sequence: its patch is stale.
        reconstruction.feed(JSON.stringify([107, [1, 9, ["/round", 1, 2]], []]));
        expect(reconstruction.view.getState()).toEqual({ round: 4 });
        reconstruction.feed(JSON.stringify([2, 10, ["/round", 1, 5]]));
        expect(reconstruction.view.getState()).toEqual({ round: 5 });
        expect(reconstruction.decodeErrors).toBe(0);
    });

    it("counts a frame with an undefined dynamic key slot, as the SDK client and the tool's tracker do", async () => {
        const sdk = await loadSdkCore();
        // A per-player diff whose dynamic key is a bare slot nobody defined (SDK runtime-decode-errors test).
        const frame = JSON.stringify([2, [123456, 0, 1, 1]]);
        const reconstruction = new ConnectionReconstruction(sdk, schema, "test-land:1");
        reconstruction.feed(frame);
        reconstruction.feed("not a frame");
        const tracker = new DynamicKeyTracker();
        tracker.observe(decodeRaw(frame));
        expect(reconstruction.decodeErrors).toBe(2);
        expect(reconstruction.firstError).toMatch(/used before definition/);
        expect(tracker.errors).toBe(1);
    });
});
