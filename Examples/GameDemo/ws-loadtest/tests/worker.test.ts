import { describe, it, expect } from "vitest";
import { buildActionMessage, buildJoinMessage, WorkerClient, WorkerSession } from "../src/worker";

describe("worker helpers", () => {
    it("builds join message object", () => {
        const msg = buildJoinMessage("hero-defense", "room-1", "join-1", { foo: "bar" });
        expect(msg.kind).toBe("join");
        expect(msg.payload.join.landType).toBe("hero-defense");
        expect(msg.payload.join.landInstanceId).toBe("room-1");
        expect(msg.payload.join.metadata).toEqual({ foo: "bar" });
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
