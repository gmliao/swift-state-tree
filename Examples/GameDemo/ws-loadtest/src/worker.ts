import type { ActionConfig } from "./types";
import { MessageKindOpcode, decodeMessage, encodeMessageToMessagePack } from "./protocol";

/** Extract requestID from actionResponse or error message. Handles both JSON (nested payload) and MessagePack (normalized top-level). */
function extractRequestID(message: any, kind: "actionResponse" | "error"): string | undefined {
    if (kind === "actionResponse") {
        return (
            message.requestID ??
            message.payload?.actionResponse?.requestID
        );
    }
    return (
        message.details?.requestID ??
        message.payload?.error?.details?.requestID
    );
}

export interface WebSocketLike {
    on(event: "open" | "message" | "close" | "error", handler: (data?: any, extra?: any) => void): void;
    send(data: string | Uint8Array): void;
    close(code?: number, reason?: string): void;
    /** Drops the TCP connection without a close handshake (used only after a close timeout). */
    terminate?(): void;
}

/** One closed connection, as the client saw it. */
export interface CloseRecord {
    /** ms since epoch */
    t: number;
    key: string;
    landInstanceId: string;
    /** "client": this tool asked for the close (phase change or shutdown); "server": it did not. */
    initiator: "client" | "server";
    code?: number;
    reason?: string;
    joined: boolean;
    /** The close handshake did not finish in time and the socket was terminated. */
    forced?: boolean;
    /** Dropped without a close frame on purpose (`--boundary abrupt`). */
    abrupt?: boolean;
}

/** Close frame code and timeout for closes this tool initiates. */
export const CLIENT_CLOSE_CODE = 1000;
export const CLIENT_CLOSE_TIMEOUT_MS = 5000;

export interface WorkerConfig {
    /** Stable connection identity (see layout.ts); defaults to `landInstanceId`. */
    key?: string;
    serverUrl: string;
    landType: string;
    landInstanceId: string;
    playerId: string;
    actions: ActionConfig[];
    joinMetadata?: Record<string, unknown>;
}

export interface WorkerOptions {
    createSocket?: (url: string) => WebSocketLike;
    now?: () => number;
}

export interface JoinMessage {
    kind: "join";
    payload: {
        join: {
            requestID: string;
            landType: string;
            landInstanceId?: string;
            playerID?: string;
            deviceID?: string;
            metadata?: Record<string, unknown>;
        };
    };
}

export function buildJoinMessage(
    landType: string,
    landInstanceId: string,
    requestID: string,
    metadata?: Record<string, unknown>
): JoinMessage {
    return {
        kind: "join",
        payload: {
            join: {
                requestID,
                landType,
                landInstanceId,
                metadata
            }
        }
    };
}

export function buildActionMessage(
    typeIdentifier: string,
    requestID: string,
    payload: Record<string, unknown>
): [number, string, string, Record<string, unknown>] {
    return [MessageKindOpcode.action, requestID, typeIdentifier, payload];
}

export function selectAction(actions: ActionConfig[], index: number): ActionConfig {
    if (actions.length === 0) {
        return { name: "PlayAction", weight: 1, payloadTemplate: {} };
    }
    const totalWeight = actions.reduce((sum, action) => sum + action.weight, 0);
    const target = index % totalWeight;
    let acc = 0;
    for (const action of actions) {
        acc += action.weight;
        if (target < acc) {
            return action;
        }
    }
    return actions[0];
}

export interface WorkerMetrics {
    rttMs: number[];
    /** When each RTT sample completed (same clock as `now`), parallel to `rttMs`. */
    rttAt: number[];
    stateUpdateIntervalsMs: number[];
    /** When each update interval ended, parallel to `stateUpdateIntervalsMs`. */
    updateAt: number[];
    /** Actual minus intended send time per action (0 in lockstep mode), parallel to `sentAt`. */
    sendLagMs: number[];
    /** Actual send time per action. */
    sentAt: number[];
    errorCount: number;
    /** Closes the client did not ask for. */
    disconnectCount: number;
    actionsSent: number;
    closes: CloseRecord[];
}

function emptyMetrics(): WorkerMetrics {
    return {
        rttMs: [],
        rttAt: [],
        stateUpdateIntervalsMs: [],
        updateAt: [],
        sendLagMs: [],
        sentAt: [],
        errorCount: 0,
        disconnectCount: 0,
        actionsSent: 0,
        closes: []
    };
}

