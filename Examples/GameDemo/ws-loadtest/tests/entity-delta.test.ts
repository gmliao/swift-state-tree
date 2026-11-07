import { describe, expect, it } from "vitest";
import { EntityDeltaClient } from "../src/entity-delta";

/** A frame writer mirroring the Swift encoder's layout, for hand-built frames. */
class Frame {
    bytes: number[] = [];
    varint(v: number): this {
        while (v >= 0x80) {
            this.bytes.push((v & 0x7f) | 0x80);
            v = Math.floor(v / 128);
        }
        this.bytes.push(v);
        return this;
    }
    byte(v: number): this {
        this.bytes.push(v);
        return this;
    }
    string(s: string): this {
        const utf8 = Buffer.from(s, "utf8");
        this.varint(utf8.length);
        this.bytes.push(...utf8);
        return this;
    }
    int(v: number): this {
        return this.byte(4).varint(v >= 0 ? 2 * v : -2 * v - 1);
    }
    done(): Uint8Array {
        return Uint8Array.from(this.bytes);
    }
}

/** Fields: root `score`, `#monsters`; monster type 2 `hp`, `position.v.x`. */
function first(): Uint8Array {
    return new Frame()
        .varint(4).byte(0).string("#monsters").byte(0).string("score").byte(2).string("hp").byte(2).string("position.v.x")
        .varint(0)
        .varint(2).varint(0).byte(0).string("").varint(1).byte(2).string("7")
        .varint(2)
        .varint(0).varint(0b11).byte(3).int(10)
        .varint(1).varint(0b11).int(5).int(-3)
        .done();
}

describe("entity-delta decoder", () => {
    it("rebuilds the projection from a first frame", () => {
        const client = new EntityDeltaClient();
        client.feed(first());
        expect(client.decodeErrors).toBe(0);
        expect(client.getState()).toEqual({ score: 10, monsters: { "7": { hp: 5, position: { v: { x: -3 } } } } });
    });

    it("applies only the fields a mask names", () => {
        const client = new EntityDeltaClient();
        client.feed(first());
        client.feed(new Frame().varint(0).varint(0).varint(0).varint(1).varint(1).varint(0b10).int(4).done());
        expect(client.getState()).toEqual({ score: 10, monsters: { "7": { hp: 5, position: { v: { x: 4 } } } } });
    });

    it("reuses a freed slot in the same frame: the removal comes first and the new entity starts empty", () => {
        const client = new EntityDeltaClient();
        client.feed(first());
        // Monster 7 (slot 1) dies; monster 8 takes slot 1 and sets hp only.
        client.feed(new Frame().varint(0).varint(1).varint(1).varint(1).varint(1).byte(2).string("8").varint(1).varint(1).varint(0b01).int(9).done());
        expect(client.decodeErrors).toBe(0);
        expect(client.getState()).toEqual({ score: 10, monsters: { "8": { hp: 9 } } });
    });

    it("keeps an empty collection", () => {
        const client = new EntityDeltaClient();
        client.feed(first());
        client.feed(new Frame().varint(0).varint(1).varint(1).varint(0).varint(0).done());
        expect(client.getState()).toEqual({ score: 10, monsters: {} });
    });

    it("counts malformed frames as decode errors", () => {
        const cases: Array<[string, Uint8Array]> = [
            ["trailing bytes", new Frame().varint(0).varint(0).varint(0).varint(0).byte(0).done()],
            ["change to an empty slot", new Frame().varint(0).varint(0).varint(0).varint(1).varint(5).varint(1).int(1).done()],
            ["removal of an empty slot", new Frame().varint(0).varint(1).varint(5).varint(0).varint(0).done()],
            ["truncated", new Frame().varint(1).byte(0).done()]
        ];
        for (const [name, frame] of cases) {
            const client = new EntityDeltaClient();
            client.feed(frame);
            expect(client.decodeErrors, name).toBe(1);
        }
    });

    it("refuses a creation in an occupied slot (a removal applied after the creations)", () => {
        const client = new EntityDeltaClient();
        client.feed(first());
        client.feed(new Frame().varint(0).varint(0).varint(1).varint(1).byte(2).string("8").varint(0).done());
        expect(client.decodeErrors).toBe(1);
    });
});

describe("entity-delta state", () => {
    it("reports an entity whose collection marker is missing as a decode error", () => {
        const client = new EntityDeltaClient();
        // A monster entity (type 2) with no `#monsters` marker on the root.
        client.feed(new Frame().varint(1).byte(2).string("hp").varint(0).varint(1).varint(0).byte(2).string("7").varint(1).varint(0).varint(1).int(3).done());
        expect(client.decodeErrors).toBe(0);
        expect(client.getState()).toEqual({});
        expect(client.decodeErrors).toBe(1);
    });
});
