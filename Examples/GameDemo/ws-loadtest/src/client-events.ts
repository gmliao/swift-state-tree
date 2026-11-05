import { hash32 } from "./connect-schedule";

/**
 * Client events a scenario sends next to its actions (`events` in the scenario). Events get no
 * response, so they never enter RTT; RTT stays on the actions. Each event has its own rate per
 * player and its own spread schedule (`SendSchedule`, keyed by event name and connection).
 */
export interface EventConfig {
    /** The event's type identifier on the wire (e.g. `MoveTo`). */
    name: string;
    /** Sends per second per player. */
    ratePerSecond: number;
    /** A named payload generator (`PAYLOAD_GENERATORS`); without one, the payload is `{}`. */
    payloadGenerator?: string;
}

/** A deterministic PRNG returning floats in `[0, 1)` (mulberry32). */
export type Random = () => number;

export function mulberry32(seed: number): Random {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6d2b79f5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 0x1_0000_0000;
    };
}

/**
 * One connection's PRNG for one event: seeded from the run seed, the event name and the
 * connection key. With the same seed a connection's n-th payload is the same in every run; how
 * many it sends depends on its join time, so runs share a prefix of the sequence, not its length.
 */
export function eventRandom(runSeed: number, eventName: string, connectionKey: string): Random {
    return mulberry32(hash32(`${runSeed >>> 0}:${eventName}:${connectionKey}`));
}

/** The hero-defense world, in world units (`GameConfig.WORLD_WIDTH` / `WORLD_HEIGHT`). */
export const HERO_DEFENSE_WORLD = { width: 128, height: 72 } as const;

/** The visibility-test arena, in world units (`VisibilityTestConfig.arenaSize` on both axes). */
export const VISIBILITY_TEST_ARENA = { width: 100, height: 100 } as const;

/** A point drawn uniformly inside `[0, width) × [0, height)`, in world units (floats). */
export function uniformPoint(random: Random, bounds: { width: number; height: number }): { x: number; y: number } {
    return { x: random() * bounds.width, y: random() * bounds.height };
}

/** Builds an event payload from the connection's PRNG. */
export type PayloadGenerator = (random: Random) => Record<string, unknown>;

/** The SDK's fixed-point types, as `sdk/core` exports them. */
export interface FixedPointTypes {
    IVec2: new (x: number, y: number, isFixedPoint?: boolean) => unknown;
    Position2: new (v: any, isFixedPoint?: boolean) => { toJSON(): unknown };
}

/**
 * Loads the SDK's fixed-point types, once per process. The SDK is ESM and this tool is
 * CommonJS, so this is a native dynamic import (kept as one by `module: Node16`). It names the
 * self-contained `core/deterministic-math` module: the `core` index re-exports without file
 * extensions, which only bundlers resolve, not Node.
 */
export async function loadFixedPointTypes(): Promise<FixedPointTypes> {
    const math = await import("@swiftstatetree/sdk/core/deterministic-math");
    return { IVec2: math.IVec2, Position2: math.Position2 };
}

/**
 * The payload generators a scenario can name. `moveTo` gives a `MoveToEvent` (generated client
 * type) whose target is drawn uniformly inside the hero-defense world, and `moveViewer` a
 * visibility-test `MoveViewerEvent` whose position is drawn uniformly inside its arena. Both are
 * encoded by the SDK's `Position2`, so the fixed-point scale is the SDK's, not a hand-written one.
 */
export function payloadGenerators(types: FixedPointTypes): Record<string, PayloadGenerator> {
    return {
        moveTo: (random) => {
            const { x, y } = uniformPoint(random, HERO_DEFENSE_WORLD);
            const target = new types.Position2(new types.IVec2(x, y, false), false);
            const event: MoveToEventWire = { target: target.toJSON() as MoveToEventWire["target"] };
            return event as unknown as Record<string, unknown>;
        },
        moveViewer: (random) => {
            const { x, y } = uniformPoint(random, VISIBILITY_TEST_ARENA);
            const position = new types.Position2(new types.IVec2(x, y, false), false);
            const event: MoveViewerEventWire = { position: position.toJSON() as MoveViewerEventWire["position"] };
            return event as unknown as Record<string, unknown>;
        }
    };
}

/** `MoveToEvent` (`Examples/GameDemo/WebClient/src/generated/defs.ts`) as JSON on the wire. */
type MoveToEventWire = { target: { v: { x: number; y: number } } };

/** `MoveViewerEvent` (visibility-test) as JSON on the wire. */
type MoveViewerEventWire = { position: { v: { x: number; y: number } } };

/** The moving-players overlay: `MoveTo` events with targets from the `moveTo` generator. */
export const MOVE_TO_EVENT_NAME = "MoveTo";
export const MOVE_TO_GENERATOR = "moveTo";

/**
 * The events a run sends: the scenario's, with `--move-to-rate` applied when given. A positive
 * rate sets (or adds) the `MoveTo` event at that rate per player; 0 removes it. Without the
 * flag the scenario's events stand, so any scenario or set of overrides can run with or
 * without moving players.
 */
export function effectiveEvents(scenarioEvents: EventConfig[], moveToRate?: number): EventConfig[] {
    if (moveToRate === undefined) {
        return scenarioEvents;
    }
    const others = scenarioEvents.filter((event) => event.name !== MOVE_TO_EVENT_NAME);
    return moveToRate > 0
        ? [...others, { name: MOVE_TO_EVENT_NAME, ratePerSecond: moveToRate, payloadGenerator: MOVE_TO_GENERATOR }]
        : others;
}
