import fs from "node:fs";
import zlib from "node:zlib";
import { ConnectionReconstruction, type SdkCore, type TransportEncodingConfig } from "./reconstruction";
import { EntityDeltaClient } from "./entity-delta";
import { ENTITY_DELTA_FORMAT, reaches, sdkEncoding } from "./verify-views";

/**
 * Client decode cost over recorded frames: every recipient's stream, in order, decoded by the
 * TypeScript SDK as a client does. Two figures per stream:
 * - `decode`: `decodeMessage` alone, with the stream's own dynamic-key tables;
 * - `decodeApply`: decode plus applying to a `StateTreeView` (the client's cost per frame).
 * Each pass starts from fresh key tables and a fresh view, so every pass does the same work as
 * the live client did. The figure is the median pass after `warmup` passes, per frame and per
 * sync (a sync is one checkpoint of the capture: all frames a recipient got for one sync).
 *
 * A capture from the entity-delta baseline is decoded by `EntityDeltaClient` instead. Its decoder
 * applies as it parses, so it has `decodeApply` only (`decode` is null).
 */

export interface DecodeStream {
    /** `<file>#<session>` */
    name: string;
    schema: unknown;
    landID: string;
    playerID: string;
    encoding: TransportEncodingConfig;
    /** `entity-delta` for the baseline's frames; otherwise the SDK decodes them. */
    decoder: "sdk" | "entity-delta";
    /** As a client's socket hands them over: text for JSON, bytes for MessagePack. */
    frames: Array<string | Uint8Array>;
    syncs: number;
}

export interface TimingOptions {
    passes: number;
    warmup: number;
    now?: () => bigint;
}

export interface StreamTiming {
    name: string;
    frames: number;
    syncs: number;
    bytes: number;
    decodeUsPerPass: number[];
    decodeApplyUsPerPass: number[];
}

export interface DecodeSummary {
    streams: number;
    frames: number;
    syncs: number;
    bytes: number;
    passes: number;
    warmup: number;
    /** Sum over streams of each stream's median pass, divided by frames and syncs. */
    /** Null when a stream's decoder can't decode without applying (the entity-delta baseline). */
    decode: { usPerFrame: number; usPerSync: number } | null;
    decodeApply: { usPerFrame: number; usPerSync: number };
}

/** Every recipient stream of one `--capture-views` room file. */
export function captureStreams(file: string): DecodeStream[] {
    const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.length > 0);
    if (lines.length < 2) throw new Error(`${file}: a header and at least one sync are needed`);
    const header = JSON.parse(lines[0]);
    const entityDelta = header.format === ENTITY_DELTA_FORMAT;
    const encoding = entityDelta ? ({} as TransportEncodingConfig) : sdkEncoding(header.message, header.stateUpdate);
    const binary = entityDelta || header.message === "messagepack";
    const sessions = Object.entries(header.sessions as Record<string, string>);
    const streams: DecodeStream[] = sessions.map(([session, player]) => ({
        name: `${file}#${session}`, schema: header.schema, landID: header.landID, playerID: player,
        encoding, decoder: entityDelta ? "entity-delta" : "sdk", frames: [] as Array<string | Uint8Array>, syncs: 0
    }));
    for (const raw of lines.slice(1)) {
        const line = JSON.parse(raw) as { frames: Array<{ to: string; data: string }> };
        const decoded = line.frames.map((f) => {
            const bytes = Buffer.from(f.data, "base64");
            return { to: f.to, data: binary ? new Uint8Array(bytes) : bytes.toString("utf8") };
        });
        sessions.forEach(([session, player], i) => {
            streams[i].syncs += 1;
            for (const f of decoded) if (reaches(f.to, session, player)) streams[i].frames.push(f.data);
        });
    }
    return streams;
}

const median = (values: number[]): number => {
    const sorted = [...values].sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};

