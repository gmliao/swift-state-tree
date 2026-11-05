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
    /** Extensions the server accepted (`ws`: e.g. `"permessage-deflate"`, or `""`), once open. */
    extensions?: string;
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

/**
 * A request unanswered for longer than this is a timeout: a response arriving later is a late
 * response, and one still missing at the phase end counts as timed out.
 */
export const RESPONSE_TIMEOUT_MS = 5000;

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
    /** How long a join may go unanswered before it counts as a `timeout` join failure. */
    joinTimeoutMs?: number;
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

/** A client event (`[103, fromClient, type, payload]` in the opcode encodings). */
export const EVENT_FROM_CLIENT = 0;

export function buildEventMessage(
    typeIdentifier: string,
    payload: Record<string, unknown>
): [number, number, string, Record<string, unknown>] {
    return [MessageKindOpcode.event, EVENT_FROM_CLIENT, typeIdentifier, payload];
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
    /** When each error was counted, parallel to the `errorCount` increments. */
    errorAt: number[];
    /** RTT origins of responses that took longer than `lateAfterMs` (their RTT is still recorded). */
    lateResponseOrigins: number[];
    errorCount: number;
    /** Closes the client did not ask for. */
    disconnectCount: number;
    actionsSent: number;
    /** Send time of each client event, by event name. */
    eventSentAt: Record<string, number[]>;
    /**
     * Payload size in bytes of each state update, parallel to `updateAt` (so, like the intervals,
     * without a connection's first update: its join snapshot). The payload is the message `ws`
     * hands over, after permessage-deflate inflation if the connection negotiated it
     * (`permessageDeflate`). Empty when the caller gave no sizes.
     */
    updateBytes: number[];
    /** Connections opened with and without permessage-deflate negotiated (`ws` offers it). */
    permessageDeflate: PermessageDeflateCounts;
    closes: CloseRecord[];
}

export interface PermessageDeflateCounts {
    negotiated: number;
    notNegotiated: number;
}

function emptyMetrics(): WorkerMetrics {
    return {
        rttMs: [],
        rttAt: [],
        stateUpdateIntervalsMs: [],
        updateAt: [],
        sendLagMs: [],
        sentAt: [],
        errorAt: [],
        lateResponseOrigins: [],
        errorCount: 0,
        disconnectCount: 0,
        actionsSent: 0,
        eventSentAt: {},
        updateBytes: [],
        permessageDeflate: { negotiated: 0, notNegotiated: 0 },
        closes: []
    };
}

/**
 * A plain state frame this soon after an opcode-107 frame, with no state frame between them, is
 * the per-player half of the same sync. In the opcode encodings a sync reaches a session as the
 * merged broadcast frame (107), its targeted event frames, then its per-player state frame
 * (`TransportAdapter.planSyncPhase`); both frames come from one write, so they arrive together.
 */
export const SYNC_FRAME_GROUP_MS = 10;

export class WorkerSession {
    private pendingRequests = new Map<string, number>();
    private lastStateUpdateAt?: number;
    /** The last state frame was a 107 frame: when it arrived, and where its size went (if recorded). */
    private openBroadcastFrame?: { at: number; bytesIndex?: number };
    public metrics: WorkerMetrics = emptyMetrics();

    /** A response slower than this (ms) is a late response (a timeout in the report). */
    constructor(private readonly lateAfterMs: number = RESPONSE_TIMEOUT_MS) {}

