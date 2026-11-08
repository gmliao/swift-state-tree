import fs from "node:fs";
import path from "node:path";
import type * as ColyseusSchema from "@colyseus/schema" with { "resolution-mode": "import" };

// The package ships CommonJS (`build/index.cjs`, its `require` export) next to its ESM build;
// this tool is CommonJS, so it loads that build and takes only the types from the ESM side.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { Decoder, Encoder, schema, t } = require("@colyseus/schema") as typeof ColyseusSchema;

/**
 * The `@colyseus/schema` baseline (B1, plan `Notes/plans/2026-11-07-entity-delta-baseline.md`):
 * hero-defense's synced state declared as Colyseus schema classes, encoded offline from the
 * per-sync projections of a `--capture-views` capture, and decoded with Colyseus's own `Decoder`.
 *
 * The classes mirror the `@Sync(.broadcast)` fields of `Sources/GameContent/States/*.swift`, with
 * `Position2` and `Angle` flattened to their components, as a Colyseus server would declare them.
 * Nil optionals (`targetPosition`, `ownerID`) are assigned `undefined`, which Colyseus encodes as
 * a delete, so absent stays apart from present at zero; they map back to `null`, as the
 * projection represents nil.
 */

export const COLYSEUS_FORMAT = "colyseus-schema";
export type Typing = "number" | "tuned";
export const TYPINGS: Typing[] = ["number", "tuned"];

/** A Colyseus primitive type for one field. */
export type FieldType = "number" | "int8" | "uint8" | "int16" | "uint16" | "int32" | "uint32" | "float32" | "float64" | "string";
/** Per class, per field, the type it's declared with; travels in the capture header. */
export type FieldTypes = Record<string, Record<string, FieldType>>;

type Projection = Record<string, any>;

/** The classes' fields: `number` or `string`, and whether the field is optional. */
const SHAPE: Record<string, Record<string, { kind: "number" | "string"; optional?: true }>> = {
    Player: {
        x: { kind: "number" }, y: { kind: "number" }, rotation: { kind: "number" },
        targetX: { kind: "number", optional: true }, targetY: { kind: "number", optional: true },
        health: { kind: "number" }, maxHealth: { kind: "number" }, weaponLevel: { kind: "number" }, resources: { kind: "number" }
    },
    Monster: { id: { kind: "number" }, x: { kind: "number" }, y: { kind: "number" }, rotation: { kind: "number" }, health: { kind: "number" }, maxHealth: { kind: "number" } },
    Turret: {
        id: { kind: "number" }, x: { kind: "number" }, y: { kind: "number" }, rotation: { kind: "number" }, level: { kind: "number" },
        ownerID: { kind: "string", optional: true }
    },
    Base: { x: { kind: "number" }, y: { kind: "number" }, radius: { kind: "number" }, health: { kind: "number" }, maxHealth: { kind: "number" } },
    State: { score: { kind: "number" } }
};

export const COLLECTIONS: Record<string, string> = { players: "Player", monsters: "Monster", turrets: "Turret" };

/** The package version the converter runs, as installed (pinned in package-lock.json). */
export function colyseusVersion(): string {
    let dir = path.dirname(require.resolve("@colyseus/schema"));
    while (!fs.existsSync(path.join(dir, "package.json"))) dir = path.dirname(dir);
    return JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).version;
}

/** Every number field declared `number`: Colyseus's documented default. */
export function numberTypes(): FieldTypes {
    return Object.fromEntries(Object.entries(SHAPE).map(([cls, fields]) => [cls, Object.fromEntries(Object.entries(fields).map(([f, s]) => [f, s.kind === "string" ? "string" : "number"]))])) as FieldTypes;
}

/** Observed values per field, for the tuned typing. */
export class FieldRanges {
    private readonly ranges = new Map<string, { min: number; max: number; integer: boolean; float32: boolean }>();