export class WorkerSession {
    private pendingRequests = new Map<string, number>();
    private lastStateUpdateAt?: number;
    public metrics: WorkerMetrics = emptyMetrics();

    /**
     * Starts a new phase's metrics on a connection that stays open. In-flight requests and the
     * last update time carry over, so a response or update interval spanning the boundary is
     * counted in the phase it completes in.
     */
    resetMetrics(): void {
        this.metrics = emptyMetrics();
    }

    /**
     * `originAt` is where RTT is measured from: the intended send time (spread mode) or the
     * actual one (lockstep). `actualAt` defaults to `originAt`.
     */
    recordSend(requestID: string, originAt: number, actualAt: number = originAt): void {
        this.pendingRequests.set(requestID, originAt);
        this.metrics.actionsSent += 1;
        this.metrics.sentAt.push(actualAt);
        this.metrics.sendLagMs.push(actualAt - originAt);
    }

    handleDecodedMessage(message: any, now: number): void {
        if (message && typeof message === "object") {
            if (message.kind === "actionResponse") {
                const requestID = extractRequestID(message, "actionResponse");
                this.recordRTT(requestID, now);
                return;
            }
            if (message.kind === "error") {
                this.metrics.errorCount += 1;
                const requestID = extractRequestID(message, "error");
                if (typeof requestID === "string") {
                    this.recordRTT(requestID, now);
                }
                return;
            }
            if (message.type === "stateUpdate" || message.type === "stateUpdateWithEvents") {
                this.recordStateUpdate(now);
            }
        }
    }

    recordClose(record: CloseRecord): void {
        this.metrics.closes.push(record);
        if (record.initiator === "server") {
            this.metrics.disconnectCount += 1;
        }
    }

    private recordRTT(requestID: string | undefined, now: number): void {
        if (!requestID) {
            return;
        }
        const sentAt = this.pendingRequests.get(requestID);
        if (sentAt !== undefined) {
            this.metrics.rttMs.push(now - sentAt);
            this.metrics.rttAt.push(now);
            this.pendingRequests.delete(requestID);
        }
    }

    private recordStateUpdate(now: number): void {
        if (this.lastStateUpdateAt !== undefined) {
            this.metrics.stateUpdateIntervalsMs.push(now - this.lastStateUpdateAt);
            this.metrics.updateAt.push(now);
        }
        this.lastStateUpdateAt = now;
    }
}

export class WorkerClient {
    private socket?: WebSocketLike;
    private messageEncoding: "json" | "messagepack" = "json";
    private joined = false;
    private closed = false;
    private closeRequested = false;
    private closeWaiters: Array<() => void> = [];
    private abrupt = false;
    private joinedCallbacks: Array<(at: number) => void> = [];
    private readonly session = new WorkerSession();
    private readonly now: () => number;
    private readonly createSocket: (url: string) => WebSocketLike;

    constructor(private readonly config: WorkerConfig, options: WorkerOptions = {}) {
        this.now = options.now ?? (() => Date.now());
        this.createSocket =
            options.createSocket ??
            ((url: string) => {
                const { WebSocket } = require("ws");
                return new WebSocket(url);
            });
    }

    connect(): void {
        this.socket = this.createSocket(this.config.serverUrl);
        this.socket.on("open", () => {
            this.sendJoin();
        });
        this.socket.on("message", (data) => {
            this.handleMessage(data);
        });
        this.socket.on("close", (code?: number, reason?: unknown) => {
            this.finishClose(code, reason, false);
        });
        this.socket.on("error", () => {
            this.session.metrics.errorCount += 1;
        });
    }

    getMessageEncoding(): "json" | "messagepack" {
        return this.messageEncoding;
    }

    isJoined(): boolean {
        return this.joined;
    }

    /** `connect()` was called (the connect ramp reached this client). */
    isStarted(): boolean {
        return this.socket !== undefined;
    }

    /** Calls `callback` with the join time once joined (right away if already joined). */
    onJoined(callback: (at: number) => void): void {
        if (this.joined) {
            callback(this.now());
        } else {
            this.joinedCallbacks.push(callback);
        }
    }

    /** Drops pending join callbacks (a phase ended before the join). */
    clearJoinedCallbacks(): void {
        this.joinedCallbacks = [];
    }

