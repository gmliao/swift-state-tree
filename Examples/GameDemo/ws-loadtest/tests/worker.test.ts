import { describe, it, expect, vi } from "vitest";
import { buildActionMessage, buildJoinMessage, WorkerClient, WorkerSession } from "../src/worker";
import { decodeMessage } from "../src/protocol";

describe("worker helpers", () => {
    it("builds join message object", () => {
        const msg = buildJoinMessage("hero-defense", "room-1", "join-1", { foo: "bar" });
        expect(msg.kind).toBe("join");
        expect(msg.payload.join.landType).toBe("hero-defense");
        expect(msg.payload.join.landInstanceId).toBe("room-1");
        // Every join also declares the state-update features (tests/join-features.test.ts).
        expect(msg.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence", "rowAddressing"], foo: "bar" });
    });

    it("builds action opcode array", () => {
        const msg = buildActionMessage("PlayAction", "req-1", {});
        expect(msg[0]).toBe(101);
        expect(msg[1]).toBe("req-1");
        expect(msg[2]).toBe("PlayAction");
    });

    it("records RTT for actionResponse (MessagePack normalized format)", () => {
        const session = new WorkerSession();
        session.recordSend("req-1", 1000);
        session.handleDecodedMessage({ kind: "actionResponse", requestID: "req-1" }, 1100);
        expect(session.metrics.rttMs).toEqual([100]);
    });

    it("records RTT for actionResponse (JSON nested payload format)", () => {
        const session = new WorkerSession();
        session.recordSend("req-json-1", 2000);
        session.handleDecodedMessage(
            { kind: "actionResponse", payload: { actionResponse: { requestID: "req-json-1", response: {} } } },
            2100
        );
        expect(session.metrics.rttMs).toEqual([100]);
    });

    it("records RTT for error (JSON nested payload format)", () => {
        const session = new WorkerSession();
        session.recordSend("req-err-1", 3000);
        session.handleDecodedMessage(
            {
                kind: "error",
                payload: { error: { code: "x", message: "y", details: { requestID: "req-err-1" } } }
            },
            3100
        );
        expect(session.metrics.rttMs).toEqual([100]);
    });

    it("tracks actions sent", () => {
        const session = new WorkerSession();
        session.recordSend("req-1", 1000);
        expect(session.metrics.actionsSent).toBe(1);
    });

    it("records state update cadence", () => {
        const session = new WorkerSession();
        session.handleDecodedMessage({ type: "stateUpdate" }, 1000);
        session.handleDecodedMessage({ type: "stateUpdate" }, 1100);
        expect(session.metrics.stateUpdateIntervalsMs).toEqual([100]);
    });

    it("records state update cadence from jsonObject frames (#138)", () => {
        const session = new WorkerSession();
        session.handleDecodedMessage(decodeMessage(JSON.stringify({ type: "firstSync", patches: [] })), 1000);
        session.handleDecodedMessage(decodeMessage(JSON.stringify({ type: "noChange" })), 1100);
        session.handleDecodedMessage(decodeMessage(JSON.stringify({ type: "diff", patches: [] })), 1250);
        expect(session.metrics.stateUpdateIntervalsMs).toEqual([100, 150]);
    });

    it("sends join on open and updates encoding on joinResponse", () => {
        const fake = new FakeWebSocket();
        const client = new WorkerClient(
            {
                serverUrl: "ws://localhost:8080/game/hero-defense",
                landType: "hero-defense",
                landInstanceId: "room-1",
                playerId: "0-0",
                actions: []
            },
            {
                createSocket: () => fake,
                now: () => 0
            }
        );

        client.connect();
        fake.emit("open");
        const sent = fake.sent[0] as string;
        expect(sent).toContain("\"kind\":\"join\"");

        fake.emit(
            "message",
            JSON.stringify({
                kind: "joinResponse",
                payload: { joinResponse: { success: true, encoding: "messagepack" } }
            })
        );
        expect(client.getMessageEncoding()).toBe("messagepack");
        expect(client.isJoined()).toBe(true);
    });

    it("an unanswered join becomes a timeout join failure after the join timeout; a late answer doesn't join", async () => {
        const fake = new FakeWebSocket();
        const client = new WorkerClient(
            { serverUrl: "ws://x", landType: "hero-defense", landInstanceId: "room-1", playerId: "0-0", actions: [] },
            { createSocket: () => fake, joinTimeoutMs: 30 }
        );
        client.connect();
        fake.emit("open");
        expect(client.takeJoinFailure()).toBeUndefined();
        await new Promise((resolve) => setTimeout(resolve, 60));
        const failure = client.takeJoinFailure();
        expect(failure?.reason).toBe("timeout");
        expect(failure?.message).toBe("no join response within 30 ms");
        expect(client.takeJoinFailure()).toBeUndefined();
        fake.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } }));
        expect(client.isJoined()).toBe(false);
        expect(client.isUsable()).toBe(false);
    });

    it("a joined connection doesn't time out", async () => {
        const fake = new FakeWebSocket();
        const client = new WorkerClient(
            { serverUrl: "ws://x", landType: "hero-defense", landInstanceId: "room-1", playerId: "0-0", actions: [] },
            { createSocket: () => fake, joinTimeoutMs: 30 }
        );
        client.connect();
        fake.emit("open");
        fake.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } }));
        await new Promise((resolve) => setTimeout(resolve, 60));
        expect(client.takeJoinFailure()).toBeUndefined();
        expect(client.isUsable()).toBe(true);
    });
});