    /**
     * Starts a new phase's metrics on a connection that stays open. The last update time carries
     * over, so an update interval spanning the boundary is counted in the phase it completes in.
     * The phase runner takes unanswered requests (`takePending`) before this.
     */
    resetMetrics(): void {
        this.metrics = emptyMetrics();
        if (this.openBroadcastFrame) {
            this.openBroadcastFrame = { at: this.openBroadcastFrame.at };
        }
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

    /** `byteLength` is the frame's size on the wire, recorded for state updates. */
    handleDecodedMessage(message: any, now: number, byteLength?: number): void {
        if (message && typeof message === "object") {
            if (message.kind === "actionResponse") {
                const requestID = extractRequestID(message, "actionResponse");
                this.recordRTT(requestID, now);
                return;
            }
            if (message.kind === "error") {
                this.recordError(now);
                const requestID = extractRequestID(message, "error");
                if (typeof requestID === "string") {
                    this.recordRTT(requestID, now);
                }
                return;
            }
            if (message.type === "stateUpdateWithEvents") {
                const bytesIndex = this.recordStateUpdate(now, byteLength);
                this.openBroadcastFrame = { at: now, bytesIndex };
            } else if (message.type === "stateUpdate") {
                const open = this.openBroadcastFrame;
                this.openBroadcastFrame = undefined;
                if (open && now - open.at <= SYNC_FRAME_GROUP_MS) {
                    // The per-player frame of the 107 frame's sync: one update, both frames' bytes.
                    if (open.bytesIndex !== undefined && byteLength !== undefined) {
                        this.metrics.updateBytes[open.bytesIndex] += byteLength;
                    }
                } else {
                    this.recordStateUpdate(now, byteLength);
                }
            }
        }
    }

    /** Counts an opened connection by whether permessage-deflate was negotiated. */
    recordOpen(extensions: string | undefined): void {
        if (typeof extensions === "string" && extensions.includes("permessage-deflate")) {
            this.metrics.permessageDeflate.negotiated += 1;
        } else {
            this.metrics.permessageDeflate.notNegotiated += 1;
        }
    }

    recordError(now: number): void {
        this.metrics.errorCount += 1;
        this.metrics.errorAt.push(now);
    }

    /**
     * Requests still unanswered: returns their RTT origins and forgets them, so a response that
     * arrives later is not counted in a later phase.
     */
    takePending(): number[] {
        const origins = [...this.pendingRequests.values()];
        this.pendingRequests.clear();
        return origins;
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
            if (now - sentAt > this.lateAfterMs) {
                this.metrics.lateResponseOrigins.push(sentAt);
            }
            this.pendingRequests.delete(requestID);
        }
    }

    /** Records one update (one sync); returns the index of its size in `updateBytes`, if recorded. */
    private recordStateUpdate(now: number, byteLength: number | undefined): number | undefined {
        let bytesIndex: number | undefined;
        if (this.lastStateUpdateAt !== undefined) {
            this.metrics.stateUpdateIntervalsMs.push(now - this.lastStateUpdateAt);
            this.metrics.updateAt.push(now);
            if (byteLength !== undefined) {
                bytesIndex = this.metrics.updateBytes.push(byteLength) - 1;
            }
        }
        this.lastStateUpdateAt = now;
        return bytesIndex;
    }
}

/** A join that didn't succeed. Join failures are not counted as errors (`errorCount`). */
export interface JoinFailure {
    t: number;
    /**
     * `rejected`: a join response with `success: false`. `error`: an error frame before the
     * connection joined (how SwiftStateTree rejects a join, e.g. a full room). `closed`: the
     * connection closed before it joined, without the client asking. `timeout`: no answer to the
     * join within `RESPONSE_TIMEOUT_MS` of connecting, or by the end of the phase if that is
     * sooner (a connection whose socket never opened counts too).
     */
    reason: "rejected" | "error" | "closed" | "timeout";
    code?: string;
    message?: string;
}

/** Request id of the join every connection sends. */
const JOIN_REQUEST_ID = "join-1";

export class WorkerClient {
    private socket?: WebSocketLike;
    private messageEncoding: "json" | "messagepack" = "json";
    private joined = false;
    private closed = false;
    private closeRequested = false;
    private closeWaiters: Array<() => void> = [];
    private abrupt = false;
    private joinedCallbacks: Array<(at: number) => void> = [];
    private joinedAt?: number;
    private closedAt?: number;
    private joinFailure?: JoinFailure;
    private joinFailureReported = false;
    private joinTimer?: ReturnType<typeof setTimeout>;
    private readonly joinTimeoutMs: number;
    private readonly session = new WorkerSession();
    private readonly now: () => number;
    private readonly createSocket: (url: string) => WebSocketLike;

    constructor(private readonly config: WorkerConfig, options: WorkerOptions = {}) {
        this.now = options.now ?? (() => Date.now());
        this.joinTimeoutMs = options.joinTimeoutMs ?? RESPONSE_TIMEOUT_MS;
        this.createSocket =
            options.createSocket ??
            ((url: string) => {
                const { WebSocket } = require("ws");
                return new WebSocket(url);
            });
    }

