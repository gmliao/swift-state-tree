// Base runtime for typed Land clients.
// Handles WebSocket send/receive with a `{ kind, landId, id?, payload }` envelope
// and manages subscriptions for snapshot/diff/server events.

export type Unsubscribe = () => void;

type OutgoingEnvelope =
  | { kind: "action"; landId: string; id: string; payload: unknown }
  | { kind: "clientEvent"; landId: string; id: string; payload: unknown };

type IncomingEnvelope =
  | { kind: "snapshot"; landId: string; payload: unknown }
  | { kind: "diff"; landId: string; payload: unknown }
  | { kind: "serverEvent"; landId: string; id: string; payload: unknown };

export interface WireIdMapping<
  A extends string,
  CE extends string,
  SE extends string
> {
  actions: Record<A, string>; // typed id -> wire id
  clientEvents: Record<CE, string>;
  serverEvents: Record<SE, string>;
}

export interface LandViewRuntimeOptions<
  L extends string,
  A extends string,
  CE extends string,
  SE extends string,
  Snapshot,
  Diff
> {
  landId: L;
  ws: WebSocket;
  wireIds: WireIdMapping<A, CE, SE>;
  logger?: (msg: string, meta?: unknown) => void;
  parseIncoming?: (raw: string) => IncomingEnvelope | null;
}

type SnapshotHandler<Snapshot> = (snapshot: Snapshot) => void;
type DiffHandler<Diff> = (diff: Diff) => void;

export type JoinOptions = {
  requestID?: string;
  playerID?: string;
  deviceID?: string;
  metadata?: Record<string, string>;
};

export class LandViewRuntime<
  L extends string,
  A extends string,
  CE extends string,
  SE extends string,
  Snapshot,
  Diff,
  Actions extends Record<A, unknown>,
  ClientEvents extends Record<CE, unknown>,
  ServerEvents extends Record<SE, unknown>
