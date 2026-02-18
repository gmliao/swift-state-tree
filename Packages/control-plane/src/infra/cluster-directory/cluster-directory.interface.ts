/**
 * ClusterDirectory: userId → nodeId mapping with TTL lease.
 * Gateway registers on connect; heartbeat refreshes lease.
 * Used for routing messages (e.g. match.assigned, sendToUser) to the correct API node.
 */
export interface ClusterDirectory {
  /**
   * Register a user session on a node. Overwrites previous mapping.
   * @param userId - User ID
   * @param nodeId - Node ID where user is connected
   * @param ttlSeconds - Lease TTL (default from env)
   */
  registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  /**
   * Refresh lease for an existing session.
   * @param userId - User ID
   * @param nodeId - Node ID
   * @param ttlSeconds - Lease TTL
   */
  refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  /**
   * Get node ID for a user. Returns null if not registered.
   * @param userId - User ID
   * @returns Node ID or null
   */
  getNodeId(userId: string): Promise<string | null>;
  /**
   * Unregister a user session. Only removes if value matches nodeId.
   * @param userId - User ID
   * @param nodeId - Node ID to unregister
   */
  unregisterSession(userId: string, nodeId: string): Promise<void>;
}

/** NestJS injection token for ClusterDirectory. */
export const CLUSTER_DIRECTORY = 'ClusterDirectory' as const;
