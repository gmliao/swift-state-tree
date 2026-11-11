import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { ConnectionReconstruction, loadSdkCore, type TransportEncodingConfig } from "../src/reconstruction";
import { DynamicKeyTracker, decodeRaw, truncatedCloseReason } from "../src/protocol";
import { WorkerClient, type WebSocketLike } from "../src/worker";

// Row entries (`rowAddressing`, ops 6 to 9) in the load client: the key tracker, the
// reconstruction (the SDK's decoder, row tables and resync skip) and the worker's 4013 close.
// Frames from the Swift fixture the SDK's own row entry tests read: each row frame and its plain
// twin, encoded by Swift with the feature on and off.

interface FixtureFrame {
    name: string;
    jsonFrame: string;
    messagePackFrame: string;
    plainJsonFrame: string;
    plainMessagePackFrame: string;
}

const fixture: { pathHashes: Record<string, number>; frames: FixtureFrame[] } = JSON.parse(
    fs.readFileSync(
        path.join(__dirname, "../../../../Tests/SwiftStateTreeTransportTests/Fixtures/RowAddressing/row-addressing-frames.json"),
        "utf8"
    )
);

const LAND = "rows";
const schema = {
    lands: { [LAND]: { stateType: "RowState", pathHashes: fixture.pathHashes } },
    defs: { RowState: { type: "object", properties: {} } }
};
// The fixture's frames carry no sync sequence, so `syncSequence` isn't negotiated here.
const rowFeatures = ["pathIndex", "fieldMerge", "rowAddressing"];
const plainFeatures = ["pathIndex", "fieldMerge"];

function joinResponse(features: string[]): string {
    return JSON.stringify({
        kind: "joinResponse",
        payload: { joinResponse: { requestID: "join-1", success: true, playerID: "p1", encoding: "json", stateUpdateFeatures: features } }
    });
}

async function reconstruction(features: string[], onRowEntryViolation?: (rule: string) => void) {
    const sdk = await loadSdkCore();
    const encoding: TransportEncodingConfig = { message: "json", stateUpdate: "opcodeJsonArray", stateUpdateDecoding: "opcodeJsonArray" };
    const view = new ConnectionReconstruction(sdk, schema, `${LAND}:room-1`, { playerID: "p1", encoding, onRowEntryViolation });
    view.feed(joinResponse(features));
    return view;
}

const messagePack = (base64: string) => new Uint8Array(Buffer.from(base64, "base64"));

describe("the key tracker with row entries", () => {
    it("counts row entries where the feature was negotiated, without reading their slots as keys", () => {
        const tracker = new DynamicKeyTracker();
        tracker.rowAddressing = true;
        for (const frame of fixture.frames) tracker.observe(decodeRaw(frame.jsonFrame));
        expect(tracker.errors).toBe(0);
        expect(tracker.rowViolation).toBeUndefined();
        expect(tracker.rowEntries).toBeGreaterThan(fixture.frames.length);
    });

    it("refuses a row entry without the feature, as the SDK does, and the plain frames stay clean", () => {
        const plain = new DynamicKeyTracker();
        for (const frame of fixture.frames) plain.observe(decodeRaw(frame.plainJsonFrame));
        expect(plain.errors).toBe(0);
        expect(plain.rowEntries).toBe(0);

        const tracker = new DynamicKeyTracker();
        tracker.observe(decodeRaw(fixture.frames[0].jsonFrame));
        expect(tracker.errors).toBe(1);
        expect(tracker.rowViolation).toBe("op 6 without rowAddressing negotiated");
        expect(tracker.rowEntries).toBe(0);
    });
});

