import type { WebSocket } from 'ws';

/**
 * UserSessionRegistry: unified interface for userId→socket with ClusterDirectory integration.
 * - Single-session policy: one userId = one WebSocket (multi-login prohibited)
 * - Same node: new client kicks existing. Cross node: new node sends kick to old node's inbox
 * - Only calls ClusterDirectory when count crosses 0↔1 (avoids redundant register/unregister)
 */
export interface UserSessionRegistry {
  /**
   * Bind a WebSocket to a userId. Registers with ClusterDirectory if first session.
   * Kicks existing session on same node; publishes kick to old node if cross-node.
   * @param client - WebSocket client
   * @param userId - User ID
   */
  bind(client: WebSocket, userId: string): Promise<void>;
  /**
   * Unbind a WebSocket. Unregisters from ClusterDirectory if last session for userId.
   * @param client - WebSocket client
   */
  unbind(client: WebSocket): void;
  /**
   * Refresh ClusterDirectory lease for the client's userId (heartbeat).
   * @param client - WebSocket client
   */
  refreshLease(client: WebSocket): void;
  /**
   * Handle kick command from another node (close WebSocket for userId).
   * Called when node inbox receives KickUserPayload.
   * @param userId - User ID to kick
   */
  handleKick(userId: string): void;
  /**
   * Get WebSocket(s) for a userId. Returns Set of one socket (single-session policy).
   * @param userId - User ID
   * @returns Set of WebSockets or undefined if not connected
   */
  getSockets(userId: string): Set<WebSocket> | undefined;
}

/** NestJS injection token for UserSessionRegistry. */
export const USER_SESSION_REGISTRY = 'UserSessionRegistry' as const;
