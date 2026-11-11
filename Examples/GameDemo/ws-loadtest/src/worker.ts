import type { SampleRecord, SampleWriter } from "./samples-sink";
import type { ActionConfig } from "./types";
import { InputLatencyTracker, echoPointOf, emptyInputLatencyMetrics, type InputLatencyMetrics } from "./input-latency";
import { ConnectionReconstruction, type SdkCore } from "./reconstruction";
import { DynamicKeyTracker, MessageKindOpcode, StateUpdateOpcode, classifyDecoded, decodeRaw, encodeMessageToMessagePack, encodeSyncAck, syncSeqOf } from "./protocol";
import { emptyActionOutcomes, injectedFailure, limitRejection, type ActionOutcome, type ActionOutcomeCounts } from "./action-outcomes";

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
    /** Stops reading the TCP socket (`ws`), so the server's send buffer fills (`--slow-read`). */
    pause?(): void;
    resume?(): void;
    /** Bytes read from the TCP socket so far (`ws`: its socket's `bytesRead`); tests set it. */
    bytesReceived?(): number;
}

/** Bytes `socket` has read from its TCP connection, or undefined when it can't tell. */
export function socketBytesReceived(socket: WebSocketLike | undefined): number | undefined {
    if (socket === undefined) return undefined;
    if (socket.bytesReceived) return socket.bytesReceived();
    const read = (socket as any)._socket?.bytesRead;
    return typeof read === "number" ? read : undefined;
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
    /**
     * `"stale"`: the client abandoned the connection after no frame from the server for
     * `--stale-after` (initiator `client`, but counted as a disconnect).
     */
    cause?: "stale";
    /** For a stale close: how long the connection had been silent, ms. */
    silentForMs?: number;
    /** A `--slow-read` connection: when it stopped and resumed reading (ms since epoch), if it did. */
    slowReader?: boolean;
    readPausedAt?: number;
    readResumedAt?: number;
    /**
     * `syncSequence` connections (#332): the in-place resyncs this connection received, the acks
     * it sent, and of those the ones sent while its reading was paused (`--slow-read`: the
     * unchanged last applied sequence, re-sent every second, keeps the server's acks fresh).
     */
    resyncs?: number;
    acksSent?: number;
    acksSentWhilePaused?: number;
    /** `syncSequence`: the last sequence this connection acked, and the last one it received. */
    lastAckedSeq?: number;
    lastReceivedSeq?: number;
}

/** A close the client didn't plan: any server-initiated close, and the client's own stale check. */
export function isDisconnect(record: CloseRecord): boolean {
    return record.initiator === "server" || record.cause === "stale";
}

/** `--reconnect on-server-close`: when and how a connection the server (or the stale check) closed is reopened. */
export interface ReconnectOption {
    /** No attempt starts at or after this time (ms since epoch). */
    untilAt: number;
    /** Wait before the first attempt, and between attempts (default 1000 ms). */
    delayMs?: number;
    /** An attempt that hasn't joined in this long is abandoned (default 5000 ms). */
    attemptTimeoutMs?: number;
}

/**
 * One reconnect: a joined connection was closed by the server or the stale check, and the client
 * opened a new connection with the same key and joined the same land. A new join, not a
 * resumption: the server assigns the player again.
 */
export interface ReconnectRecord {
    key: string;
    landInstanceId: string;
    playerId: string;
    /** What closed the old connection. */
    cause: "server" | "stale";
    closeCode?: number;
    closedAt: number;
    /** Attempts started, the last one included. */
    attempts: number;
    /**
     * `recovered`: joined and got a firstSync. `joinedNoFirstSync`: joined, but the connection
     * closed (or the run ended) before a firstSync. `gaveUp`: no attempt joined before `untilAt`.
     * `cancelled`: the tool closed the connection while it was reconnecting.
     */
    outcome: "recovered" | "joinedNoFirstSync" | "gaveUp" | "cancelled";
    /** The successful attempt: its start, socket open, join answer and first firstSync. */
    attemptStartedAt?: number;
    openedAt?: number;
    joinedAt?: number;
    firstSyncAt?: number;
    firstSyncBytes?: number;
    /** close → firstSync, attempt start → socket open, join → firstSync. */
    downtimeMs?: number;
    connectMs?: number;
    joinToFirstSyncMs?: number;
}

/** A state frame that is a firstSync (opcode or JSON), as classified by `classifyDecoded`. */
export function isFirstSync(decoded: any): boolean {
    return (
        decoded?.type === "stateUpdate" &&
        (decoded.opcode === StateUpdateOpcode.firstSync || decoded.updateType === "firstSync")
    );
}

/** A state frame that is an in-place resync (#332): a full view on the live connection. */
export function isResync(decoded: any): boolean {
    return (
        decoded?.type === "stateUpdate" &&
        (decoded.opcode === StateUpdateOpcode.resync || decoded.updateType === "resync")
    );
}

