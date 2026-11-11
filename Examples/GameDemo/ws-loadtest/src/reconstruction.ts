import fs from "node:fs";
import path from "node:path";

/**
 * Per-connection client state, rebuilt with the TypeScript SDK's state view, for the
 * convergence check of the network impairment runs (design § 6). Each connection feeds every
 * frame it receives to its own `StateTreeView`, decoded by the SDK's `decodeMessage` with the
 * connection's own dynamic key maps and routed as `StateTreeRuntime.handleMessage` routes it.
 * The tool's own decode (`protocol.ts`) stays as it is for the metrics, so a frame is decoded
 * twice; that cost is part of every run that reconstructs, P0 included.
 */

/** The parts of the SDK's `StateTreeView` used here. */
export interface StateViewLike {
    handleTransportMessage(message: unknown): void;
    handleStateUpdate(update: unknown): void;
    handleSnapshot(snapshot: unknown): void;
    getState(): Record<string, unknown>;
}

export interface ConvergenceDifference {
    path: string;
    client: unknown;
    server: unknown;
}

/** The parts of the SDK's core module used by the reconstruction and the coordinator. */
export interface SdkCore {
    StateTreeView: new (runtime: unknown, landID: string, options: Record<string, unknown>) => StateViewLike;
    decodeMessage(data: string | ArrayBuffer | Uint8Array, config: unknown, dynamicKeyMap: unknown): any;
    normalizeForConvergence(value: unknown): unknown;
    compareStates(client: unknown, server: unknown): ConvergenceDifference[];
    /** The SDK's protocol debug logger; `undefined` restores the default, which writes nothing. */
    setProtocolLogger(logger: unknown): void;
    /** The state-update features the SDK decodes. */
    SUPPORTED_STATE_UPDATE_FEATURES: string[];
    /** A land's path index table (its sorted, de-duplicated path hashes). */
    pathIndexTableFor(pathHashes: Record<string, number>): number[];
    /** A connection's row tables (`rowAddressing`), passed to `decodeMessage` with the key maps. */
    RowTables: new () => { clear(): void };
    /** Which patches of a frame at a resync's sequence apply (the runtime's rule). */
    ResyncSkip: new () => ResyncSkipLike;
    /** What the decoder throws for a row entry that breaks the strict rules. */
    RowEntryProtocolError: new (...args: any[]) => Error & { rule: string };
    /** The row-derived patch indices of a decoded update. */
    rowPatchIndicesOf(update: unknown): readonly number[];
}

export interface ResyncSkipLike {
    filter(update: any, rows?: { tables: unknown; pathPatterns?: ReadonlyMap<number, string> }): any | undefined;
    noteApplied(update: any, rows?: { tables: unknown; pathPatterns?: ReadonlyMap<number, string> }): void;
}

let sdkCore: Promise<SdkCore> | undefined;

/**
 * Loads the SDK's core once per process. The SDK is ESM whose `core` index re-exports without
 * file extensions, which Node can't resolve, so `npm run build` bundles it into
 * `dist/sdk-core.cjs` (`scripts/bundle-sdk.mjs`). Under vitest or tsx, where `src/` runs and
 * the bundler resolves the index, it is imported directly.
 */
export function loadSdkCore(): Promise<SdkCore> {
    sdkCore ??= (async () => {
        const bundled = path.join(__dirname, "sdk-core.cjs");
        if (fs.existsSync(bundled)) {
            // eslint-disable-next-line @typescript-eslint/no-var-requires
            return require(bundled) as SdkCore;
        }
        return (await import("@swiftstatetree/sdk/core")) as unknown as SdkCore;
    })();
    return sdkCore;
}

export type MessageEncoding = "json" | "opcodeJsonArray" | "messagepack";

export interface TransportEncodingConfig {
    message: MessageEncoding;
    stateUpdate: "jsonObject" | "opcodeJsonArray";
    stateUpdateDecoding: "auto" | "jsonObject" | "opcodeJsonArray";
    /** The state-update features in use (`joinResponse.stateUpdateFeatures`). */
    stateUpdateFeatures?: string[];
    /** The joined land's path index table, with the path index feature. */
    pathIndexTable?: readonly number[];
    /** The joined land's hash → pattern lookup. */
    pathPatterns?: ReadonlyMap<number, string>;
}

/** `StateTreeRuntime`'s default before a join response names the encoding. */
const DEFAULT_ENCODING: TransportEncodingConfig = {
    message: "json",
    stateUpdate: "opcodeJsonArray",
    stateUpdateDecoding: "auto"
};

export interface ReconstructionOptions {
    playerID?: string;
    now?: () => number;
    /** The encoding from the first frame, for a stream without a join response (default: the runtime's). */
    encoding?: TransportEncodingConfig;
    /**
     * A row entry broke the strict rules (or came without `rowAddressing`): the SDK's runtime
     * closes the connection with 4013 here. Called once; later frames are not applied.
     */
    onRowEntryViolation?: (rule: string) => void;
}

