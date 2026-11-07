import { decode } from "@msgpack/msgpack";

/**
 * Reader for re-evaluation records in format 3.0 (#245): the `SSTR` magic and a version, then
 * records, each a 4-byte big-endian length and one MessagePack map with a `kind` key
 * (`header`, `turn`, `footer`). Only what the CLI needs: the metadata and the turn records in
 * file order. A record cut at the end is ignored, as the Swift reader does.
 */
export interface RecordLogTurn {
  tickId: number | bigint;
  lifecycleEvents?: Array<{ kind?: string; playerID?: string }>;
  [key: string]: unknown;
}

export interface RecordLog {
  metadata: Record<string, unknown> | undefined;
  turns: RecordLogTurn[];
  complete: boolean;
}

const MAGIC = [0x53, 0x53, 0x54, 0x52]; // "SSTR"

export function isRecordLog(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && MAGIC.every((b, i) => bytes[i] === b);
}

export function readRecordLog(bytes: Uint8Array): RecordLog {
  if (!isRecordLog(bytes)) {
    throw new Error("not a 3.x re-evaluation record (missing SSTR magic)");
  }
  let offset = 6;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const log: RecordLog = { metadata: undefined, turns: [], complete: false };
  while (bytes.length - offset >= 4) {
    const length = view.getUint32(offset, false);
    const start = offset + 4;
    if (bytes.length - start < length) break;
    // useBigInt64: an unsigned 64-bit field above 2^53 isn't rounded.
    const record = decode(bytes.subarray(start, start + length), { useBigInt64: true }) as Record<string, unknown>;
    offset = start + length;
    switch (record.kind) {
      case "header":
        log.metadata = record.metadata as Record<string, unknown>;
        break;
      case "turn":
        log.turns.push(record as unknown as RecordLogTurn);
        break;
      case "footer":
        log.complete = record.complete === true;
        break;
    }
  }
  return log;
}