/** `--slow-read`: the window, in ms since epoch, in which a connection doesn't read its socket. */
export interface SlowReadWindow {
    startAt: number;
    endAt: number;
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

/**
 * How one socket ended (#490), for the `socket` samples record: a reconnect attempt's end
 * (`attempt*`: its join timed out, its socket closed, or its join was refused, and the tool
 * terminated it), a first join's (`join*`), a joined connection's close (`closed`), or the tool's
 * close of a connection that hadn't joined (`phaseEnd`).
 */
export type SocketEnd =
    | "attemptTimeout"
    | "attemptClosed"
    | "attemptRejected"
    | "joinTimeout"
    | "joinClosed"
    | "joinRejected"
    | "closed"
    | "phaseEnd";

/**
 * One socket, written once when it ends (#490). `localAddress` and `localPort` are the TCP
 * connection's local end, the server's peer address (`sessionOpened` in the server's lifecycle
 * log), so the analysis pairs each server session with the socket it was. Absent when the TCP
 * connection never completed, and for TLS (`wss:`), which keeps ws's own connect.
 * `connectedAt` is the TCP connect, `openedAt` the WebSocket open, `joinedAt` the JoinResponse.
 */
export interface SocketRecord {
    localPort?: number;
    /** The TCP connection's local address: with the port, the server's peer address. */
    localAddress?: string;
    connectedAt?: number;
    openedAt?: number;
    joinedAt?: number;
    endedAt: number;
    end: SocketEnd;
}

/** A socket's facts so far; `recorded` once its `socket` record is written. */
interface SocketTrack {
    localPort?: number;
    localAddress?: string;
    connectedAt?: number;
    openedAt?: number;
    joinedAt?: number;
    joinFailure?: JoinFailure["reason"];
    recorded: boolean;
}

/** The `SocketEnd` of a first join that failed for `reason`. */
function joinEnd(reason: JoinFailure["reason"]): SocketEnd {
    return reason === "timeout" ? "joinTimeout" : reason === "closed" ? "joinClosed" : "joinRejected";
}

/** The `SocketEnd` of a reconnect attempt that failed for `reason`. */
function attemptEnd(reason: JoinFailure["reason"]): SocketEnd {
    return reason === "timeout" ? "attemptTimeout" : reason === "closed" ? "attemptClosed" : "attemptRejected";
}

/** The process's sockets (#490): created, and those whose `socket` record is written. */
const socketCounts = { created: 0, recorded: 0 };

/** This process's socket counts so far: at shutdown, `created - recorded` were left without a record. */
export function processSocketCounts(): { created: number; recorded: number } {
    return { ...socketCounts };
}

export interface WorkerOptions {
    /**
     * Opens a socket to `url`. `onTcpConnect`, when the implementation can tell, is called once
     * with the TCP connection's local port as it connects (before the WebSocket opens); a test's
     * fake may call it or not.
     */
    createSocket?: (url: string, onTcpConnect?: (localPort: number | undefined, localAddress?: string) => void) => WebSocketLike;
    now?: () => number;
    /** How long a join may go unanswered before it counts as a `timeout` join failure. */
    joinTimeoutMs?: number;
    /** Time move events until a state frame shows their point (`input-latency`). Default false. */
    trackInputLatency?: boolean;
    /**
     * `--stale-after`: a joined connection with no frame from the server for this long is
     * abandoned by `checkStale`. Suspended while reading is paused. Unset: never.
     */
    staleAfterMs?: number;
    /** `--slow-read`: stop reading the socket during this window. */
    slowRead?: SlowReadWindow;
    /** `--samples-dir`: where this connection's raw samples go. */
    samples?: SampleWriter;
    /** `--reconnect on-server-close`; unset: a closed connection stays closed. */
    reconnect?: ReconnectOption;
    /** `--reconstruct`: rebuild each connection's client state with the SDK's view (`reconstruction`). */
    reconstruction?: { sdk: SdkCore; schema: unknown };
}

/** One connection's part of a convergence check (`--control-socket`, design § 6). */
export interface ConvergenceConnection {
    key: string;
    land: string;
    /** The connection's layout player (its slot). */
    player: string;
    /** The playerID the server's JoinResponse named, which the projection is fetched for. */
    serverPlayer?: string;
    /** Joined and open now. */
    open: boolean;
    /** Its current session came from a reconnect. */
    reconnected: boolean;
    decodeErrors: number;
    lastFrameAt?: number;
    /** The reconstructed state, normalised (`normalizeForConvergence`); absent when not open. */
    state?: unknown;
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

/**
 * The state-update features this client decodes (through the SDK's decoder, the same list as
 * its `SUPPORTED_STATE_UPDATE_FEATURES`), declared in every join's metadata: a server with a
 * feature on refuses a join that doesn't declare it.
 */
export const STATE_UPDATE_FEATURES: readonly string[] = ["pathIndex", "fieldMerge", "syncSequence"];

/** How often a connection with `syncSequence` acks its last applied sequence (the SDK's default). */
export const SYNC_ACK_INTERVAL_MS = 1000;

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
                // A template's own declaration wins (a run can test a server's refusal).
                metadata: { stateUpdateFeatures: [...STATE_UPDATE_FEATURES], ...metadata }
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
    /** Answered actions by outcome (`action-outcomes.ts`); injected failures and cap rejections aren't in `errorCount`. */
    actionOutcomes: ActionOutcomeCounts;
    /** RTTs of the applied actions only (a subset of `rttMs`, which has every answer's). */
    appliedRttMs: number[];
    /**
     * When each frame arrived that a real client could not decode (a dynamic key slot used
     * before its definition, #90, #191), before the client began to close. Any of these fails
     * the phase, wherever it falls: a #90-class error shows right after a join, in the ramp.
     */
    decodeErrorAt: number[];
    /** Decode errors after the client began to close: counted, not failed (#190). */
    decodeErrorsAfterLeave: number;
    /** The first such error, for the report. */
    firstDecodeError?: string;
    /** Closes the client did not ask for. */
    disconnectCount: number;
    /** In-place resyncs received (#332): state frames with opcode 3. */
    resyncCount: number;
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
    /** How plain state frames after a 107 frame were counted (`SYNC_FRAME_GROUP_MS`). */
    syncFrameGrouping: SyncFrameGrouping;
    /** Input-to-visible samples of move events (`input-latency`), by send time. */
    inputLatency: InputLatencyMetrics;
    closes: CloseRecord[];
    /** Reconnects that ended (any outcome) while this phase's metrics were current. */
    reconnects: ReconnectRecord[];
}

/**
 * Plain state frames that came right after an opcode-107 frame (no state frame between).
 * `grouped`: within `SYNC_FRAME_GROUP_MS`, counted as part of the 107 frame's sync.
 * `ungroupedAfterBroadcast`: later than that, counted as their own update. That is right for a
 * per-player-only sync (the server sends no 107 frame when the broadcast diff is empty and no
 * event is queued) and wrong for the per-player half of a sync delayed by a stalled event loop;
 * the frames carry no tick marker to tell them apart. A count that grows with load means the
 * update rate and sizes are distorted for a land with per-player fields.
 */
export interface SyncFrameGrouping {
    grouped: number;
    ungroupedAfterBroadcast: number;
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
        actionOutcomes: emptyActionOutcomes(),
        appliedRttMs: [],
        decodeErrorAt: [],
        decodeErrorsAfterLeave: 0,
        disconnectCount: 0,
        resyncCount: 0,
        actionsSent: 0,
        eventSentAt: {},
        updateBytes: [],
        permessageDeflate: { negotiated: 0, notNegotiated: 0 },
        syncFrameGrouping: { grouped: 0, ungroupedAfterBroadcast: 0 },
        inputLatency: emptyInputLatencyMetrics(),
        closes: [],
        reconnects: []
    };
}