/** One connection's reconstructed client state. A reconnect starts a new one. */
export class ConnectionReconstruction {
    readonly view: StateViewLike;
    /** Frames the SDK could not decode (it throws; the runtime logs and counts them). */
    decodeErrors = 0;
    firstError: string | undefined;
    /** The strict rule a row entry broke (the SDK's 4013 close); later frames are dropped. */
    rowEntryViolation: string | undefined;
    /** Frames dropped after `rowEntryViolation`, as the runtime's `droppedAfterStrictClose`. */
    droppedAfterRowEntryViolation = 0;
    /** Patches from row entries applied to the view. */
    rowPatchesApplied = 0;
    /** When the connection last received a frame, ms since epoch: any frame, decoded or not,
     * since a snapshot or an undecodable frame is still traffic the quiet window must wait out. */
    lastFrameAt: number | undefined;
    private encoding: TransportEncodingConfig = { ...DEFAULT_ENCODING };
    // Cleared per connection, as the runtime clears them on open: a new instance per connection.
    private readonly keyMaps: { broadcast: Map<number, string>; perPlayer: Map<number, string>; rowTables: { clear(): void } };
    private readonly resyncSkip: ResyncSkipLike;
    private readonly onRowEntryViolation?: (rule: string) => void;
    private readonly now: () => number;

    constructor(private readonly sdk: SdkCore, schema: unknown, landID: string, options: ReconstructionOptions = {}) {
        this.now = options.now ?? (() => Date.now());
        this.keyMaps = { broadcast: new Map(), perPlayer: new Map(), rowTables: new sdk.RowTables() };
        this.resyncSkip = new sdk.ResyncSkip();
        this.onRowEntryViolation = options.onRowEntryViolation;
        if (options.encoding) this.encoding = { ...options.encoding };
        // The view's runtime is only asked whether it is connected, to send (never: this client
        // sends through its own socket), and to switch the decode path and the state-update
        // features after the join response.
        const runtime = {
            connected: true,
            sendRawMessage: () => {},
            updateDecodingStrategy: (message: MessageEncoding) => {
                this.encoding = {
                    ...this.encoding,
                    message,
                    stateUpdate: message === "json" ? "jsonObject" : "opcodeJsonArray",
                    stateUpdateDecoding: this.encoding.stateUpdateDecoding ?? "auto"
                };
            },
            // The features the join response echoes, with the land's tables (path indices).
            updateStateUpdateFeatures: (
                features: string[],
                pathIndexTable?: readonly number[],
                pathPatterns?: ReadonlyMap<number, string>
            ) => {
                this.encoding = { ...this.encoding, stateUpdateFeatures: [...features], pathIndexTable, pathPatterns };
                // As the SDK runtime: every successful join starts the row tables again (a rejoin
                // on the same socket gets creates for the slots the last land bound).
                this.keyMaps.rowTables.clear();
                if (features.includes("rowAddressing") && !features.includes("pathIndex")) {
                    this.violate("rowAddressing without pathIndex");
                    return false;
                }
                return true;
            }
        };
        this.view = new sdk.StateTreeView(runtime, landID, { schema, playerID: options.playerID });
    }

    /** The encoding the next frame is decoded with (switched by a join response). */
    get currentEncoding(): TransportEncodingConfig {
        return { ...this.encoding };
    }

    /** Decodes one received frame and applies it to the view. */
    /** With `rowAddressing`: the row tables and the land's patterns, for the resync skip. */
    private resyncRows(): { tables: unknown; pathPatterns?: ReadonlyMap<number, string> } | undefined {
        return this.encoding.stateUpdateFeatures?.includes("rowAddressing")
            ? { tables: this.keyMaps.rowTables, pathPatterns: this.encoding.pathPatterns }
            : undefined;
    }

    /** As the SDK runtime: after a resync, a frame at its sequence applies only what `ResyncSkip` keeps. */
    private applyState(update: any): void {
        const rows = this.resyncRows();
        const toApply = this.resyncSkip.filter(update, rows);
        if (toApply) {
            this.view.handleStateUpdate(toApply);
            this.rowPatchesApplied += this.sdk.rowPatchIndicesOf(toApply).length;
        }
        this.resyncSkip.noteApplied(update, rows);
    }

    private violate(rule: string): void {
        if (this.rowEntryViolation !== undefined) return;
        this.rowEntryViolation = rule;
        this.onRowEntryViolation?.(rule);
    }

    feed(data: string | ArrayBuffer | Uint8Array): void {
        this.lastFrameAt = this.now();
        if (this.rowEntryViolation !== undefined) {
            this.droppedAfterRowEntryViolation += 1;
            return;
        }
        let decoded: any;
        try {
            decoded = this.sdk.decodeMessage(data, this.encoding, this.keyMaps);
        } catch (error) {
            this.noteError(error);
            if (error instanceof this.sdk.RowEntryProtocolError) this.violate(error.rule);
            return;
        }
        try {
            if (decoded && typeof decoded === "object" && "kind" in decoded) {
                this.view.handleTransportMessage(decoded);
            } else if (decoded?.type === "stateUpdateWithEvents" && "stateUpdate" in decoded && "events" in decoded) {
                // Events first, then the state, as the runtime dispatches opcode 107.
                for (const event of decoded.events) this.view.handleTransportMessage(event);
                this.applyState(decoded.stateUpdate);
            } else if (decoded && "type" in decoded && "patches" in decoded) {
                this.applyState(decoded);
            } else if (decoded && "values" in decoded) {
                this.view.handleSnapshot(decoded);
            }
        } catch (error) {
            this.noteError(error);
        }
    }

    /** The reconstructed state, normalised for comparison. */
    normalizedState(): unknown {
        return this.sdk.normalizeForConvergence(this.view.getState());
    }

    private noteError(error: unknown): void {
        this.decodeErrors += 1;
        this.firstError ??= error instanceof Error ? error.message : String(error);
    }
}
