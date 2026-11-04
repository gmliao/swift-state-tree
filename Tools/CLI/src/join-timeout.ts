/**
 * Join with a deadline. `StateTreeView.join()` waits for the server's join response with no
 * timeout, so a lost response would hang a CLI run (and a CI job) indefinitely. This fails it
 * instead, with the land ID in the error.
 */

export const DEFAULT_JOIN_TIMEOUT_MS = 15_000

/** Timeout in milliseconds: `CLI_JOIN_TIMEOUT_MS` when set to a positive number, else the default. */
export function joinTimeoutMs(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env.CLI_JOIN_TIMEOUT_MS
  const parsed = raw === undefined ? NaN : Number(raw)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_JOIN_TIMEOUT_MS
}

interface Joinable<R> {
  join(): Promise<R>
}

export async function joinWithTimeout<R>(
  view: Joinable<R>,
  landID: string,
  timeoutMs: number = joinTimeoutMs()
): Promise<R> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      reject(new Error(`Join timed out after ${timeoutMs} ms: no join response for ${landID}`))
    }, timeoutMs)
  })
  try {
    return await Promise.race([view.join(), timeout])
  } finally {
    clearTimeout(timer)
  }
}