class FakeWebSocket {
    public sent: Array<string | Uint8Array> = [];
    private handlers: Record<string, Array<(data?: any) => void>> = {};

    on(event: string, handler: (data?: any) => void): void {
        if (!this.handlers[event]) {
            this.handlers[event] = [];
        }
        this.handlers[event].push(handler);
    }

    send(data: string | Uint8Array): void {
        this.sent.push(data);
    }

    emit(event: string, data?: any): void {
        for (const handler of this.handlers[event] ?? []) {
            handler(data);
        }
    }

    close(): void {}
}

describe("convergence listing (--reconstruct-slots)", () => {
    const base = { serverUrl: "ws://localhost:8080/game/hero-defense", landType: "hero-defense", actions: [] };

    it("a connection reconstructs unless --reconstruct-slots left it out", async () => {
        const { reconstructionFor } = await import("../src/worker");
        const r = { sdk: {} as any, schema: {} };
        expect(reconstructionFor({}, r)).toBe(r);
        expect(reconstructionFor({ reconstruct: true }, r)).toBe(r);
        expect(reconstructionFor({ reconstruct: false }, r)).toBeUndefined();
        expect(reconstructionFor({}, undefined)).toBeUndefined();
    });

    it("lists only the connections that reconstruct, and every one when all do", async () => {
        const { convergenceListing } = await import("../src/worker");
        const reconstruction = { sdk: {} as any, schema: {} };
        const sampled = new WorkerClient({ ...base, key: "a", landInstanceId: "room-1", playerId: "p-0" }, { reconstruction });
        const unsampled = new WorkerClient({ ...base, key: "b", landInstanceId: "room-1", playerId: "p-1" }, {});
        expect(sampled.reconstructs()).toBe(true);
        expect(unsampled.reconstructs()).toBe(false);
        expect(convergenceListing([sampled, unsampled], new Set()).map((c) => c.key)).toEqual(["a"]);
        const other = new WorkerClient({ ...base, key: "c", landInstanceId: "room-2", playerId: "p-2" }, { reconstruction });
        expect(convergenceListing([sampled, other], new Set()).map((c) => c.key)).toEqual(["a", "c"]);
        expect(convergenceListing([sampled, other], new Set(), new Set(["room-2"])).map((c) => c.key)).toEqual(["c"]);
    });
});