export function timeStream(sdk: SdkCore, stream: DecodeStream, options: TimingOptions): StreamTiming {
    const now = options.now ?? (() => process.hrtime.bigint());
    const decodeUs: number[] = [];
    const applyUs: number[] = [];
    if (stream.decoder === "entity-delta") {
        for (let pass = 0; pass < options.warmup + options.passes; pass += 1) {
            const client = new EntityDeltaClient();
            let index = 0;
            const start = now();
            try {
                for (; index < stream.frames.length; index += 1) client.apply(stream.frames[index] as Uint8Array);
            } catch (error) {
                throw new Error(`${stream.name}: frame ${index} failed to decode (${error instanceof Error ? error.message : String(error)})`);
            }
            const applyNs = now() - start;
            if (pass >= options.warmup) applyUs.push(Number(applyNs) / 1000);
        }
        return { name: stream.name, frames: stream.frames.length, syncs: stream.syncs, bytes: byteCount(stream.frames), decodeUsPerPass: [], decodeApplyUsPerPass: applyUs };
    }
    for (let pass = 0; pass < options.warmup + options.passes; pass += 1) {
        // The view, made untimed first: making it loads the schema's path and event hash tables
        // (global in the SDK), which decodeMessage needs, as a client's view does once.
        const view = new ConnectionReconstruction(sdk, stream.schema, stream.landID, { playerID: stream.playerID, encoding: stream.encoding });
        // decode alone: besides those tables, the key tables are the only state decodeMessage keeps.
        const keyMaps = new Map();
        let start = now();
        let index = 0;
        try {
            for (; index < stream.frames.length; index += 1) sdk.decodeMessage(stream.frames[index], stream.encoding, keyMaps);
        } catch (error) {
            throw new Error(`${stream.name}: frame ${index} failed to decode (${error instanceof Error ? error.message : String(error)})`);
        }
        const decodeNs = now() - start;
        // decode and apply, as the reconstruction (and a client) does.
        start = now();
        for (const frame of stream.frames) view.feed(frame);
        const applyNs = now() - start;
        if (view.decodeErrors > 0) throw new Error(`${stream.name}: ${view.decodeErrors} frames failed to decode (${view.firstError})`);
        if (pass >= options.warmup) {
            decodeUs.push(Number(decodeNs) / 1000);
            applyUs.push(Number(applyNs) / 1000);
        }
    }
    return { name: stream.name, frames: stream.frames.length, syncs: stream.syncs, bytes: byteCount(stream.frames), decodeUsPerPass: decodeUs, decodeApplyUsPerPass: applyUs };
}

const byteCount = (frames: Array<string | Uint8Array>): number =>
    frames.reduce((n, f) => n + (typeof f === "string" ? Buffer.byteLength(f) : f.byteLength), 0);

export function summarize(timings: StreamTiming[], options: TimingOptions): DecodeSummary {
    const frames = timings.reduce((n, t) => n + t.frames, 0);
    const syncs = timings.reduce((n, t) => n + t.syncs, 0);
    const decodeKnown = timings.every((t) => t.decodeUsPerPass.length > 0);
    const decode = decodeKnown ? timings.reduce((n, t) => n + median(t.decodeUsPerPass), 0) : 0;
    const apply = timings.reduce((n, t) => n + median(t.decodeApplyUsPerPass), 0);
    const per = (us: number) => ({ usPerFrame: frames ? us / frames : 0, usPerSync: syncs ? us / syncs : 0 });
    return {
        streams: timings.length, frames, syncs, bytes: timings.reduce((n, t) => n + t.bytes, 0),
        passes: options.passes, warmup: options.warmup, decode: decodeKnown ? per(decode) : null, decodeApply: per(apply)
    };
}

/**
 * The streams of a `scripts/record-frames.mjs` recording (a GameServer's frames to a few
 * connections). Each stream starts after its join response, with the encoding that response
 * switched to, so it is timed like a capture's stream; its `syncs` is its frame count.
 */
export function recordingStreams(sdk: SdkCore, file: string): DecodeStream[] {
    const recording = JSON.parse(zlib.gunzipSync(fs.readFileSync(file)).toString("utf8"));
    return recording.connections.map((connection: { name: string; frames: Array<{ binary: boolean; data: string }> }) => {
        const frames = connection.frames.map((f) => {
            const bytes = Buffer.from(f.data, "base64");
            return f.binary ? new Uint8Array(bytes) : bytes.toString("utf8");
        });
        const probe = new ConnectionReconstruction(sdk, recording.schema, `hero-defense:${recording.land}`, { playerID: connection.name });
        const initial = JSON.stringify(probe.currentEncoding);
        let start = frames.length;
        for (let i = 0; i < frames.length; i += 1) {
            probe.feed(frames[i]);
            if (JSON.stringify(probe.currentEncoding) !== initial) {
                start = i + 1;
                break;
            }
        }
        if (start === frames.length) throw new Error(`${file}#${connection.name}: no join response switched the encoding`);
        const timed = frames.slice(start);
        return {
            name: `${file}#${connection.name}`, schema: recording.schema, landID: `hero-defense:${recording.land}`,
            playerID: connection.name, encoding: probe.currentEncoding, decoder: "sdk", frames: timed, syncs: timed.length
        };
    });
}