    observe(cls: string, fields: Record<string, unknown>): void {
        for (const [field, value] of Object.entries(fields)) {
            if (typeof value !== "number") continue;
            const key = `${cls}.${field}`;
            const r = this.ranges.get(key) ?? { min: value, max: value, integer: true, float32: true };
            r.min = Math.min(r.min, value);
            r.max = Math.max(r.max, value);
            r.integer &&= Number.isInteger(value);
            r.float32 &&= Math.fround(value) === value;
            this.ranges.set(key, r);
        }
    }

    /** Per field, the narrowest fixed type covering every value it took; `number` if it took none. */
    tuned(): FieldTypes {
        const types = numberTypes();
        for (const [cls, fields] of Object.entries(types)) {
            for (const field of Object.keys(fields)) {
                if (fields[field] === "string") continue;
                const r = this.ranges.get(`${cls}.${field}`);
                if (r) fields[field] = narrowest(r);
            }
        }
        return types;
    }
}

const INTEGER_TYPES: Array<[FieldType, number, number]> = [
    ["uint8", 0, 0xff], ["int8", -0x80, 0x7f], ["uint16", 0, 0xffff], ["int16", -0x8000, 0x7fff],
    ["uint32", 0, 0xffffffff], ["int32", -0x80000000, 0x7fffffff]
];

function narrowest(r: { min: number; max: number; integer: boolean; float32: boolean }): FieldType {
    if (r.integer) {
        const hit = INTEGER_TYPES.find(([, lo, hi]) => r.min >= lo && r.max <= hi);
        if (hit) return hit[0];
    }
    return r.float32 ? "float32" : "float64";
}

const classCache = new Map<string, ReturnType<typeof defineClasses>>();

function defineClasses(types: FieldTypes, tag: string) {
    const fields = (cls: string) => Object.fromEntries(Object.entries(types[cls]).map(([f, type]) => {
        const builder = (t as any)[type]();
        return [f, SHAPE[cls][f].optional ? builder.optional() : builder];
    }));
    const Player = schema(fields("Player"), `Player${tag}`);
    const Monster = schema(fields("Monster"), `Monster${tag}`);
    const Turret = schema(fields("Turret"), `Turret${tag}`);
    const Base = schema(fields("Base"), `Base${tag}`);
    const State = schema({
        players: t.map(Player), monsters: t.map(Monster), turrets: t.map(Turret), base: Base, ...fields("State")
    }, `State${tag}`);
    return { State, Base, entity: { players: Player, monsters: Monster, turrets: Turret } as Record<string, any> };
}

/** The schema classes for `types`, defined once per distinct typing. */
export function stateClasses(types: FieldTypes) {
    for (const cls of Object.keys(SHAPE)) {
        for (const f of Object.keys(SHAPE[cls])) {
            if (!types[cls]?.[f]) throw new Error(`field types lack ${cls}.${f}`);
        }
    }
    const key = JSON.stringify(Object.keys(SHAPE).map((cls) => Object.keys(SHAPE[cls]).map((f) => types[cls][f])));
    let c = classCache.get(key);
    if (!c) {
        c = defineClasses(types, `_${classCache.size}`);
        classCache.set(key, c);
    }
    return c;
}

const toFields: Record<string, (e: any) => Record<string, unknown>> = {
    players: (p) => ({
        x: p.position.v.x, y: p.position.v.y, rotation: p.rotation.degrees,
        targetX: p.targetPosition?.v.x, targetY: p.targetPosition?.v.y,
        health: p.health, maxHealth: p.maxHealth, weaponLevel: p.weaponLevel, resources: p.resources
    }),
    monsters: (m) => ({ id: m.id, x: m.position.v.x, y: m.position.v.y, rotation: m.rotation.degrees, health: m.health, maxHealth: m.maxHealth }),
    turrets: (u) => ({ id: u.id, x: u.position.v.x, y: u.position.v.y, rotation: u.rotation.degrees, level: u.level, ownerID: u.ownerID ?? undefined })
};

const baseFields = (b: any) => ({ x: b.position.v.x, y: b.position.v.y, radius: b.radius, health: b.health, maxHealth: b.maxHealth });