/**
 * A plain state frame this soon after an opcode-107 frame, with no state frame between them, is
 * the per-player half of the same sync. With opcodeMessagePack a sync reaches a session as the
 * merged broadcast frame (107), its targeted event frames, then its per-player state frame
 * (`TransportAdapter.planSyncPhase`); both frames come from one write, so they arrive together.
 */
export const SYNC_FRAME_GROUP_MS = 10;

export class WorkerSession {
    private pendingRequests = new Map<string, number>();
    /** Requests a phase end forgot unanswered (`takePending`): a later answer still takes its outcome. */
    private forgottenRequests = new Set<string>();
    /** Raw samples (`--samples-dir`), with this connection's key and player; unset: none. */
    private samples?: { write: SampleWriter; key: string; player: string };
    /** Actual send time of each pending request, kept only for the raw samples. */
    private pendingSentAt = new Map<string, number>();
    private closedAt?: number;
    private lastStateUpdateAt?: number;
    /** The last state frame was a 107 frame: when it arrived, and where its size went (if recorded). */
    private openBroadcastFrame?: { at: number; bytesIndex?: number };
    public metrics: WorkerMetrics = emptyMetrics();
    /** Pending move events of this connection; writes into `metrics.inputLatency`. */
    readonly inputLatency = new InputLatencyTracker();

    /** A response slower than this (ms) is a late response (a timeout in the report). */
    constructor(private readonly lateAfterMs: number = RESPONSE_TIMEOUT_MS) {
        this.inputLatency.metrics = this.metrics.inputLatency;
    }

    /** Writes this connection's raw samples to `write`. */
    attachSamples(write: SampleWriter, key: string, player: string): void {
        this.samples = { write, key, player };
        this.inputLatency.onSample = (sentAt, seenAt, end) =>
            write(end === undefined ? { r: "input", k: key, sentAt, seenAt } : { r: "input", k: key, sentAt, seenAt, end });
    }

    recordReconnect(record: ReconnectRecord): void {
        this.metrics.reconnects.push(record);
        this.samples?.write({ r: "reconnect", k: this.samples.key, ...record });
    }

    /** A new connection for the same key: requests and the close of the old one are behind it. */
    noteReconnected(): void {
        this.closedAt = undefined;
    }

    /** `serverPlayer`: the playerID the server's JoinResponse names (its lifecycle log's). */
    sampleJoin(t: number, openedAt: number | undefined, land: string, serverPlayer?: string): void {
        this.samples?.write({ r: "join", k: this.samples.key, t, openedAt, land, player: this.samples.player, serverPlayer });
    }

    /**
     * Starts a new phase's metrics on a connection that stays open. The last update time carries
     * over, so an update interval spanning the boundary is counted in the phase it completes in.
     * The phase runner takes unanswered requests (`takePending`) before this.
     */
    resetMetrics(): void {
        this.metrics = emptyMetrics();
        this.inputLatency.metrics = this.metrics.inputLatency;
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
        if (this.samples) {
            this.pendingSentAt.set(requestID, actualAt);
        }
        this.metrics.actionsSent += 1;
        this.metrics.sentAt.push(actualAt);
        this.metrics.sendLagMs.push(actualAt - originAt);
    }

