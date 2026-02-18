/** Redis channel names for Pub/Sub. */
export const CHANNEL_NAMES = {
  /** Broadcast channel for match.assigned (all nodes subscribe). */
  matchAssigned: 'matchmaking:assigned',
} as const;

/**
 * Per-node inbox channel. Each API subscribes to its own inbox.
 * @param nodeId - Node ID
 * @returns Redis channel name (cd:inbox:{nodeId})
 */
export function nodeInboxChannel(nodeId: string): string {
  return `cd:inbox:${nodeId}`;
}