const fromFields: Record<string, (f: any) => Record<string, unknown>> = {
    players: (f) => ({
        health: f.health, maxHealth: f.maxHealth, position: { v: { x: f.x, y: f.y } }, resources: f.resources,
        rotation: { degrees: f.rotation },
        targetPosition: f.targetX === undefined ? null : { v: { x: f.targetX, y: f.targetY } },
        weaponLevel: f.weaponLevel
    }),
    monsters: (f) => ({ health: f.health, id: f.id, maxHealth: f.maxHealth, position: { v: { x: f.x, y: f.y } }, rotation: { degrees: f.rotation } }),
    turrets: (f) => ({ id: f.id, level: f.level, ownerID: f.ownerID ?? null, position: { v: { x: f.x, y: f.y } }, rotation: { degrees: f.rotation } })
};

/** Assigns only the values that differ, as a server mutating its state would. */
function assignChanged(target: any, fields: Record<string, unknown>): void {
    for (const [k, v] of Object.entries(fields)) if (target[k] !== v) target[k] = v;
}

/** Records every value a projection holds, by class and field, for the tuned typing. */
export function observeProjection(ranges: FieldRanges, projection: Projection): void {
    for (const [name, cls] of Object.entries(COLLECTIONS)) {
        for (const e of Object.values(projection[name] ?? {})) ranges.observe(cls, toFields[name](e));
    }
    ranges.observe("Base", baseFields(projection.base));
    ranges.observe("State", { score: projection.score });
}

/** Brings the server state to `projection`: removals, creations, changed values. */
export function applyProjection(types: FieldTypes, state: any, projection: Projection): void {
    const c = stateClasses(types);
    for (const name of Object.keys(COLLECTIONS)) {
        const map = state[name];
        const entities = projection[name] ?? {};
        for (const key of [...map.keys()]) if (!(key in entities)) map.delete(key);
        for (const [key, e] of Object.entries(entities)) {
            let item = map.get(key);
            if (!item) {
                item = new c.entity[name]();
                map.set(key, item);
            }
            assignChanged(item, toFields[name](e));
        }
    }
    assignChanged(state.base, baseFields(projection.base));
    if (state.score !== projection.score) state.score = projection.score;
}

/** A decoded state in the projection's shape. */
export function stateToProjection(state: any): Projection {
    const out: Projection = {};
    for (const name of Object.keys(COLLECTIONS)) {
        out[name] = {};
        state[name]?.forEach((item: any, key: string) => {
            out[name][key] = fromFields[name](item);
        });
    }
    const b = state.base;
    if (b) out.base = { health: b.health, maxHealth: b.maxHealth, position: { v: { x: b.x, y: b.y } }, radius: b.radius };
    out.score = state.score;
    return out;
}

export function newServerState(types: FieldTypes): any {
    const c = stateClasses(types);
    const state: any = new c.State();
    state.base = new c.Base();
    return state;
}

/** A client: Colyseus's decoder over its own state instance. */
export class ColyseusClient {
    private readonly decoder: InstanceType<typeof Decoder>;
    decodeErrors = 0;
    firstError?: string;

    constructor(types: FieldTypes) {
        this.decoder = new Decoder(new (stateClasses(types).State)() as any);
    }

    /** `Decoder.decode` alone (what time-decode times); throws on a frame that fails to decode. */
    apply(data: Uint8Array): void {
        this.decoder.decode(data as any);
    }

    feed(data: Uint8Array): void {
        try {
            this.apply(data);
        } catch (error) {
            this.decodeErrors += 1;
            this.firstError ??= error instanceof Error ? error.message : String(error);
        }
    }

    /** The decoded state mapped back to the projection's shape (the gate's side, not timed). */
    getState(): Projection {
        return stateToProjection(this.decoder.state);
    }
}

const canonical = (value: unknown): string =>
    JSON.stringify(value, (_k, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : v));