> {
  private readonly ws: WebSocket;
  private readonly landId: L;
  private readonly wireIds: WireIdMapping<A, CE, SE>;
  private readonly parseIncoming: (raw: string) => IncomingEnvelope | null;
  private readonly logger?: (msg: string, meta?: unknown) => void;
  private disposed = false;

  private readonly serverEventReverse: Map<string, SE> = new Map();
  private readonly snapshotHandlers = new Set<SnapshotHandler<Snapshot>>();
  private readonly diffHandlers = new Set<DiffHandler<Diff>>();
  private readonly serverHandlers: Map<
    SE,
    Set<(payload: ServerEvents[SE]) => void>
  > = new Map();
  private _latestSnapshot: Snapshot | null = null;
  private readonly textDecoder = new TextDecoder();

  constructor(options: LandViewRuntimeOptions<L, A, CE, SE, Snapshot, Diff>) {
    this.landId = options.landId;
    this.ws = options.ws;
    this.wireIds = options.wireIds;
    this.logger = options.logger;
    this.parseIncoming = options.parseIncoming ?? this.defaultParseIncoming;

    // Build reverse map for server events
    for (const [key, wire] of Object.entries(
      this.wireIds.serverEvents
    ) as Array<[SE, string]>) {
      this.serverEventReverse.set(wire, key);
      this.serverHandlers.set(key, new Set());
    }

    this.ws.addEventListener("message", this.onMessage);
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.ws.removeEventListener("message", this.onMessage);
    this.snapshotHandlers.clear();
    this.diffHandlers.clear();
    this.serverHandlers.forEach((set) => set.clear());
  }

  // Accessors
  get latestSnapshot(): Snapshot | null {
    return this._latestSnapshot;
  }

  // Actions / Client Events
  sendAction<ID extends A>(id: ID, payload: Actions[ID]) {
    const wireId = this.wireIds.actions[id];
    this.send({ kind: "action", landId: this.landId, id: wireId, payload });
  }

  sendClientEvent<ID extends CE>(id: ID, payload: ClientEvents[ID]) {
    const wireId = this.wireIds.clientEvents[id];
    this.send({
      kind: "clientEvent",
      landId: this.landId,
      id: wireId,
      payload,
    });
  }

  // Server Events
  onServerEvent<ID extends SE>(
    id: ID,
    handler: (payload: ServerEvents[ID]) => void
  ): Unsubscribe {
    const bucket = this.serverHandlers.get(id);
    if (!bucket) throw new Error(`Unknown server event: ${String(id)}`);
    bucket.add(handler as any);
    return () => bucket.delete(handler as any);
  }

  // State sync
  onSnapshot(handler: SnapshotHandler<Snapshot>): Unsubscribe {
    this.snapshotHandlers.add(handler);
    return () => this.snapshotHandlers.delete(handler);
  }

  onDiff(handler: DiffHandler<Diff>): Unsubscribe {
    this.diffHandlers.add(handler);
    return () => this.diffHandlers.delete(handler);
  }

  // Join / Leave
  join(options: JoinOptions = {}): string {
    const requestID =
      options.requestID ??
      `join-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const payload = {
      requestID,
      landID: this.landId,
      playerID: options.playerID,
      deviceID: options.deviceID,
      metadata: options.metadata,
    };
    this.sendRaw({ join: payload });
    return requestID;
  }

  leave() {
    this.sendRaw({ leave: { landID: this.landId } });
  }

  // Internal helpers
  private send(envelope: OutgoingEnvelope) {
    try {
      this.ws.send(JSON.stringify(envelope));
    } catch (err) {
      this.log("Failed to send envelope", err);
    }
  }

  private sendRaw(payload: Record<string, unknown>) {
    try {
      this.ws.send(JSON.stringify(payload));
    } catch (err) {
      this.log("Failed to send raw payload", err);
    }
  }

  private onMessage = (event: MessageEvent) => {
    if (this.disposed) return;
    const raw = this.normalizeIncoming(event.data);
    if (!raw) {
      this.log("Dropped incoming message (unable to normalize)", {
        type: typeof event.data,
        isArrayBuffer: event.data instanceof ArrayBuffer,
        isBlob: typeof Blob !== "undefined" && event.data instanceof Blob,
      });
      return;
    }
    const parsed = this.parseIncoming(raw);
    if (!parsed) {
      this.log("Dropped incoming message (parse failed)", {
        preview: raw.slice(0, 200),
      });
      return;
    }
    const targetLand = (parsed as any).landId ?? this.landId;
    if (targetLand !== this.landId) {
      this.log("Dropped message for different land", {
        target: targetLand,
        expected: this.landId,
      });
      return;
    }

    // If the message has `kind`, treat as envelope; otherwise handle StateUpdate shape.
    if ((parsed as any).kind) {
      this.log("Incoming envelope", parsed);

      switch ((parsed as any).kind) {
        case "snapshot": {
          const snapshot = (parsed as any).payload as Snapshot;
          this._latestSnapshot = structuredClone(snapshot);
          this.snapshotHandlers.forEach((h) => h(structuredClone(snapshot)));
          break;
        }
        case "diff": {
          const diff = (parsed as any).payload as Diff;
          this.log("Applying diff", diff);
          this.applyDiff(diff);
          this.diffHandlers.forEach((h) => h(diff));
          break;
        }
        case "serverEvent": {
          const id = this.serverEventReverse.get((parsed as any).id);
          this.log("Server event received", { id: (parsed as any).id, resolvedId: id });
          if (!id) return;
          const handlers = this.serverHandlers.get(id);
          if (!handlers) return;
          const payload = (parsed as any).payload as ServerEvents[typeof id];
          handlers.forEach((h) => h(payload));
          break;
        }
        default:
          this.log("Unknown envelope kind", parsed);
          break;
      }
      return;
    }

    // Handle StateUpdate { type: "diff" | "firstSync" | "noChange", patches? }
    if ((parsed as any).type === "diff" || (parsed as any).type === "firstSync") {
      const diff = { patches: (parsed as any).patches ?? [] } as Diff;
      this.log("Applying state update", diff);
      this.applyDiff(diff);
      this.diffHandlers.forEach((h) => h(diff));
      return;
    }
    if ((parsed as any).type === "noChange") {
      this.log("State update: noChange");
      return;
    }

    this.log("Unknown message shape", parsed);
  };

  private defaultParseIncoming(raw: string): IncomingEnvelope | null {
    try {
      return JSON.parse(raw) as IncomingEnvelope;
    } catch {
      this.log("Failed to parse incoming message", raw);
      return null;
    }
  }

  private log(msg: string, meta?: unknown) {
    if (this.logger) this.logger(msg, meta);
    else {
      // Use console.log to ensure visibility in browser devtools when no logger is supplied.
      // eslint-disable-next-line no-console
      console.log(`[LandViewRuntime] ${msg}`, meta ?? "");
    }
  }

  private normalizeIncoming(data: unknown): string | null {
    if (typeof data === "string") return data;
    if (data instanceof ArrayBuffer) {
      try {
        return this.textDecoder.decode(data);
      } catch (err) {
        this.log("Failed to decode ArrayBuffer", err);
        return null;
      }
    }
    if (typeof Blob !== "undefined" && data instanceof Blob) {
      this.log(
        "Received Blob data; set binaryType='arraybuffer' to decode automatically"
      );
      return null;
    }
    return null;
  }

  private applyDiff(diff: Diff) {
    if (!this._latestSnapshot) return;
    // Expect diff to have patches: Array<{ op, path, value? }>
    const patches = (diff as any).patches as
      | Array<{ op: string; path: string; value?: unknown }>
      | undefined;
    if (!patches || patches.length === 0) return;
    const next = structuredClone(this._latestSnapshot);
    for (const patch of patches) {
      this.applyPatch(next as any, patch);
    }
    this._latestSnapshot = next;
  }

  private applyPatch(
    target: any,
    patch: { op: string; path: string; value?: unknown }
  ) {
    const parts = patch.path.split("/").filter((p) => p.length > 0);
    if (parts.length === 0) return;
    let cursor = target;
    for (let i = 0; i < parts.length - 1; i++) {
      const key = parts[i];
      if (typeof cursor[key] !== "object" || cursor[key] === null) {
        cursor[key] = {};
      }
      cursor = cursor[key];
    }
    const last = parts[parts.length - 1];
    switch (patch.op) {
      case "add":
      case "replace":
        cursor[last] = structuredClone(patch.value);
        break;
      case "remove":
        delete cursor[last];
        break;
      default:
        break;
    }
  }
}
