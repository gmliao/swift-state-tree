import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import type { ActionOutcome } from "./action-outcomes";
import type { CloseRecord, ReconnectRecord, SocketRecord } from "./worker";

/**
 * Raw per-event samples (`--samples-dir`), one gzip-compressed NDJSON file per worker
 * (`w<index>.ndjson.gz`). Each line is one record; `k` is the connection key, every time is ms
 * since epoch. Outcomes are raw times, not classifications: whether an answer was late, or a
 * request timed out, is read from the times by the analysis, with the report's thresholds.
 *
 * - `phase`: a phase started in this worker: `name`, `originAt`, `endAt`.
 * - `join`: a connection joined: `t`, `openedAt` (socket open), `land`, `player` (the tool's
 *   label), `serverPlayer` (the playerID in the server's JoinResponse, when it names one: the
 *   key into the server's lifecycle log).
 * - `rtt`: one action: `intendedAt` (the RTT origin), `sentAt` (actual send), and either
 *   `respondedAt`, or `respondedAt: null` with `end`: `"phaseEnd"` (still unanswered when its phase
 *   ended) or `"closed"` (its connection had closed by then; `closedAt`).
 * - `late`: the first answer to a request a phase end left unanswered (its `rtt` record has
 *   `end: "phaseEnd"`), in a later phase: `respondedAt` and `outcome`. With the `rtt` records'
 *   outcomes it gives every answered request's outcome, as the report's `actionOutcomes` count it.
 *   An outcome is an `ActionOutcome` (`action-outcomes.ts`): `applied`, an injected failure
 *   (`failed`, `timedOut`), an action-job cap's rejection (`abandonedLimitRejected`,
 *   `inFlightLimitRejected`) or `errored`.
 * - `update`: one state update: `t` (arrival), `gapMs` since the previous one on the connection
 *   (null for the first), `bytes` when known, `full` (`"firstSync"` or `"resync"`, #332) when the frame
 *   was a full view.
 * - `input`: one move event (`--input-latency on`): `sentAt`, and `seenAt`, or `seenAt: null` with
 *   `end`: `"superseded"`, `"timedOut"`, `"pendingAtEnd"` (the client closed it) or
 *   `"closedBeforeSeen"` (the server or the stale check closed it).
 * - `resync`: one in-place resync (#332, `syncSequence`) the connection received: `t` (its
 *   arrival), `player`.
 * - `close`: every close, as `CloseRecord`, with `player`.
 * - `reconnect`: every reconnect that ended (`--reconnect`), as `ReconnectRecord`.
 * - `socket`: every socket, once, when it ends (#490), as `SocketRecord`: its TCP local port (the
 *   server's peer port), its connect, open and join times as far as it got, and how it ended
 *   (`SocketEnd`). A reconnect attempt the tool gave up on has one too, though it has no `close`.
 * - `sockets`: once per worker process, at shutdown: the sockets it `created`, those with a
 *   `socket` record (`recorded`), and `leftAtExit`, the difference (0 when every socket ended).
 * - `loop`: this worker's event-loop utilization over `[from, to)`, about 1 s (`elu`, 0–1), for
 *   the per-window client-bound check; written through each phase (`loop-utilization`).
 */
export type SampleRecord =
    | { r: "phase"; name: string; originAt: number; endAt: number }
    | { r: "join"; k: string; t: number; openedAt?: number; land: string; player: string; serverPlayer?: string }
    | {
          r: "rtt";
          k: string;
          intendedAt: number;
          sentAt: number;
          respondedAt: number | null;
          /** The answer's outcome (`action-outcomes.ts`), when it answered. */
          outcome?: ActionOutcome;
          end?: "phaseEnd" | "closed";
          closedAt?: number;
      }
    | { r: "late"; k: string; respondedAt: number; outcome: ActionOutcome }
    | { r: "update"; k: string; t: number; gapMs: number | null; bytes?: number; full?: "firstSync" | "resync" }
    | {
          r: "input";
          k: string;
          sentAt: number;
          seenAt: number | null;
          end?: "superseded" | "timedOut" | "pendingAtEnd" | "closedBeforeSeen";
      }
    | { r: "resync"; k: string; t: number; player: string }
    | ({ r: "close"; player: string } & CloseRecord)
    | ({ r: "reconnect"; k: string } & ReconnectRecord)
    | ({ r: "socket"; k: string } & SocketRecord)
    | { r: "sockets"; created: number; recorded: number; leftAtExit: number }
    | { r: "loop"; from: number; to: number; elu: number; cpuMs?: number };

export type SampleWriter = (record: SampleRecord) => void;

/** Lines are buffered and handed to gzip in chunks of about this many characters. */
const FLUSH_CHARS = 256 * 1024;

export class SampleSink {
    private readonly gzip: zlib.Gzip;
    private readonly file: fs.WriteStream;
    private readonly finished: Promise<void>;
    private buffer: string[] = [];
    private bufferedChars = 0;
    private closed = false;
    /** Records written, for the run report. */
    count = 0;

    constructor(readonly filePath: string) {
        fs.mkdirSync(path.dirname(filePath), { recursive: true });
        this.gzip = zlib.createGzip({ level: 1 });
        this.file = fs.createWriteStream(filePath);
        this.finished = new Promise((resolve, reject) => {
            this.file.on("finish", () => resolve());
            this.file.on("error", reject);
            this.gzip.on("error", reject);
        });
        this.gzip.pipe(this.file);
    }

    readonly write: SampleWriter = (record) => {
        if (this.closed) {
            return;
        }
        const line = JSON.stringify(record) + "\n";
        this.buffer.push(line);
        this.bufferedChars += line.length;
        this.count += 1;
        if (this.bufferedChars >= FLUSH_CHARS) {
            this.flush();
        }
    };

    /** Flushes, ends the gzip stream and resolves once the file is written. */
    async close(): Promise<void> {
        if (!this.closed) {
            this.flush();
            this.closed = true;
            this.gzip.end();
        }
        await this.finished;
    }

    private flush(): void {
        if (this.buffer.length === 0) {
            return;
        }
        this.gzip.write(this.buffer.join(""));
        this.buffer = [];
        this.bufferedChars = 0;
    }
}

/** Reads a samples file back (tests and analysis). */
export function readSamples(filePath: string): SampleRecord[] {
    const text = zlib.gunzipSync(fs.readFileSync(filePath)).toString("utf8");
    return text
        .split("\n")
        .filter((line) => line.length > 0)
        .map((line) => JSON.parse(line) as SampleRecord);
}