    connect(): void {
        this.socket = this.createSocket(this.config.serverUrl);
        this.joinTimer = setTimeout(() => {
            this.joinTimer = undefined;
            this.recordJoinFailure("timeout", undefined, `no join response within ${this.joinTimeoutMs} ms`);
        }, this.joinTimeoutMs);
        (this.joinTimer as any).unref?.();
        this.socket.on("open", () => {
            this.session.recordOpen(this.socket?.extensions);
            this.sendJoin();
        });
        this.socket.on("message", (data) => {
            this.handleMessage(data);
        });
        this.socket.on("close", (code?: number, reason?: unknown) => {
            this.finishClose(code, reason, false);
        });
        this.socket.on("error", () => {
            this.session.recordError(this.now());
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

    /** `[start, end)` while this connection was joined and open, clipped to `[from, to)`. */
    activeInterval(from: number, to: number): [number, number] | undefined {
        if (this.joinedAt === undefined) {
            return undefined;
        }
        const start = Math.max(from, this.joinedAt);
        const end = Math.min(to, this.closedAt ?? to);
        return end > start ? [start, end] : undefined;
    }

    /**
     * Joined, open and not closing: can be kept for the next phase. A connection that didn't join
     * (refused, unanswered or still pending) is closed at the transition, and the next phase opens
     * a new one that joins again.
     */
    isUsable(): boolean {
        return this.joined && this.socket !== undefined && !this.closed && !this.closeRequested;
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

    /** Sends a client event: no response is expected, so it is counted but not timed. */
    sendEvent(eventName: string, payload: Record<string, unknown>): void {
        if (!this.socket) {
            return;
        }
        const sentAt = this.session.metrics.eventSentAt;
        (sentAt[eventName] ??= []).push(this.now());
        if (this.messageEncoding === "messagepack") {
            this.socket.send(encodeMessageToMessagePack(buildEventMessage(eventName, payload)));
        } else {
            this.socket.send(JSON.stringify({ kind: "event", payload: { fromClient: { type: eventName, payload } } }));
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
        this.closedAt = this.now();
        this.clearJoinTimer();
        if (!this.joined && !this.closeRequested && this.socket !== undefined) {
            this.recordJoinFailure("closed", code, reason === undefined ? undefined : String(reason));
        }
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
            JOIN_REQUEST_ID,
            metadata ?? this.config.joinMetadata
        );
        this.socket.send(JSON.stringify(msg));
    }

    private handleMessage(data: any): void {
        const decoded = decodeMessage(data);
        if (decoded && decoded.kind === "joinResponse") {
            const success = decoded.success ?? decoded.payload?.joinResponse?.success;
            if (!success && !this.joined) {
                const response = decoded.payload?.joinResponse ?? decoded;
                this.recordJoinFailure("rejected", undefined, response?.reason ?? response?.message);
            }
            if (success) {
                if (!this.joined && !this.joinFailure) {
                    this.clearJoinTimer();
                    this.joined = true;
                    this.joinedAt = this.now();
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
        if (decoded && decoded.kind === "error" && !this.joined && isJoinError(decoded)) {
            this.recordJoinFailure(
                "error",
                decoded.code ?? decoded.payload?.error?.code,
                decoded.message ?? decoded.payload?.error?.message
            );
            return;
        }
        this.session.handleDecodedMessage(decoded, this.now(), frameByteLength(data));
    }

    /**
     * At the phase end: a connection the ramp started that has neither joined nor failed yet
     * counts as a `timeout` join failure now.
     */
    noteJoinUnansweredAtPhaseEnd(): void {
        if (this.socket !== undefined) {
            this.recordJoinFailure("timeout", undefined, "no join response by the phase end");
        }
    }

    private clearJoinTimer(): void {
        if (this.joinTimer !== undefined) {
            clearTimeout(this.joinTimer);
            this.joinTimer = undefined;
        }
    }

    private recordJoinFailure(reason: JoinFailure["reason"], code?: unknown, message?: unknown): void {
        if (this.joined || this.joinFailure) {
            return;
        }
        this.clearJoinTimer();
        this.joinFailure = {
            t: this.now(),
            reason,
            code: code === undefined ? undefined : String(code),
            message: message === undefined ? undefined : String(message)
        };
    }

    /** The join failure not yet reported, if any; each failure is returned once. */
    takeJoinFailure(): JoinFailure | undefined {
        if (!this.joinFailure || this.joinFailureReported) {
            return undefined;
        }
        this.joinFailureReported = true;
        return this.joinFailure;
    }
}

/** Size of a received frame in bytes (a text frame as UTF-8). */
export function frameByteLength(data: unknown): number | undefined {
    if (typeof data === "string") {
        return Buffer.byteLength(data, "utf8");
    }
    if (data instanceof ArrayBuffer) {
        return data.byteLength;
    }
    if (ArrayBuffer.isView(data)) {
        return data.byteLength;
    }
    return undefined;
}

/**
 * An error frame answering the join: its request id is the join's, or it has none (an error
 * before the join was answered can only concern the join).
 */
function isJoinError(decoded: any): boolean {
    const requestID = extractRequestID(decoded, "error");
    return requestID === undefined || requestID === JOIN_REQUEST_ID;
}
