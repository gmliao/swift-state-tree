/**
 * Client decoder for the entity-delta baseline (`EncodingBenchmark --baseline entity-delta`,
 * `Sources/EncodingBenchmark/EntityDeltaBaseline.swift`): a separate implementation from the
 * Swift encoder, so the capture gate checks the protocol, not one implementation against itself.
 *
 * A frame (varints unless noted):
 *   newFieldCount, { entityType: u8, path: string }*
 *   removedCount, { slot }*
 *   createdCount, { slot, entityType: u8, key: string }*
 *   changedCount, { slot, mask: varint, value* (in field order) }*
 * Values: a tag byte, then the payload: 0 absent, 1 null, 2 false, 3 true, 4 int (zigzag varint),
 * 5 float32 LE, 6 string, 7 empty object, 8 empty array, 9 float64 LE.
 */

/** Top-level keyed collections whose children are entities; type `i + 1` is `COLLECTIONS[i]`. */
export const COLLECTIONS = ["players", "monsters", "turrets"];

const ABSENT = Symbol("absent");
const EMPTY_OBJECT = Symbol("emptyObject");
const EMPTY_ARRAY = Symbol("emptyArray");
type Leaf = typeof ABSENT | typeof EMPTY_OBJECT | typeof EMPTY_ARRAY | null | boolean | number | string;

/** Reads values; a bit-packed reader would replace this one behind the same methods. */
export class ByteAlignedReader {
    private offset = 0;
    private readonly view: DataView;

    constructor(private readonly bytes: Uint8Array) {
        this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    }

    get done(): boolean {
        return this.offset === this.bytes.length;
    }

    get position(): number {
        return this.offset;
    }

    byte(): number {
        if (this.offset >= this.bytes.length) throw new Error(`entity-delta: read past the end at ${this.offset}`);
        return this.bytes[this.offset++];
    }

    /** Unsigned LEB128, as a number (values here stay far below 2^53). */
    varint(): number {
        let result = 0;
        let scale = 1;
        for (;;) {
            const b = this.byte();
            result += (b & 0x7f) * scale;
            if (b < 0x80) return result;
            scale *= 128;
            if (scale > 2 ** 56) throw new Error("entity-delta: varint too long");
        }
    }

    /** A 64-bit mask, as a bigint. */
    mask(): bigint {
        let result = 0n;
        let shift = 0n;
        for (;;) {
            const b = this.byte();
            result |= BigInt(b & 0x7f) << shift;
            if (b < 0x80) return result;
            shift += 7n;
            if (shift > 63n) throw new Error("entity-delta: mask too long");
        }
    }

    string(): string {
        const length = this.varint();
        if (this.offset + length > this.bytes.length) throw new Error("entity-delta: string past the end");
        const text = new TextDecoder("utf-8", { fatal: true }).decode(this.bytes.subarray(this.offset, this.offset + length));
        this.offset += length;
        return text;
    }

    leaf(): Leaf {
        const tag = this.byte();
        switch (tag) {
            case 0: return ABSENT;
            case 1: return null;
            case 2: return false;
            case 3: return true;
            case 4: {
                const z = this.varint();
                return z % 2 === 0 ? z / 2 : -(z + 1) / 2;
            }
            case 5: {
                const v = this.view.getFloat32(this.offset, true);
                this.offset += 4;
                return v;
            }
            case 6: return this.string();
            case 7: return EMPTY_OBJECT;
            case 8: return EMPTY_ARRAY;
            case 9: {
                const v = this.view.getFloat64(this.offset, true);
                this.offset += 8;
                return v;
            }
            default: throw new Error(`entity-delta: bad value tag ${tag}`);
        }
    }
}

interface Entity {
    type: number;
    key: string;
    values: Leaf[];
}

/** One client's state: field tables per entity type, entities by slot. */
export class EntityDeltaClient {
    private readonly fields = new Map<number, string[]>();
    private readonly slots = new Map<number, Entity>();
    decodeErrors = 0;
    firstError?: string;
    frames = 0;