    /** `byteLength` is the frame's size on the wire, recorded for state updates. */
    handleDecodedMessage(message: any, now: number, byteLength?: number): void {
        if (message && typeof message === "object") {
            if (message.kind === "actionResponse") {
                const requestID = extractRequestID(message, "actionResponse");
                this.answer(requestID, now, "applied");
                return;
            }
            if (message.kind === "error") {
                const requestID = extractRequestID(message, "error");
                const code = message.code ?? message.payload?.error?.code;
                const text = message.message ?? message.payload?.error?.message;
                // An injected failure or a cap rejection is an outcome, not an error.
                const classified = injectedFailure(code, text) ?? limitRejection(code, text);
                const outcome: ActionOutcome = classified ?? "errored";
                if (typeof requestID === "string" && this.answer(requestID, now, outcome) && classified) {
                    return;
                }
                this.recordError(now);
                return;
            }
            if (message.type === "stateUpdateWithEvents") {
                const bytesIndex = this.recordStateUpdate(now, byteLength);
                this.openBroadcastFrame = { at: now, bytesIndex };
            } else if (message.type === "stateUpdate") {
                const open = this.openBroadcastFrame;
                this.openBroadcastFrame = undefined;
                // A full view (firstSync, or an in-place resync, #332) is its own update, tagged,
                // so its bytes can be told apart from the diffs' (never folded into a 107 frame's).
                const full = isFirstSync(message) ? "firstSync" : isResync(message) ? "resync" : undefined;
                if (full !== undefined) {
                    this.recordStateUpdate(now, byteLength, full);
                } else if (open && now - open.at <= SYNC_FRAME_GROUP_MS) {
                    // The per-player frame of the 107 frame's sync: one update, both frames' bytes.
                    this.metrics.syncFrameGrouping.grouped += 1;
                    if (open.bytesIndex !== undefined && byteLength !== undefined) {
                        this.metrics.updateBytes[open.bytesIndex] += byteLength;
                    }
                } else {
                    if (open) {
                        this.metrics.syncFrameGrouping.ungroupedAfterBroadcast += 1;
                    }
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
        if (this.samples) {
            const { write, key } = this.samples;
            for (const [requestID, intendedAt] of this.pendingRequests) {
                const sentAt = this.pendingSentAt.get(requestID) ?? intendedAt;
                write(
                    this.closedAt !== undefined
                        ? { r: "rtt", k: key, intendedAt, sentAt, respondedAt: null, end: "closed", closedAt: this.closedAt }
                        : { r: "rtt", k: key, intendedAt, sentAt, respondedAt: null, end: "phaseEnd" }
                );
            }
            this.pendingSentAt.clear();
        }
        for (const requestID of this.pendingRequests.keys()) this.forgottenRequests.add(requestID);
        this.pendingRequests.clear();
        return origins;
    }

    /** A frame this connection's client could not decode, at `now`; `leaving` once it began to close. */
    recordDecodeError(now: number, message: string, leaving = false): void {
        if (leaving) {
            this.metrics.decodeErrorsAfterLeave += 1;
            return;
        }
        this.metrics.decodeErrorAt.push(now);
        this.metrics.firstDecodeError ??= message;
    }

    /** An in-place resync (#332) on this session's connection `key`, at its arrival. */
    recordResync(t: number): void {
        this.samples?.write({ r: "resync", k: this.samples.key, t, player: this.samples.player });
    }

    /** One socket's end (#490): its `socket` samples record. */
    recordSocket(record: SocketRecord): void {
        this.samples?.write({ r: "socket", k: this.samples.key, ...record });
    }

    recordClose(record: CloseRecord): void {
        this.closedAt = record.t;
        this.samples?.write({ r: "close", player: this.samples.player, ...record });
        this.metrics.closes.push(record);
        if (isDisconnect(record)) {
            this.metrics.disconnectCount += 1;
        }
    }

    /**
     * The answer to `requestID`: true for the first answer of a request this session sent, which
     * then takes `outcome`. One pending in this phase records its RTT (and, applied, in
     * `appliedRttMs`). One a phase end forgot (`takePending`) is counted in
     * `answeredAfterPhaseEnd`, with no RTT. Any other answer (a second one, or to an unknown
     * request) is `unmatched`, and false.
     */
    private answer(requestID: string | undefined, now: number, outcome: ActionOutcome): boolean {
        if (this.recordRTT(requestID, now, outcome)) {
            this.metrics.actionOutcomes[outcome] += 1;
            return true;
        }
        if (requestID !== undefined && this.forgottenRequests.delete(requestID)) {
            this.metrics.actionOutcomes[outcome] += 1;
            this.metrics.actionOutcomes.answeredAfterPhaseEnd += 1;
            if (this.samples) this.samples.write({ r: "late", k: this.samples.key, respondedAt: now, outcome });
            return true;
        }
        this.metrics.actionOutcomes.unmatched += 1;
        return false;
    }

    /** Whether `requestID` was pending (its RTT is then recorded and it stops being pending). */
    private recordRTT(requestID: string | undefined, now: number, outcome?: ActionOutcome): boolean {
        if (!requestID) {
            return false;
        }
        const sentAt = this.pendingRequests.get(requestID);
        if (sentAt === undefined) {
            return false;
        }
        this.metrics.rttMs.push(now - sentAt);
        this.metrics.rttAt.push(now);
        if (outcome === "applied") {
            this.metrics.appliedRttMs.push(now - sentAt);
        }
        if (now - sentAt > this.lateAfterMs) {
            this.metrics.lateResponseOrigins.push(sentAt);
        }
        this.pendingRequests.delete(requestID);
        if (this.samples) {
            const actual = this.pendingSentAt.get(requestID) ?? sentAt;
            this.pendingSentAt.delete(requestID);
            this.samples.write(
                outcome === undefined
                    ? { r: "rtt", k: this.samples.key, intendedAt: sentAt, sentAt: actual, respondedAt: now }
                    : { r: "rtt", k: this.samples.key, intendedAt: sentAt, sentAt: actual, respondedAt: now, outcome }
            );
        }
        return true;
    }

    /** Records one update (one sync); returns the index of its size in `updateBytes`, if recorded. */
    private recordStateUpdate(now: number, byteLength: number | undefined, full?: "firstSync" | "resync"): number | undefined {
        let bytesIndex: number | undefined;
        if (this.samples) {
            const gapMs = this.lastStateUpdateAt === undefined ? null : now - this.lastStateUpdateAt;
            const line: SampleRecord =
                byteLength === undefined
                    ? { r: "update", k: this.samples.key, t: now, gapMs }
                    : { r: "update", k: this.samples.key, t: now, gapMs, bytes: byteLength };
            if (full !== undefined && line.r === "update") line.full = full;
            this.samples.write(line);
        }
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
    /** The land the connection tried to join (a per-land count of failed joins needs it). */
    land: string;
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
    private readonly joinedCallbacks = new Set<(at: number) => void>();
    private joinedAt?: number;
    /** When the socket opened (the join request goes out right after). */
    private openedAt?: number;
    private joinLatencyReported = false;
    /** The JoinResponse's encoding and `stateUpdateFeatures` as a key (`joinFeaturesKey`), set on each join. */
    private joinFeatures: string | undefined;
    private joinFeaturesReported = false;
    private closedAt?: number;
    private joinFailure?: JoinFailure;
    private joinFailureReported = false;
    private joinTimer?: ReturnType<typeof setTimeout>;
    private readonly joinTimeoutMs: number;
    private readonly session = new WorkerSession();
    /** This connection's dynamic key tables, as its client would hold them. */
    private keyTracker = new DynamicKeyTracker();
    private readonly now: () => number;
    private readonly createSocket: (url: string, onTcpConnect?: (localPort: number | undefined, localAddress?: string) => void) => WebSocketLike;
    /** The current socket's facts for its `socket` record (#490); a new one per `connect()`. */
    private socketTrack?: SocketTrack;
    private readonly trackInputLatency: boolean;
    private readonly staleAfterMs?: number;
    private readonly slowRead?: SlowReadWindow;
    /** Last frame from the server, or when the stale timer last (re)started. */
    private lastFrameAt?: number;
    /** `syncSequence` negotiated for this join (#332): frames carry a sequence, acks go out. */
    private syncSequence = false;
    private lastAppliedSeq?: number;
    private ackTimer?: ReturnType<typeof setInterval>;
    /** In-place resyncs received (#332), over every join of this client. */
    resyncCount = 0;
    /** This connection's resyncs and acks (#332), reset for each new connection. */
    private connectionResyncs = 0;
    private acksSent = 0;
    private acksSentWhilePaused = 0;
    private lastAckedSeq?: number;
    private lastReceivedSeq?: number;
    private readPaused = false;
    /** `--slow-read`: the socket's bytes at the last stale check (bytes arriving aren't silence). */
    private lastBytesReceived?: number;
    private readPausedAt?: number;
    private readResumedAt?: number;
    private slowReadTimers: Array<ReturnType<typeof setTimeout>> = [];
    private staleSilentForMs?: number;
    private readonly reconnectOption?: ReconnectOption;
    private readonly reconstructionOption?: { sdk: SdkCore; schema: unknown };
    /** This connection's reconstructed client state; a new one per socket. */
    private reconstruction?: ConnectionReconstruction;
    private serverPlayer?: string;
    private rejoined = false;
    private everJoined = false;
    /** The reconnect in progress: its record so far, and whether an attempt's socket is open. */
    private reconnecting?: { record: Omit<ReconnectRecord, "outcome">; inAttempt: boolean; awaitingFirstSync: boolean };
    private reconnectTimer?: ReturnType<typeof setTimeout>;
    /** Joined spans, `[joinedAt, closedAt]`; the last is open while joined. */
    private joinedSpans: Array<[number, number | undefined]> = [];

    constructor(private readonly config: WorkerConfig, options: WorkerOptions = {}) {
        this.now = options.now ?? (() => Date.now());
        this.joinTimeoutMs = options.joinTimeoutMs ?? RESPONSE_TIMEOUT_MS;
        this.trackInputLatency = options.trackInputLatency ?? false;
        this.staleAfterMs = options.staleAfterMs;
        this.slowRead = options.slowRead;
        this.reconnectOption = options.reconnect;
        this.reconstructionOption = options.reconstruction;
        if (options.samples) {
            this.session.attachSamples(options.samples, this.getKey(), config.playerId);
        }
        this.createSocket =
            options.createSocket ??
            ((url: string, onTcpConnect?: (localPort: number | undefined, localAddress?: string) => void) => {
                const { WebSocket } = require("ws");
                // TLS (wss:, and https:, which ws maps to wss) keeps ws's own connect: its sockets'
                // records have no localPort. The measurement topics connect over ws:.
                const protocol = new URL(url).protocol;
                if (protocol === "wss:" || protocol === "https:") {
                    return new WebSocket(url);
                }
                const net = require("node:net");
                // ws's own `netConnect`, with the TCP connect's local port reported (#490).
                return new WebSocket(url, {
                    createConnection: (opts: any) => {
                        opts.path = opts.socketPath;
                        const tcp = net.connect(opts);
                        tcp.once("connect", () => onTcpConnect?.(tcp.localPort, tcp.localAddress));
                        return tcp;
                    }
                });
            });
    }

    /**
     * Writes `track`'s `socket` record once (#490): `failAttempt` and `finishClose` can both reach
     * one socket, and the first end is the one recorded.
     */
    private endSocket(track: SocketTrack | undefined, end: SocketEnd): void {
        if (!track || track.recorded) {
            return;
        }
        track.recorded = true;
        socketCounts.recorded += 1;
        const record: SocketRecord = { endedAt: this.now(), end };
        if (track.localPort !== undefined) record.localPort = track.localPort;
        if (track.localAddress !== undefined) record.localAddress = track.localAddress;
        if (track.connectedAt !== undefined) record.connectedAt = track.connectedAt;
        if (track.openedAt !== undefined) record.openedAt = track.openedAt;
        if (track.joinedAt !== undefined) record.joinedAt = track.joinedAt;
        this.session.recordSocket(record);
    }

    connect(): void {
        // A new connection: the server's key tables for it start empty, so do the client's.
        this.keyTracker = new DynamicKeyTracker();
        if (this.reconstructionOption) {
            const { sdk, schema } = this.reconstructionOption;
            this.reconstruction = new ConnectionReconstruction(sdk, schema, `${this.config.landType}:${this.config.landInstanceId}`);
        }
        const track: SocketTrack = { recorded: false };
        this.socketTrack = track;
        socketCounts.created += 1;
        const socket = this.createSocket(this.config.serverUrl, (localPort, localAddress) => {
            track.localPort = localPort;
            track.localAddress = localAddress;
            track.connectedAt = this.now();
        });
        this.socket = socket;
        const timeoutMs = this.reconnecting ? this.reconnectOption?.attemptTimeoutMs ?? 5000 : this.joinTimeoutMs;
        this.joinTimer = setTimeout(() => {
            this.joinTimer = undefined;
            this.recordJoinFailure("timeout", undefined, `no join response within ${timeoutMs} ms`);
        }, timeoutMs);
        (this.joinTimer as any).unref?.();
        // Events of an earlier socket (a reconnect replaced it) are ignored.
        const current = () => this.socket === socket;
        socket.on("open", () => {
            if (!current()) return;
            this.openedAt = this.now();
            track.openedAt = this.openedAt;
            this.session.recordOpen(socket.extensions);
            this.sendJoin();
        });
        socket.on("message", (data) => {
            if (!current()) return;
            this.handleMessage(data);
        });
        socket.on("close", (code?: number, reason?: unknown) => {
            if (!current()) return;
            this.finishClose(code, reason, false);
        });
        socket.on("error", () => {
            if (!current()) return;
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

    /**
     * Calls `callback` with the join time on every join, a reconnect's included (right away if
     * joined now). Returns a function that removes it.
     */
    onJoined(callback: (at: number) => void): () => void {
        this.joinedCallbacks.add(callback);
        if (this.joined) {
            callback(this.now());
        }
        return () => {
            this.joinedCallbacks.delete(callback);
        };
    }

    /** Drops the join callbacks (the phase that registered them ended). */
    clearJoinedCallbacks(): void {
        this.joinedCallbacks.clear();
    }

    /** `[start, end)` while this connection was joined and open, clipped to `[from, to)`. */
    activeIntervals(from: number, to: number): Array<[number, number]> {
        const intervals: Array<[number, number]> = [];
        for (const [joinedAt, closedAt] of this.joinedSpans) {
            const start = Math.max(from, joinedAt);
            const end = Math.min(to, closedAt ?? to);
            if (end > start) {
                intervals.push([start, end]);
            }
        }
        return intervals;
    }

    /** A reconnect is waiting for its next attempt or has an attempt's socket open. */
    isReconnecting(): boolean {
        return this.reconnecting !== undefined && !this.reconnecting.awaitingFirstSync;
    }

    /**
     * Joined, open and not closing: can be kept for the next phase. A connection that didn't join
     * (refused, unanswered or still pending) is closed at the transition, and the next phase opens
     * a new one that joins again.
     */
    isUsable(): boolean {
        return this.joined && this.socket !== undefined && !this.closed && !this.closeRequested;
    }

    /** This connection's convergence report; `withState` adds its normalised state when open. */
    convergenceReport(withState: boolean): ConvergenceConnection {
        const open = this.isUsable();
        return {
            key: this.getKey(),
            land: this.config.landInstanceId,
            player: this.config.playerId,
            serverPlayer: this.serverPlayer,
            open,
            reconnected: this.rejoined,
            decodeErrors: this.reconstruction?.decodeErrors ?? 0,
            lastFrameAt: this.reconstruction?.lastFrameAt,
            state: withState && open ? this.reconstruction?.normalizedState() : undefined
        };
    }

    getLandInstanceId(): string {
        return this.config.landInstanceId;
    }

    /** Whether this connection rebuilds its client state (`--reconstruct`, within `--reconstruct-slots`). */
    reconstructs(): boolean {
        return this.reconstructionOption !== undefined;
    }

    getKey(): string {
        return this.config.key ?? this.config.landInstanceId;
    }

    /**
     * Closes with a close frame and resolves when the close handshake ends. If it doesn't end
     * within `timeoutMs`, the socket is terminated and the record is marked `forced`.
     */
    close(reason: string, timeoutMs = CLIENT_CLOSE_TIMEOUT_MS): Promise<void> {
        this.cancelReconnect();
        if (!this.socket || this.closed) {
            return Promise.resolve();
        }
        // A paused reader couldn't see the server's close frame, so the handshake would time out.
        this.resumeReading();
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
        const now = this.now();
        (sentAt[eventName] ??= []).push(now);
        const point = this.trackInputLatency ? echoPointOf(payload) : undefined;
        if (point) {
            this.session.inputLatency.recordSent(point, now);
        }
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
        this.cancelReconnect();
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
        this.stopAcks();
        if (this.reconnecting?.inAttempt && !this.joined && !this.closeRequested) {
            // An attempt that closed before joining isn't a connection: no close record.
            this.failAttempt("attemptClosed");
            return;
        }
        this.closed = true;
        this.closedAt = this.now();
        this.clearJoinTimer();
        this.slowReadTimers.forEach((timer) => clearTimeout(timer));
        this.slowReadTimers = [];
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
        if (this.staleSilentForMs !== undefined) {
            record.cause = "stale";
            record.silentForMs = this.staleSilentForMs;
        }
        // Move events still pending: the client closed them, or the server (or the stale check) did.
        this.session.inputLatency.drainOnClose(
            this.closeRequested && this.staleSilentForMs === undefined ? "pendingAtEnd" : "closedBeforeSeen"
        );
        if (this.slowRead) {
            record.slowReader = true;
            record.readPausedAt = this.readPausedAt;
            record.readResumedAt = this.readResumedAt;
        }
        if (this.syncSequence) {
            record.resyncs = this.connectionResyncs;
            record.acksSent = this.acksSent;
            record.acksSentWhilePaused = this.acksSentWhilePaused;
            record.lastAckedSeq = this.lastAckedSeq;
            record.lastReceivedSeq = this.lastReceivedSeq;
        }
        this.session.recordClose(record);
        const track = this.socketTrack;
        this.endSocket(
            track,
            this.joined ? "closed" : track?.joinFailure !== undefined ? joinEnd(track.joinFailure) : this.closeRequested ? "phaseEnd" : "joinClosed"
        );
        const span = this.joinedSpans[this.joinedSpans.length - 1];
        if (span && span[1] === undefined) {
            span[1] = record.t;
        }
        if (this.reconnecting?.awaitingFirstSync) {
            this.finishReconnect("joinedNoFirstSync");
        }
        // A close the tool asked for isn't a disconnect, so it never starts a reconnect.
        if (this.reconnectOption && this.everJoined && isDisconnect(record)) {
            this.reconnecting = {
                record: {
                    key: this.getKey(),
                    landInstanceId: this.config.landInstanceId,
                    playerId: this.config.playerId,
                    cause: record.cause === "stale" ? "stale" : "server",
                    closeCode: record.code,
                    closedAt: record.t,
                    attempts: 0
                },
                inAttempt: false,
                awaitingFirstSync: false
            };
            this.scheduleAttempt();
        }
        const waiters = this.closeWaiters;
        this.closeWaiters = [];
        waiters.forEach((resolve) => resolve());
    }

    /**
     * The stale check (`staleAfterMs`): a joined, open connection that is reading and has had no
     * frame from the server for `staleAfterMs` is terminated and closed with cause `stale`.
     * Returns whether it was. The worker calls this for every client on a short interval.
     */
    checkStale(now: number = this.now()): boolean {
        if (
            this.staleAfterMs === undefined ||
            !this.joined ||
            this.closed ||
            this.closeRequested ||
            this.readPaused ||
            this.lastFrameAt === undefined
        ) {
            return false;
        }
        // `--slow-read` only: silence is measured by bytes on the socket, not by handled frames.
        // A slow reader that resumed drains its backlog slower than it arrives; bytes still
        // arriving mean the server is sending, so the connection isn't silent.
        if (this.slowRead) {
            const bytes = socketBytesReceived(this.socket);
            if (bytes !== undefined && bytes !== this.lastBytesReceived) {
                if (this.lastBytesReceived !== undefined) this.lastFrameAt = Math.max(this.lastFrameAt, now);
                this.lastBytesReceived = bytes;
            }
        }
        const silentForMs = now - this.lastFrameAt;
        if (silentForMs < this.staleAfterMs) {
            return false;
        }
        this.staleSilentForMs = silentForMs;
        // Client-initiated, so a late close event from the socket isn't a server close.
        this.closeRequested = true;
        this.socket?.terminate?.();
        this.finishClose(undefined, "stale", false);
        return true;
    }

    /** Reading is paused (`--slow-read`). */
    isReadPaused(): boolean {
        return this.readPaused;
    }

    /** Once joined: pause reading for the slow-read window, or for what is left of it. */
    private scheduleSlowRead(): void {
        if (!this.slowRead || this.readPausedAt !== undefined) {
            return;
        }
        const now = this.now();
        if (now >= this.slowRead.endAt) {
            return;
        }
        const pause = setTimeout(() => this.pauseReading(), Math.max(0, this.slowRead.startAt - now));
        const resume = setTimeout(() => this.resumeReading(), this.slowRead.endAt - now);
        (pause as any).unref?.();
        (resume as any).unref?.();
        this.slowReadTimers.push(pause, resume);
    }

    private pauseReading(): void {
        if (this.closed || this.closeRequested || this.readPaused || !this.socket) {
            return;
        }
        this.readPaused = true;
        this.readPausedAt = this.now();
        this.socket.pause?.();
    }

    private resumeReading(): void {
        if (!this.readPaused) {
            return;
        }
        this.readPaused = false;
        this.readResumedAt = this.now();
        // The stale timer restarts: the pause's silence was the client's own doing.
        this.lastFrameAt = this.readResumedAt;
        this.socket?.resume?.();
    }

    /** The next attempt after `delayMs`, unless it would start at or after `untilAt`. */
    private scheduleAttempt(): void {
        const option = this.reconnectOption!;
        const startAt = this.now() + (option.delayMs ?? 1000);
        if (startAt >= option.untilAt) {
            this.finishReconnect("gaveUp");
            return;
        }
        this.reconnectTimer = setTimeout(() => {
            this.reconnectTimer = undefined;
            this.startAttempt();
        }, startAt - this.now());
        (this.reconnectTimer as any).unref?.();
    }

    /** A new connection with the same key: per-socket state starts over. */
    private startAttempt(): void {
        if (!this.reconnecting) {
            return;
        }
        this.closed = false;
        this.joined = false;
        this.joinFailure = undefined;
        this.closeRequested = false;
        this.abrupt = false;
        this.staleSilentForMs = undefined;
        this.openedAt = undefined;
        this.lastFrameAt = undefined;
        this.readPaused = false;
        // `--slow-read`: the new connection pauses for what is left of the window (scheduleSlowRead).
        this.readPausedAt = undefined;
        this.readResumedAt = undefined;
        this.connectionResyncs = 0;
        this.acksSent = 0;
        this.acksSentWhilePaused = 0;
        this.lastAckedSeq = undefined;
        this.lastReceivedSeq = undefined;
        this.lastBytesReceived = undefined;
        this.session.noteReconnected();
        this.reconnecting.record.attempts += 1;
        this.reconnecting.record.attemptStartedAt = this.now();
        this.reconnecting.inAttempt = true;
        this.connect();
    }

    /** The attempt's socket is dropped without a close record, and the next one is scheduled. */
    private failAttempt(end: SocketEnd): void {
        this.clearJoinTimer();
        this.endSocket(this.socketTrack, end);
        const socket = this.socket;
        this.closed = true;
        this.reconnecting!.inAttempt = false;
        // Detach first, so its late events are ignored.
        this.socket = undefined;
        socket?.terminate?.();
        this.scheduleAttempt();
    }

    private finishReconnect(outcome: ReconnectRecord["outcome"]): void {
        const pending = this.reconnecting;
        if (!pending) {
            return;
        }
        this.reconnecting = undefined;
        const record: ReconnectRecord = { ...pending.record, outcome };
        if (outcome === "recovered" || outcome === "joinedNoFirstSync") {
            if (record.openedAt !== undefined && record.attemptStartedAt !== undefined) {
                record.connectMs = record.openedAt - record.attemptStartedAt;
            }
        } else {
            // No joined attempt: its last attempt's start says nothing.
            delete record.attemptStartedAt;
        }
        if (record.firstSyncAt !== undefined) {
            record.downtimeMs = record.firstSyncAt - record.closedAt;
            record.joinToFirstSyncMs = record.firstSyncAt - record.joinedAt!;
        }
        this.session.recordReconnect(record);
    }

    /** The tool is closing this connection: no more attempts. */
    private cancelReconnect(): void {
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = undefined;
        }
        if (this.reconnecting && !this.reconnecting.awaitingFirstSync) {
            const inAttempt = this.reconnecting.inAttempt;
            this.finishReconnect("cancelled");
            if (inAttempt) {
                // The attempt's socket hasn't joined: drop it without a close record, with its
                // one socket record (#490): the tool closed it while it was still joining.
                this.endSocket(this.socketTrack, "phaseEnd");
                this.clearJoinTimer();
                const socket = this.socket;
                this.socket = undefined;
                this.closed = true;
                socket?.terminate?.();
            }
        }
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
        // The frame's arrival, taken before any of this client's own work on it (the
        // reconstruction's feed, the decode, the key tracker): the time the input-to-visible
        // match, the reconnect's first sync and the message timings use, so a connection that
        // reconstructs (--reconstruct-slots) and one that doesn't are timed alike.
        const arrivedAt = this.now();
        this.lastFrameAt = arrivedAt;
        this.reconstruction?.feed(data);
        const raw = decodeRaw(data);
        const errorsBefore = this.keyTracker.errors;
        this.keyTracker.observe(raw);
        if (this.keyTracker.errors > errorsBefore) {
            this.session.recordDecodeError(this.now(), this.keyTracker.firstError ?? "decode error", this.closeRequested || this.closed);
        }
        const decoded = classifyDecoded(raw);
        if (decoded && decoded.kind === "joinResponse") {
            const success = decoded.success ?? decoded.payload?.joinResponse?.success;
            if (!success && !this.joined) {
                const response = decoded.payload?.joinResponse ?? decoded;
                this.recordJoinFailure("rejected", undefined, response?.reason ?? response?.message);
            }
            if (success) {
                const serverPlayer = decoded.playerID ?? decoded.payload?.joinResponse?.playerID;
                if (!this.joined && !this.joinFailure) {
                    this.clearJoinTimer();
                    this.joined = true;
                    this.everJoined = true;
                    this.joinedAt = this.now();
                    if (this.socketTrack) this.socketTrack.joinedAt = this.joinedAt;
                    this.joinedSpans.push([this.joinedAt, undefined]);
                    this.lastFrameAt = this.joinedAt;
                    this.serverPlayer = typeof serverPlayer === "string" ? serverPlayer : undefined;
                    this.joinFeatures = joinFeaturesKey(
                        decoded.stateUpdateFeatures ?? decoded.payload?.joinResponse?.stateUpdateFeatures,
                        decoded.encoding ?? decoded.payload?.joinResponse?.encoding
                    );
                    this.joinFeaturesReported = false;
                    const features = decoded.stateUpdateFeatures ?? decoded.payload?.joinResponse?.stateUpdateFeatures;
                    this.startAcks(Array.isArray(features) && features.includes("syncSequence"));
                    this.rejoined = this.reconnecting?.inAttempt === true;
                    if (this.reconnecting?.inAttempt) {
                        this.reconnecting.inAttempt = false;
                        this.reconnecting.awaitingFirstSync = true;
                        this.reconnecting.record.openedAt = this.openedAt;
                        this.reconnecting.record.joinedAt = this.joinedAt;
                    }
                    this.session.sampleJoin(
                        this.joinedAt,
                        this.openedAt,
                        this.config.landInstanceId,
                        typeof serverPlayer === "string" ? serverPlayer : undefined
                    );
                    this.scheduleSlowRead();
                    const at = this.now();
                    [...this.joinedCallbacks].forEach((callback) => callback(at));
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
        const now = arrivedAt;
        if (this.syncSequence) {
            const seq = syncSeqOf(raw);
            if (seq !== undefined) {
                this.lastAppliedSeq = seq;
                this.lastReceivedSeq = seq;
                const resync = isResync(decoded);
                if (resync) {
                    this.resyncCount += 1;
                    this.connectionResyncs += 1;
                    this.session.metrics.resyncCount += 1;
                    this.session.recordResync(now);
                }
                // A full view is acked at once: the server exempts it from the lag rule until then.
                if (resync || isFirstSync(decoded)) this.sendAck();
            }
        }
        if (this.reconnecting?.awaitingFirstSync && isFirstSync(decoded)) {
            this.reconnecting.record.firstSyncAt = now;
            this.reconnecting.record.firstSyncBytes = frameByteLength(data);
            this.finishReconnect("recovered");
        }
        if (decoded && (decoded.type === "stateUpdate" || decoded.type === "stateUpdateWithEvents")) {
            this.session.inputLatency.observe(raw, now);
        }
        this.session.handleDecodedMessage(decoded, now, frameByteLength(data));
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

    /** Starts (or stops) the ack timer for a join; each join starts from no applied sequence. */
    private startAcks(syncSequence: boolean): void {
        this.stopAcks();
        this.syncSequence = syncSequence;
        if (!syncSequence) return;
        // Acks keep their value while the socket isn't read (`--slow-read`): a slow reader.
        this.ackTimer = setInterval(() => this.sendAck(), SYNC_ACK_INTERVAL_MS);
        (this.ackTimer as any).unref?.();
    }

    private stopAcks(): void {
        if (this.ackTimer !== undefined) {
            clearInterval(this.ackTimer);
            this.ackTimer = undefined;
        }
        this.lastAppliedSeq = undefined;
    }

    private sendAck(): void {
        if (this.lastAppliedSeq === undefined || this.socket === undefined || this.closed) return;
        try {
            this.socket.send(encodeSyncAck(this.lastAppliedSeq, this.messageEncoding === "messagepack"));
            this.acksSent += 1;
            this.lastAckedSeq = this.lastAppliedSeq;
            if (this.readPaused) this.acksSentWhilePaused += 1;
        } catch {
            // A closing socket: the close handler stops the timer.
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
        if (this.reconnecting?.inAttempt) {
            // A failed attempt is the reconnect's, not a join failure of the phase.
            this.failAttempt(attemptEnd(reason));
            return;
        }
        // The socket stays open until the phase closes it; its record names this failure.
        if (this.socketTrack) this.socketTrack.joinFailure ??= reason;
        this.clearJoinTimer();
        this.joinFailure = {
            t: this.now(),
            reason,
            code: code === undefined ? undefined : String(code),
            message: message === undefined ? undefined : String(message),
            land: this.config.landInstanceId
        };
    }

    /** The join failure not yet reported, if any; each failure is returned once. */
    /**
     * Socket open to the successful JoinResponse, ms, once per connection: a connection kept
     * for the next phase reports its join only in the phase that opened it.
     */
    takeJoinLatency(): number | undefined {
        if (this.joinLatencyReported || this.joinedAt === undefined || this.openedAt === undefined) {
            return undefined;
        }
        this.joinLatencyReported = true;
        return this.joinedAt - this.openedAt;
    }

    /**
     * The wire form the server's JoinResponse named for this connection, its encoding and
     * state-update features (`joinFeaturesKey`), once per join: a rejoin reports its own.
     */
    takeJoinFeatures(): string | undefined {
        if (this.joinFeaturesReported || this.joinFeatures === undefined) {
            return undefined;
        }
        this.joinFeaturesReported = true;
        return this.joinFeatures;
    }

    takeJoinFailure(): JoinFailure | undefined {
        if (!this.joinFailure || this.joinFailureReported) {
            return undefined;
        }
        this.joinFailureReported = true;
        return this.joinFailure;
    }
}

/**
 * The JoinResponse's wire form as one key, `<encoding>:<features>`, so a report can count
 * connections per wire form: the encoding it named ("unknown" when it named none), and its
 * `stateUpdateFeatures` sorted and joined with ",", "none" for an empty or absent list. E.g.
 * "messagepack:fieldMerge,pathIndex", "json:none".
 *
 * An absent list is "none", the same as an empty one, on purpose: the server never sends an empty
 * list. TransportAdapter's joinResponse sets `stateUpdateFeatures` to nil when no feature is on,
 * and the opcode encoders drop trailing nils, so a server with every feature off sends no field.
 * "Not recorded" is a report without `phaseTotals.stateUpdateFeatures` at all (an older client).
 */
export function joinFeaturesKey(features: unknown, encoding?: unknown): string {
    const names = Array.isArray(features) ? features.filter((f): f is string => typeof f === "string").sort() : [];
    const form = typeof encoding === "string" && encoding.length > 0 ? encoding : "unknown";
    return `${form}:${names.length > 0 ? names.join(",") : "none"}`;
}

/**
 * The reconstruction a connection gets: the worker's (`--reconstruct`), unless `--reconstruct-slots`
 * left this connection out (`spec.reconstruct === false`). Without that option no spec carries the
 * flag, so every connection reconstructs, as before it existed.
 */
export function reconstructionFor<R>(spec: { reconstruct?: boolean }, reconstruction: R | undefined): R | undefined {
    return spec.reconstruct === false ? undefined : reconstruction;
}

/**
 * The control channel's listing of a worker's connections for the convergence check: only the
 * ones that reconstruct (every one without `--reconstruct-slots`), optionally only in `only`'s
 * lands, each with its normalised state when its land is in `withStates`.
 */
export function convergenceListing(
    clients: Iterable<WorkerClient>,
    withStates: Set<string>,
    only?: Set<string>
): ConvergenceConnection[] {
    return [...clients]
        .filter((client) => client.reconstructs())
        .filter((client) => !only || only.has(client.getLandInstanceId()))
        .map((client) => client.convergenceReport(withStates.has(client.getLandInstanceId())));
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