    /** Open and not closing: can be kept for the next phase. */
    isUsable(): boolean {
        return this.socket !== undefined && !this.closed && !this.closeRequested;
    }

    getKey(): string {
        return this.config.key ?? this.config.landInstanceId;
    }

    /**
     * Closes with a close frame and resolves when the close handshake ends. If it doesn't end
     * within `timeoutMs`, the socket is terminated and the record is marked `forced`.
     */
    close(reason: string, timeoutMs = CLIENT_CLOSE_TIMEOUT_MS): Promise<void> {
        if (!this.socket || this.closed) {
            return Promise.resolve();
        }
        if (this.closeRequested) {
            return new Promise<void>((resolve) => this.closeWaiters.push(resolve));
        }
        const done = new Promise<void>((resolve) => this.closeWaiters.push(resolve));
        {
            this.closeRequested = true;
            const socket = this.socket;
            const timer = setTimeout(() => {
                if (this.closed) {
                    return;
                }
                socket.terminate?.();
                this.finishClose(undefined, reason, true);
            }, timeoutMs);
            (timer as any).unref?.();
            socket.close(CLIENT_CLOSE_CODE, reason);
        }
        return done;
    }

    getSession(): WorkerSession {
        return this.session;
    }

    getPlayerId(): string {
        return this.config.playerId;
    }

    /** Sends an action; RTT is measured from `intendedAt` when given, else from now. */
    sendAction(requestID: string, actionName: string, payload: Record<string, unknown>, intendedAt?: number): void {
        if (!this.socket) {
            return;
        }
        const now = this.now();
        this.session.recordSend(requestID, intendedAt ?? now, now);
        if (this.messageEncoding === "messagepack") {
            const msg = buildActionMessage(actionName, requestID, payload);
            this.socket.send(encodeMessageToMessagePack(msg));
        } else {
            const msg = {
                kind: "action",
                payload: { requestID, typeIdentifier: actionName, payload }
            };
            this.socket.send(JSON.stringify(msg));
        }
    }

    /**
     * Drops the socket without a close frame (`--boundary abrupt`). Resolves at once; the record
     * is client-initiated and marked `abrupt`.
     */
    drop(reason: string): Promise<void> {
        if (!this.socket || this.closed) {
            return Promise.resolve();
        }
        this.closeRequested = true;
        this.abrupt = true;
        this.socket.terminate?.();
        this.finishClose(undefined, reason, false);
        return Promise.resolve();
    }

    private finishClose(code: number | undefined, reason: unknown, forced: boolean): void {
        if (this.closed) {
            return;
        }
        this.closed = true;
        const record: CloseRecord = {
            t: this.now(),
            key: this.getKey(),
            landInstanceId: this.config.landInstanceId,
            initiator: this.closeRequested ? "client" : "server",
            code,
            reason: reason === undefined ? undefined : String(reason),
            joined: this.joined
        };
        if (forced) {
            record.forced = true;
        }
        if (this.abrupt) {
            record.abrupt = true;
        }
        this.session.recordClose(record);
        const waiters = this.closeWaiters;
        this.closeWaiters = [];
        waiters.forEach((resolve) => resolve());
    }

    private sendJoin(metadata?: Record<string, unknown>): void {
        if (!this.socket) {
            return;
        }
        const msg = buildJoinMessage(
            this.config.landType,
            this.config.landInstanceId,
            "join-1",
            metadata ?? this.config.joinMetadata
        );
        this.socket.send(JSON.stringify(msg));
    }

    private handleMessage(data: any): void {
        const decoded = decodeMessage(data);
        if (decoded && decoded.kind === "joinResponse") {
            const success = decoded.success ?? decoded.payload?.joinResponse?.success;
            if (success) {
                if (!this.joined) {
                    this.joined = true;
                    const callbacks = this.joinedCallbacks;
                    this.joinedCallbacks = [];
                    const at = this.now();
                    callbacks.forEach((callback) => callback(at));
                }
            }
            const encoding = decoded.encoding ?? decoded.payload?.joinResponse?.encoding;
            if (encoding) {
                this.messageEncoding = encoding === "messagepack" ? "messagepack" : "json";
            }
        }
        this.session.handleDecodedMessage(decoded, this.now());
    }
}
