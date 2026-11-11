import { describe, expect, it } from "vitest";
import { buildJoinMessage, declaredStateUpdateFeatures, ROW_ADDRESSING_FEATURE, STATE_UPDATE_FEATURES, WorkerClient } from "../src/worker";
import { loadSdkCore } from "../src/reconstruction";
import { EventEmitter } from "events";

// A server with a state-update feature on refuses a join that doesn't declare it, so every
// load-test join must declare what the SDK's decoder (which this client decodes through) reads.
// `rowAddressing` is declared only with `--row-addressing on`: the declaration is join metadata,
// which a recording server keeps in its records, so without the flag a join must be exactly the
// one this client sent before it decoded row entries.

/**
 * The join frame a connection sent before the client decoded row entries (the client at the
 * commit before rowAddressing was declared, 618746f3), byte for byte. Without the flag, a join
 * must still be this.
 */
const JOIN_BEFORE_ROW_ADDRESSING =
    '{"kind":"join","payload":{"join":{"requestID":"join-1","landType":"hero-defense","landInstanceId":"room-1",' +
    '"metadata":{"stateUpdateFeatures":["pathIndex","fieldMerge","syncSequence"]}}}}';

class FakeSocket extends EventEmitter {
    public readyState = 1;
    public sent: Array<string | Uint8Array> = [];
    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }
    close(): void {}
    terminate(): void {}
    pause(): void {}
    resume(): void {}
}

/** The first frame a connection sends: its join. */
function sentJoin(options: { rowAddressing?: boolean }): string {
    const socket = new FakeSocket();
    const client = new WorkerClient(
        { serverUrl: "ws://localhost:8080/game/hero-defense", landType: "hero-defense", landInstanceId: "room-1", playerId: "0-0", actions: [] },
        { createSocket: () => socket as any, now: () => 0, ...options }
    );
    client.connect();
    socket.emit("open");
    expect(socket.sent.length).toBeGreaterThan(0);
    return socket.sent[0] as string;
}

describe("join features", () => {
    it("declares the features the SDK decodes, rowAddressing only when asked", async () => {
        const sdk = await loadSdkCore();
        expect([...STATE_UPDATE_FEATURES, ROW_ADDRESSING_FEATURE]).toEqual(sdk.SUPPORTED_STATE_UPDATE_FEATURES);
        expect(declaredStateUpdateFeatures(false)).toEqual(["pathIndex", "fieldMerge", "syncSequence"]);
        expect(declaredStateUpdateFeatures(true)).toEqual(sdk.SUPPORTED_STATE_UPDATE_FEATURES);
    });

    it("every join carries the declaration, next to a template's metadata", () => {
        const plain = buildJoinMessage("hero-defense", "room-1", "join-1");
        expect(plain.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence"] });
        const templated = buildJoinMessage("hero-defense", "room-1", "join-1", { token: "t" });
        expect(templated.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence"], token: "t" });
        const rows = buildJoinMessage("hero-defense", "room-1", "join-1", { token: "t" }, true);
        expect(rows.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence", "rowAddressing"], token: "t" });
        // A template that declares its own list keeps it, with the flag or without.
        const own = buildJoinMessage("hero-defense", "room-1", "join-1", { stateUpdateFeatures: [] }, true);
        expect(own.payload.join.metadata).toEqual({ stateUpdateFeatures: [] });
    });

    it("without the flag, a connection's join is byte-identical to the join before row addressing", () => {
        expect(JSON.stringify(buildJoinMessage("hero-defense", "room-1", "join-1"))).toBe(JOIN_BEFORE_ROW_ADDRESSING);
        expect(sentJoin({})).toBe(JOIN_BEFORE_ROW_ADDRESSING);
        expect(sentJoin({ rowAddressing: false })).toBe(JOIN_BEFORE_ROW_ADDRESSING);
    });

    it("with the flag, a connection's join declares rowAddressing last", () => {
        expect(sentJoin({ rowAddressing: true })).toBe(
            JOIN_BEFORE_ROW_ADDRESSING.replace('"syncSequence"]', '"syncSequence","rowAddressing"]')
        );
    });
});
