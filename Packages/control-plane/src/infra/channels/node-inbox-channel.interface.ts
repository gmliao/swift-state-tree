import type { MatchAssignedPayload } from './match-assigned-channel.interface';

/**
 * Payload to kick a user on another node (multi-login prohibited, cross-node).
 * When a user connects to a new node, the new node publishes this to the old node's inbox.
 */
export interface KickUserPayload {
  /** Discriminator for type guard. */
  type: 'kick';
  /** User ID to kick (close WebSocket). */
  userId: string;
}

/** Union of payload types that can be delivered to a node inbox. */
export type NodeInboxPayload = MatchAssignedPayload | KickUserPayload;

/**
 * Type guard for KickUserPayload.
 * @param p - Payload from node inbox
 * @returns True if payload is a kick command
 */
export function isKickPayload(p: NodeInboxPayload): p is KickUserPayload {
  return (p as KickUserPayload).type === 'kick';
}

/**
 * NodeInboxChannel: per-node Pub/Sub for directed delivery.
 * Each API subscribes to its own inbox (cd:inbox:{nodeId}).
 * Matchmaking/Dispatch publishes to a specific node instead of broadcast.
 */
export interface NodeInboxChannel {
  /**
   * Publish payload to a specific node's inbox.
   * @param nodeId - Target node ID
   * @param payload - MatchAssignedPayload or KickUserPayload
   */
  publish(nodeId: string, payload: NodeInboxPayload): Promise<void>;
  /**
   * Subscribe to this node's inbox. Handler receives all payloads published to this node.
   * @param nodeId - This node's ID
   * @param handler - Callback for each payload
   */
  subscribe(nodeId: string, handler: (payload: NodeInboxPayload) => void): void;
}

/** NestJS injection token for NodeInboxChannel. */
export const NODE_INBOX_CHANNEL = 'NodeInboxChannel' as const;