describe("the reconstruction with row entries", () => {
    for (const encoding of ["json", "messagepack"] as const) {
        it(`reaches the plain frames' state after every frame (${encoding})`, async () => {
            const rows = await reconstruction(rowFeatures);
            const plain = await reconstruction(plainFeatures);
            for (const frame of fixture.frames) {
                rows.feed(encoding === "json" ? frame.jsonFrame : messagePack(frame.messagePackFrame));
                plain.feed(encoding === "json" ? frame.plainJsonFrame : messagePack(frame.plainMessagePackFrame));
                expect(rows.normalizedState(), frame.name).toEqual(plain.normalizedState());
            }
            expect(rows.firstError).toBeUndefined();
            expect(plain.firstError).toBeUndefined();
            expect(rows.decodeErrors).toBe(0);
            expect(plain.decodeErrors).toBe(0);
            expect(rows.rowPatchesApplied).toBeGreaterThan(0);
            expect(plain.rowPatchesApplied).toBe(0);
        });
    }

    it("starts the row tables again at every join response", async () => {
        const rows = await reconstruction(rowFeatures);
        rows.feed(fixture.frames[0].jsonFrame);
        // A rejoin on the same socket: the creates for the slots the last join bound decode.
        rows.feed(joinResponse(rowFeatures));
        rows.feed(fixture.frames[0].jsonFrame);
        expect(rows.decodeErrors).toBe(0);
        expect(rows.rowEntryViolation).toBeUndefined();
    });

    it("stops on a broken rule, reports it once and drops the frames after it", async () => {
        const rules: string[] = [];
        const rows = await reconstruction(rowFeatures, (rule) => rules.push(rule));
        rows.feed(fixture.frames[0].jsonFrame);
        rows.feed(fixture.frames[0].jsonFrame);
        const atViolation = JSON.stringify(rows.normalizedState());
        rows.feed(fixture.frames[1].jsonFrame);
        // Frame 1 decodes against these tables, so only the drop keeps it out of the state.
        expect(JSON.stringify(rows.normalizedState())).toBe(atViolation);
        expect(rules).toEqual(["Row create on bound slot 0 of units.*"]);
        expect(rows.rowEntryViolation).toBe("Row create on bound slot 0 of units.*");
        expect(rows.decodeErrors).toBe(1);
        expect(rows.droppedAfterRowEntryViolation).toBe(1);
    });

    it("after a resync, still applies the same sequence's row entries, as the SDK runtime does", async () => {
        const sdk = await loadSdkCore();
        const table = sdk.pathIndexTableFor(fixture.pathHashes);
        const index = (pattern: string) => table.indexOf(fixture.pathHashes[pattern]);
        const rows = await reconstruction([...rowFeatures, "syncSequence"]);
        const unit = { bag: {}, blob: {}, core: { v: 0 }, hp: 1, note: null, parts: {}, tags: [] };
        // The resync at 5 binds slot 0; the shared frame at 5 then sets its hp and the round.
        rows.feed(JSON.stringify([3, 5, [index("units.*"), 0, 6, 0, null, "a", unit]]));
        rows.feed(JSON.stringify([2, 5, [index("round"), null, 1, 9], [index("units.*.hp"), [0], 8, [7]]]));
        expect(rows.firstError).toBeUndefined();
        const state = rows.normalizedState() as any;
        expect(state.units.a.hp).toBe(7);
        // Not a row patch, and not under a root with a bound row: skipped, as the snapshot has it.
        expect(state.round).toBeUndefined();
    });

    it("refuses a join with rowAddressing but without pathIndex", async () => {
        const rules: string[] = [];
        await reconstruction(["rowAddressing"], (rule) => rules.push(rule));
        expect(rules).toEqual(["rowAddressing without pathIndex"]);
    });
});

class FakeSocket implements WebSocketLike {
    handlers = new Map<string, (data?: any, extra?: any) => void>();
    closeCalls: Array<[number | undefined, string | undefined]> = [];
    on(event: string, handler: (data?: any, extra?: any) => void): void {
        this.handlers.set(event, handler);
    }
    send(): void {}
    close(code?: number, reason?: string): void {
        this.closeCalls.push([code, reason]);
    }
    terminate(): void {}
    emit(event: string, data?: any, extra?: any): void {
        this.handlers.get(event)?.(data, extra);
    }
}

function joinedClient(features: string[], reconnect = false) {
    const sockets: FakeSocket[] = [];
    const client = new WorkerClient(
        { key: "k1", serverUrl: "ws://x", landType: LAND, landInstanceId: "room-1", playerId: "p1", actions: [] },
        {
            createSocket: () => {
                const socket = new FakeSocket();
                sockets.push(socket);
                return socket;
            },
            now: () => 42,
            reconnect: reconnect ? { untilAt: Number.MAX_SAFE_INTEGER, delayMs: 1 } as any : undefined
        }
    );
    client.connect();
    sockets[0].emit("open");
    sockets[0].emit("message", Buffer.from(joinResponse(features)));
    return { client, sockets };
}

describe("the worker with row entries", () => {
    it("counts the row entries it receives where the feature was negotiated", () => {
        const { client, sockets } = joinedClient(rowFeatures);
        for (const frame of fixture.frames) sockets[0].emit("message", Buffer.from(frame.jsonFrame));
        const metrics = client.getSession().metrics;
        expect(metrics.rowEntries).toBeGreaterThan(0);
        expect(metrics.rowEntryCloses).toBe(0);
        expect(sockets[0].closeCalls).toEqual([]);
    });

    it("closes with 4013 on a row entry without the feature, records it and doesn't reconnect", () => {
        const { client, sockets } = joinedClient(plainFeatures, true);
        sockets[0].emit("message", Buffer.from(fixture.frames[0].jsonFrame));
        sockets[0].emit("message", Buffer.from(fixture.frames[1].jsonFrame));
        expect(sockets[0].closeCalls).toEqual([[4013, "row entry: op 6 without rowAddressing negotiated"]]);
        sockets[0].emit("close", 4013, Buffer.from("row entry: op 6 without rowAddressing negotiated"));
        const metrics = client.getSession().metrics;
        expect(metrics.rowEntryCloses).toBe(1);
        expect(metrics.rowEntries).toBe(0);
        expect(metrics.closes).toEqual([
            expect.objectContaining({
                initiator: "client",
                code: 4013,
                cause: "rowEntry",
                rowEntryRule: "op 6 without rowAddressing negotiated"
            })
        ]);
        expect(sockets).toHaveLength(1);
    });

    it("cuts the close reason at 123 UTF-8 bytes on a character boundary", () => {
        const reason = truncatedCloseReason(`row entry: ${"é".repeat(100)}`);
        expect(Buffer.byteLength(reason, "utf8")).toBeLessThanOrEqual(123);
        expect(reason.endsWith("é")).toBe(true);
        expect(truncatedCloseReason("short")).toBe("short");
    });
});
