/**
 * UserIdDirectory: userId → nodeId mapping with TTL lease.
 * Gateway registers on connect; heartbeat refreshes lease.
 * Used for routing messages (e.g. match.assigned, sendToUser) to the correct API node.
 */
export interface UserIdDirectory {
  registerSession(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  refreshLease(userId: string, nodeId: string, ttlSeconds?: number): Promise<void>;
  getNodeId(userId: string): Promise<string | null>;
  unregisterSession(userId: string, nodeId: string): Promise<void>;
}

export const USER_ID_DIRECTORY = 'UserIdDirectory' as const;