export interface ConvertReport {
    package: string;
    version: string;
    typing: Typing;
    runs: Record<string, { rooms: number; syncs: number; firstSyncBytes: number; encodeUsPerRoomSyncNode: number; fieldTypes: FieldTypes }>;
}

/**
 * Converts every run of a `--capture-views` directory into a capture of B1's frames: per room,
 * one encoder; checkpoint 0 (the joins, the initial sync and the warm-up) is `encodeAll()`, each
 * later checkpoint `encode()` after the changed values are assigned, then `discardChanges()`.
 * Each frame goes to every session (`*`). The projections are copied unchanged. A sync where two
 * players' projections differ is refused: one encoder per room needs every projection equal.
 * With the tuned typing, a first pass over the run's projections picks the field types.
 */
export function convertCapture(source: string, out: string, typing: Typing, now: () => bigint = () => process.hrtime.bigint()): ConvertReport {
    const version = colyseusVersion();
    const report: ConvertReport = { package: "@colyseus/schema", version, typing, runs: {} };
    const runs = fs.readdirSync(source).filter((r) => fs.statSync(path.join(source, r)).isDirectory()).sort();
    if (runs.length === 0) throw new Error(`${source}: no runs`);
    for (const run of runs) {
        const match = run.match(/-(r\d+-p\d+-m\d+(?:-active)?-serial)$/);
        if (!match) throw new Error(`${run}: unexpected run name`);
        const target = path.join(out, `${COLYSEUS_FORMAT}-delta-${match[1]}`);
        fs.mkdirSync(target, { recursive: true });
        const files = fs.readdirSync(path.join(source, run)).filter((f) => /^room-\d+\.ndjson$/.test(f)).sort();
        const rooms = files.map((file) => {
            const lines = fs.readFileSync(path.join(source, run, file), "utf8").split("\n").filter((l) => l.length > 0);
            return { file, header: JSON.parse(lines[0]), lines: lines.slice(1).map((l) => JSON.parse(l)) };
        });
        let types = numberTypes();
        if (typing === "tuned") {
            const ranges = new FieldRanges();
            for (const room of rooms) for (const line of room.lines) for (const p of Object.values(line.projections)) observeProjection(ranges, p as Projection);
            types = ranges.tuned();
        }
        let encodeNs = 0n;
        let syncs = 0;
        let firstSyncBytes = 0;
        for (const { file, header, lines } of rooms) {
            const sessions = Object.keys(header.sessions);
            const state = newServerState(types);
            const encoder = new Encoder(state);
            const output = [JSON.stringify({
                ...header, format: COLYSEUS_FORMAT, message: COLYSEUS_FORMAT, stateUpdate: COLYSEUS_FORMAT,
                colyseus: { package: "@colyseus/schema", version, typing, fieldTypes: types }, sourceFormat: header.format
            })];
            lines.forEach((line, checkpoint) => {
                const projections = Object.values(line.projections) as Projection[];
                const first = canonical(projections[0]);
                if (projections.some((p) => canonical(p) !== first)) throw new Error(`${run}/${file} sync ${line.sync}: players' projections differ`);
                applyProjection(types, state, projections[0]);
                const start = now();
                const bytes = (checkpoint === 0 ? encoder.encodeAll() : encoder.encode()).slice();
                encoder.discardChanges();
                const spent = now() - start;
                const frames = bytes.length > 0 ? [{ to: "*", data: Buffer.from(bytes).toString("base64") }] : [];
                if (checkpoint === 0) {
                    firstSyncBytes += bytes.length * sessions.length;
                } else {
                    encodeNs += spent;
                    syncs += 1;
                }
                output.push(JSON.stringify({ ...line, frames }));
            });
            fs.writeFileSync(path.join(target, file), output.join("\n") + "\n");
        }
        report.runs[path.basename(target)] = {
            rooms: files.length, syncs: files.length ? syncs / files.length : 0, firstSyncBytes,
            encodeUsPerRoomSyncNode: syncs ? Number(encodeNs) / 1000 / syncs : 0, fieldTypes: types
        };
    }
    return report;
}
