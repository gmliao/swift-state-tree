import { describe, it, expect } from "vitest";
import { LandViewRuntime } from "./LandViewRuntime";

type Snapshot = { value: number };
type Diff = { patch: string };

type Actions = { inc: { amount: number } };
type ClientEvents = { ping: Record<string, never> };
type ServerEvents = { pong: { at: number } };

class MockWebSocket {
    public sent: string[] = [];
    private listeners = new Map<string, Set<(ev: { data: string }) => void>>();

    send(data: string) {
        this.sent.push(data);
    }

    addEventListener(type: string, listener: (ev: { data: string }) => void) {
        if (!this.listeners.has(type)) {
            this.listeners.set(type, new Set());
        }
        this.listeners.get(type)!.add(listener);
    }

    removeEventListener(type: string, listener: (ev: { data: string }) => void) {
        this.listeners.get(type)?.delete(listener);
    }

    emitMessage(data: unknown) {
        const payload = typeof data === "string" ? data : JSON.stringify(data);
        this.listeners.get("message")?.forEach((fn) => fn({ data: payload }));
    }
}

describe("TypedLandClient", () => {
  const wireIds = {
    actions: { inc: "Inc" },
    clientEvents: { ping: "Ping" },
    serverEvents: { pong: "Pong" },
  } as const;

  it("applies diff to latest snapshot", () => {
    const ws = new MockWebSocket();
    const client = new LandViewRuntime<"demo", "inc", "ping", "pong", Snapshot, Diff, Actions, ClientEvents, ServerEvents>({
      landId: "demo",
      ws: ws as unknown as WebSocket,
      wireIds,
    });

    ws.emitMessage({ kind: "snapshot", landId: "demo", payload: { value: 1 } });
    ws.emitMessage({
      kind: "diff",
      landId: "demo",
      payload: { patches: [{ op: "replace", path: "/value", value: 5 }] },
    });

    expect(client.latestSnapshot).toEqual({ value: 5 });
  });

    it("sends actions and client events with wire ids", () => {
        const ws = new MockWebSocket();
        const client = new LandViewRuntime<"demo", "inc", "ping", "pong", Snapshot, Diff, Actions, ClientEvents, ServerEvents>({
            landId: "demo",
            ws: ws as unknown as WebSocket,
            wireIds,
        });

        client.sendAction("inc", { amount: 2 });
        client.sendClientEvent("ping", {});

        expect(ws.sent).toHaveLength(2);
        expect(JSON.parse(ws.sent[0])).toEqual({
            kind: "action",
            landId: "demo",
            id: "Inc",
            payload: { amount: 2 },
        });
        expect(JSON.parse(ws.sent[1])).toEqual({
            kind: "clientEvent",
            landId: "demo",
            id: "Ping",
            payload: {},
        });
    });

    it("routes snapshot and diff to handlers and tracks latest snapshot", () => {
        const ws = new MockWebSocket();
        const client = new LandViewRuntime<"demo", "inc", "ping", "pong", Snapshot, Diff, Actions, ClientEvents, ServerEvents>({
            landId: "demo",
            ws: ws as unknown as WebSocket,
            wireIds,
        });

        let snapshotValue = 0;
        let diffPatch = "";
        client.onSnapshot((s) => (snapshotValue = s.value));
        client.onDiff((d) => (diffPatch = d.patch));

        ws.emitMessage({ kind: "snapshot", landId: "demo", payload: { value: 42 } });
        ws.emitMessage({ kind: "diff", landId: "demo", payload: { patch: "p1" } });

        expect(snapshotValue).toBe(42);
        expect(client.latestSnapshot).toEqual({ value: 42 });
        expect(diffPatch).toBe("p1");
    });

    it("routes server events using reverse wire map", () => {
        const ws = new MockWebSocket();
        const client = new LandViewRuntime<"demo", "inc", "ping", "pong", Snapshot, Diff, Actions, ClientEvents, ServerEvents>({
            landId: "demo",
            ws: ws as unknown as WebSocket,
            wireIds,
        });

        let called = false;
        client.onServerEvent("pong", (payload) => {
            called = true;
            expect(payload).toEqual({ at: 123 });
        });

        ws.emitMessage({ kind: "serverEvent", landId: "demo", id: "Pong", payload: { at: 123 } });
        expect(called).toBe(true);
    });
});