describe("join latency", () => {
    const config = {
        serverUrl: "ws://localhost:8080/game/hero-defense",
        landType: "hero-defense",
        landInstanceId: "room-1",
        playerId: "0-0",
        actions: []
    };
    const joined = JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true } } });

    it("measures socket open to the successful JoinResponse, reported once", () => {
        const fake = new FakeWebSocket();
        let clock = 1000;
        const client = new WorkerClient(config, { createSocket: () => fake, now: () => clock });
        client.connect();
        clock = 1010;
        fake.emit("open");
        clock = 1052;
        fake.emit("message", joined);
        expect(client.takeJoinLatency()).toBe(42);
        // A kept connection doesn't report it again in the next phase.
        expect(client.takeJoinLatency()).toBeUndefined();
    });

    it("reports none for a refused join", () => {
        const fake = new FakeWebSocket();
        const client = new WorkerClient(config, { createSocket: () => fake, now: () => 0 });
        client.connect();
        fake.emit("open");
        fake.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: false } } }));
        expect(client.takeJoinLatency()).toBeUndefined();
    });

    it("records the JoinResponse's state-update features once per join, sorted, 'none' when absent", async () => {
        const { joinFeaturesKey } = await import("../src/worker");
        const withFeatures = JSON.stringify({
            kind: "joinResponse",
            payload: { joinResponse: { success: true, encoding: "messagepack", stateUpdateFeatures: ["pathIndex", "fieldMerge"] } }
        });
        const fake = new FakeWebSocket();
        const client = new WorkerClient(config, { createSocket: () => fake, now: () => 0 });
        client.connect();
        fake.emit("open");
        fake.emit("message", withFeatures);
        expect(client.takeJoinFeatures()).toBe("messagepack:fieldMerge,pathIndex");
        expect(client.takeJoinFeatures()).toBeUndefined();

        const plain = new FakeWebSocket();
        const old = new WorkerClient(config, { createSocket: () => plain, now: () => 0 });
        old.connect();
        plain.emit("open");
        plain.emit("message", joined);
        expect(old.takeJoinFeatures()).toBe("unknown:none");
        // A server with every feature off sends no field (TransportAdapter: nil for an empty list):
        // that is "none", both off, not "not recorded".
        const off = new FakeWebSocket();
        const plainServer = new WorkerClient(config, { createSocket: () => off, now: () => 0 });
        plainServer.connect();
        off.emit("open");
        off.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true, encoding: "messagepack" } } }));
        expect(plainServer.takeJoinFeatures()).toBe("messagepack:none");
        expect(joinFeaturesKey([], "json")).toBe("json:none");
        expect(joinFeaturesKey(["pathIndex", 3], "messagepack")).toBe("messagepack:pathIndex");

        const refused = new FakeWebSocket();
        const denied = new WorkerClient(config, { createSocket: () => refused, now: () => 0 });
        denied.connect();
        refused.emit("open");
        refused.emit("message", JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: false, stateUpdateFeatures: ["pathIndex"] } } }));
        expect(denied.takeJoinFeatures()).toBeUndefined();
    });

    it("sums the workers' feature counts into the phase totals' map", async () => {
        const { mergeJoinFeatures } = await import("../src/run");
        expect(mergeJoinFeatures([{ joinFeatures: { "messagepack:fieldMerge,pathIndex": 3 } },
            { joinFeatures: { "messagepack:fieldMerge,pathIndex": 2, "messagepack:none": 1 } }, {}]))
            .toEqual({ "messagepack:fieldMerge,pathIndex": 5, "messagepack:none": 1 });
    });

    it("summarizes a phase's joins over all workers", async () => {
        const { summarizeJoinLatency } = await import("../src/run");
        const summary = summarizeJoinLatency([{ joinLatenciesMs: [10, 20, 30] }, { joinLatenciesMs: [40] }]);
        expect(summary.count).toBe(4);
        expect(summary.max).toBe(40);
        expect(summary.p50).toBeGreaterThanOrEqual(20);
        expect(summary.p50).toBeLessThanOrEqual(30);
    });
});

describe("sync acks (#332)", () => {
    const config = {
        serverUrl: "ws://localhost:8080/game/hero-defense",
        landType: "hero-defense",
        landInstanceId: "room-1",
        playerId: "0-0",
        actions: []
    };
    const joinedWith = (features: string[]) =>
        JSON.stringify({ kind: "joinResponse", payload: { joinResponse: { success: true, encoding: "json", stateUpdateFeatures: features } } });
    const acks = (fake: FakeWebSocket) => fake.sent.filter((d) => typeof d === "string" && d.startsWith("[108,"));

    it("acks a firstSync and a resync at once, the last applied sequence on the timer, and stops on close", () => {
        vi.useFakeTimers();
        try {
            const fake = new FakeWebSocket();
            const client = new WorkerClient(config, { createSocket: () => fake, now: () => 0 });
            client.connect();
            fake.emit("open");
            fake.emit("message", joinedWith(["syncSequence", "rowAddressing"]));
            vi.advanceTimersByTime(1500);
            expect(acks(fake)).toEqual([]);
            fake.emit("message", JSON.stringify([1, 5]));
            expect(acks(fake)).toEqual(["[108,5]"]);
            fake.emit("message", JSON.stringify([2, 6]));
            expect(acks(fake)).toEqual(["[108,5]"]);
            vi.advanceTimersByTime(1000);
            expect(acks(fake)).toEqual(["[108,5]", "[108,6]"]);
            fake.emit("message", JSON.stringify([3, 9]));
            expect(acks(fake).at(-1)).toBe("[108,9]");
            expect(client.resyncCount).toBe(1);
            fake.emit("close", 1000, "");
            const sent = acks(fake).length;
            vi.advanceTimersByTime(5000);
            expect(acks(fake).length).toBe(sent);
        } finally {
            vi.useRealTimers();
        }
    });

    it("sends no acks when the server didn't negotiate syncSequence", () => {
        vi.useFakeTimers();
        try {
            const fake = new FakeWebSocket();
            const client = new WorkerClient(config, { createSocket: () => fake, now: () => 0 });
            client.connect();
            fake.emit("open");
            fake.emit("message", joinedWith(["pathIndex"]));
            fake.emit("message", JSON.stringify([1, ["/x", 1, 1]]));
            vi.advanceTimersByTime(3000);
            expect(acks(fake)).toEqual([]);
            expect(client.resyncCount).toBe(0);
        } finally {
            vi.useRealTimers();
        }
    });
});