    /** Decodes one frame and applies it. A frame that fails to decode is counted, not thrown. */
    feed(data: Uint8Array): void {
        this.frames += 1;
        try {
            this.apply(data);
        } catch (error) {
            this.decodeErrors += 1;
            this.firstError ??= error instanceof Error ? error.message : String(error);
        }
    }

    /** Throws on a malformed frame. */
    apply(data: Uint8Array): void {
        const r = new ByteAlignedReader(data);
        for (let n = r.varint(); n > 0; n -= 1) {
            const type = r.byte();
            const path = r.string();
            const table = this.fields.get(type) ?? [];
            table.push(path);
            this.fields.set(type, table);
        }
        // Removals before creations: a freed slot can be reused in the same frame.
        for (let n = r.varint(); n > 0; n -= 1) {
            const slot = r.varint();
            if (!this.slots.delete(slot)) throw new Error(`entity-delta: removal of empty slot ${slot}`);
        }
        for (let n = r.varint(); n > 0; n -= 1) {
            const slot = r.varint();
            const type = r.byte();
            const key = r.string();
            if (this.slots.has(slot)) throw new Error(`entity-delta: creation in occupied slot ${slot}`);
            this.slots.set(slot, { type, key, values: [] });
        }
        for (let n = r.varint(); n > 0; n -= 1) {
            const slot = r.varint();
            const mask = r.mask();
            const entity = this.slots.get(slot);
            if (!entity) throw new Error(`entity-delta: change to empty slot ${slot}`);
            const table = this.fields.get(entity.type) ?? [];
            if (mask >> BigInt(table.length) !== 0n) throw new Error(`entity-delta: mask names fields beyond the table of type ${entity.type}`);
            while (entity.values.length < table.length) entity.values.push(ABSENT);
            for (let i = 0; i < table.length; i += 1) {
                if ((mask >> BigInt(i)) & 1n) entity.values[i] = r.leaf();
            }
        }
        if (!r.done) throw new Error(`entity-delta: ${data.length - r.position} trailing bytes`);
    }

    /** The state as a plain object, the shape of the server's projection. */
    getState(): Record<string, unknown> {
        const top: Record<string, unknown> = {};
        const collections = new Map<number, Record<string, unknown>>();
        for (const entity of this.slots.values()) {
            const table = this.fields.get(entity.type) ?? [];
            if (entity.type === 0) {
                entity.values.forEach((leaf, i) => {
                    const path = table[i];
                    if (path.startsWith("#")) {
                        const type = COLLECTIONS.indexOf(path.slice(1)) + 1;
                        if (leaf === true && !collections.has(type)) collections.set(type, {});
                    } else {
                        insert(top, path.split("."), leaf);
                    }
                });
            }
        }
        for (const entity of this.slots.values()) {
            if (entity.type === 0) continue;
            const children = collections.get(entity.type);
            if (!children) {
                // An inconsistent state is a decode error, reported by the gate, not a crash.
                this.decodeErrors += 1;
                this.firstError ??= `entity-delta: entity of type ${entity.type} without its collection`;
                continue;
            }
            const node: Record<string, unknown> = {};
            const table = this.fields.get(entity.type) ?? [];
            entity.values.forEach((leaf, i) => insert(node, table[i].split("."), leaf));
            children[entity.key] = node;
        }
        for (const [type, children] of collections) top[COLLECTIONS[type - 1]] = children;
        return top;
    }
}

/** Puts `leaf` at `path` under `node`; an absent leaf adds nothing. */
function insert(node: Record<string, unknown>, path: string[], leaf: Leaf): void {
    if (leaf === ABSENT) return;
    let current = node;
    for (const part of path.slice(0, -1)) {
        const next = current[part];
        if (typeof next !== "object" || next === null || Array.isArray(next)) current[part] = {};
        current = current[part] as Record<string, unknown>;
    }
    const last = path[path.length - 1];
    if (leaf === EMPTY_OBJECT) {
        const existing = current[last];
        if (typeof existing !== "object" || existing === null || Array.isArray(existing)) current[last] = {};
    } else if (leaf === EMPTY_ARRAY) {
        current[last] = [];
    } else {
        current[last] = leaf;
    }
}
