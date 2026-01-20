export function formatSince(date: Date | undefined, nowMs: number = Date.now()): string {
  if (!date) return 'Never'

  const diffMs = Math.max(0, nowMs - date.getTime())

  if (diffMs < 1000) return 'Just now'
  if (diffMs < 60_000) return `${Math.floor(diffMs / 1000)}s ago`
  if (diffMs < 3_600_000) return `${Math.floor(diffMs / 60_000)}m ago`

  return date.toLocaleTimeString()
}
