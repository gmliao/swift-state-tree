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
    on(event: "open" | "message" | "close" | "error", handler: (data?: any) => void): void;
    send(data: string | Uint8Array): void;
    close(): void;
}

export interface WorkerConfig {
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
    stateUpdateIntervalsMs: number[];
    errorCount: number;
    disconnectCount: number;
    actionsSent: number;
}

export class WorkerSession {
    private pendingRequests = new Map<string, number>();
    private lastStateUpdateAt?: number;
    public metrics: WorkerMetrics = {
        rttMs: [],
        stateUpdateIntervalsMs: [],
        errorCount: 0,
        disconnectCount: 0,
        actionsSent: 0
    };

    recordSend(requestID: string, sentAt: number): void {
        this.pendingRequests.set(requestID, sentAt);
        this.metrics.actionsSent += 1;
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

    recordDisconnect(): void {
        this.metrics.disconnectCount += 1;
    }

    private recordRTT(requestID: string | undefined, now: number): void {
        if (!requestID) {
            return;
        }
        const sentAt = this.pendingRequests.get(requestID);
        if (sentAt !== undefined) {
            this.metrics.rttMs.push(now - sentAt);
            this.pendingRequests.delete(requestID);
        }
    }

    private recordStateUpdate(now: number): void {
        if (this.lastStateUpdateAt !== undefined) {
            this.metrics.stateUpdateIntervalsMs.push(now - this.lastStateUpdateAt);
        }
        this.lastStateUpdateAt = now;
    }
}

export class WorkerClient {
    private socket?: WebSocketLike;
    private messageEncoding: "json" | "messagepack" = "json";
    private joined = false;
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
        this.socket.on("close", () => {
            this.session.recordDisconnect();
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

    getSession(): WorkerSession {
        return this.session;
    }

    getPlayerId(): string {
        return this.config.playerId;
    }

    sendAction(requestID: string, actionName: string, payload: Record<string, unknown>): void {
        if (!this.socket) {
            return;
        }
        this.session.recordSend(requestID, this.now());
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
                this.joined = true;
            }
            const encoding = decoded.encoding ?? decoded.payload?.joinResponse?.encoding;
            if (encoding) {
                this.messageEncoding = encoding === "messagepack" ? "messagepack" : "json";
            }
        }
        this.session.handleDecodedMessage(decoded, this.now());
    }
}
