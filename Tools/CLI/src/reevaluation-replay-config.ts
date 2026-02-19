export type ReplayE2EArgs = Record<string, string | boolean>;

const DEFAULT_TIMEOUT_MS = 60000;
const DEFAULT_REPLAY_IDLE_MS = 1500;

function parsePositiveNumber(value: string | boolean | undefined): number | null {
  if (typeof value !== "string") {
    return null;
  }

  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return null;
  }

  return parsed;
}

export function parseReplayE2EConfig(args: ReplayE2EArgs): { timeoutMs: number; replayIdleMs: number } {
  const timeoutMs = parsePositiveNumber(args["timeout-ms"]) ?? DEFAULT_TIMEOUT_MS;
  const replayIdleMs = parsePositiveNumber(args["replay-idle-ms"]) ?? DEFAULT_REPLAY_IDLE_MS;
  return { timeoutMs, replayIdleMs };
}