/** Frame sizes in bytes: the distribution the timings are read against. */
export function frameSizes(streams: DecodeStream[]): { frames: number; min: number; median: number; p95: number; max: number; mean: number } {
    const sizes = streams.flatMap((s) => s.frames.map((f) => (typeof f === "string" ? Buffer.byteLength(f) : f.byteLength))).sort((a, b) => a - b);
    if (sizes.length === 0) return { frames: 0, min: 0, median: 0, p95: 0, max: 0, mean: 0 };
    const at = (q: number) => sizes[Math.min(sizes.length - 1, Math.floor(q * (sizes.length - 1)))];
    return { frames: sizes.length, min: sizes[0], median: at(0.5), p95: at(0.95), max: sizes[sizes.length - 1], mean: sizes.reduce((a, b) => a + b, 0) / sizes.length };
}

/**
 * Each frame's payload size after permessage-deflate as `ws` runs it by default: one raw-deflate
 * context per connection kept across messages (context takeover, 15-bit window, level 6), each
 * message flushed with a sync flush and its trailing `00 00 ff ff` removed (RFC 7692).
 */
export async function deflateSizes(frames: Array<string | Uint8Array>): Promise<number[]> {
    const deflate = zlib.createDeflateRaw({ windowBits: 15, level: 6, memLevel: 8 });
    let pending = 0;
    deflate.on("data", (chunk: Buffer) => (pending += chunk.length));
    const sizes: number[] = [];
    for (const frame of frames) {
        deflate.write(typeof frame === "string" ? Buffer.from(frame, "utf8") : frame);
        await new Promise<void>((resolve) => deflate.flush(zlib.constants.Z_SYNC_FLUSH, () => resolve()));
        sizes.push(pending - 4);
        pending = 0;
    }
    deflate.close();
    return sizes;
}

export interface RoomBytes {
    rooms: number;
    /** Checkpoints after the first (the joins, the initial sync and the warm-up flush). */
    measuredSyncs: number;
    /** Payload bytes to every recipient of a room per measured sync, mean over the rooms. */
    bytesPerRoomSync: number;
    /** The same after permessage-deflate (`deflateSizes`), each recipient's whole stream compressed in order. */
    deflateBytesPerRoomSync: number;
}

/**
 * Bytes per room per sync over a run's captured rooms, before and after deflate. A frame counts
 * once per recipient it reaches, as the benchmark counts it; checkpoint 0 is compressed (it sets
 * up the deflate context, as on a real connection) but outside the measured window.
 */
export async function roomBytes(files: string[]): Promise<RoomBytes> {
    let raw = 0;
    let deflated = 0;
    let measuredSyncs = -1;
    for (const file of files) {
        const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.length > 0);
        const header = JSON.parse(lines[0]);
        const sessions = Object.entries(header.sessions as Record<string, string>);
        const syncs = lines.length - 2;
        if (measuredSyncs >= 0 && syncs !== measuredSyncs) throw new Error(`${file}: ${syncs} measured syncs, other rooms have ${measuredSyncs}`);
        measuredSyncs = syncs;
        for (const [session, player] of sessions) {
            const frames: Uint8Array[] = [];
            const measured: boolean[] = [];
            lines.slice(1).forEach((rawLine, checkpoint) => {
                for (const f of (JSON.parse(rawLine) as { frames: Array<{ to: string; data: string }> }).frames) {
                    if (!reaches(f.to, session, player)) continue;
                    frames.push(new Uint8Array(Buffer.from(f.data, "base64")));
                    measured.push(checkpoint > 0);
                }
            });
            const sizes = await deflateSizes(frames);
            frames.forEach((f, i) => {
                if (!measured[i]) return;
                raw += f.byteLength;
                deflated += sizes[i];
            });
        }
    }
    if (files.length === 0 || measuredSyncs <= 0) throw new Error("roomBytes: no measured syncs");
    const per = (bytes: number) => bytes / files.length / measuredSyncs;
    return { rooms: files.length, measuredSyncs, bytesPerRoomSync: per(raw), deflateBytesPerRoomSync: per(deflated) };
}
