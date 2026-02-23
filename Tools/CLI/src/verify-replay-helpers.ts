/**
 * Pure helpers for replay verification (base/player position checks).
 * Exported for unit testing.
 */

export const BASE_X = 64;
export const BASE_Y = 36;
export const NEAR_BASE_RADIUS = 25;

export function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const arg of argv) {
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq > 2) {
      out[arg.slice(2, eq)] = arg.slice(eq + 1);
    }
  }
  return out;
}

export function getPositionXY(obj: unknown): { x: number; y: number } | null {
  if (obj == null || typeof obj !== "object") return null;
  const o = obj as Record<string, unknown>;
  const pos = o.position ?? o.v;
  if (pos != null && typeof pos === "object") {
    const p = pos as Record<string, unknown>;
    const v = p.v ?? p;
    if (v != null && typeof v === "object") {
      const vv = v as Record<string, unknown>;
      if (typeof vv.x === "number" && typeof vv.y === "number") {
        const x = vv.x;
        const y = vv.y;
        return { x: x > 1000 ? x / 1000 : x, y: y > 1000 ? y / 1000 : y };
      }
    }
    if (typeof p.x === "number" && typeof p.y === "number") {
      const x = p.x;
      const y = p.y;
      return { x: x > 1000 ? x / 1000 : x, y: y > 1000 ? y / 1000 : y };
    }
  }
  return null;
}

export function distance(x1: number, y1: number, x2: number, y2: number): number {
  return Math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2);
}

export function isBasePositionOk(basePos: { x: number; y: number } | null): boolean {
  if (!basePos) return false;
  return distance(basePos.x, basePos.y, BASE_X, BASE_Y) < 1;
}

export function isNearBase(x: number, y: number): boolean {
  return distance(x, y, BASE_X, BASE_Y) <= NEAR_BASE_RADIUS;
}

export function analyzeReplayState(state: Record<string, unknown> | undefined): {
  basePos: { x: number; y: number } | null;
  baseOk: boolean;
  playerEntries: [string, unknown][];
  nearBaseCount: number;
  playersWithPosition: number;
} {
  if (!state || typeof state !== "object") {
    return {
      basePos: null,
      baseOk: false,
      playerEntries: [],
      nearBaseCount: 0,
      playersWithPosition: 0,
    };
  }
  const base = state.base as Record<string, unknown> | undefined;
  const basePos = base ? getPositionXY(base) : null;
  const baseOk = isBasePositionOk(basePos);
  const players = (state.players as Record<string, unknown>) ?? {};
  const playerEntries = Object.entries(players);
  let nearBaseCount = 0;
  let playersWithPosition = 0;
  for (const [, p] of playerEntries) {
    const pos = getPositionXY(p);
    if (pos) {
      playersWithPosition++;
      if (isNearBase(pos.x, pos.y)) nearBaseCount++;
    }
  }
  return {
    basePos,
    baseOk,
    playerEntries,
    nearBaseCount,
    playersWithPosition,
  };
}
