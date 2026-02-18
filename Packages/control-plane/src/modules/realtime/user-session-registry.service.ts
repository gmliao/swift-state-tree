import { Inject, Injectable } from '@nestjs/common';
import type { ClusterDirectory } from '../../infra/cluster-directory/cluster-directory.interface';
import { CLUSTER_DIRECTORY } from '../../infra/cluster-directory/cluster-directory.interface';
import { NODE_ID } from '../../infra/config/env.config';
import type { NodeInboxChannel } from '../../infra/channels/node-inbox-channel.interface';
import { NODE_INBOX_CHANNEL } from '../../infra/channels/node-inbox-channel.interface';
import { USER_SESSION_REGISTRY, type UserSessionRegistry } from './user-session-registry.interface';
import type { WebSocket } from 'ws';

const META_KEY = '_userId' as const;
const KICK_CLOSE_CODE = 4000;
const KICK_REASON_SAME_NODE = 'Replaced by new session (multi-login prohibited)';
const KICK_REASON_CROSS_NODE = 'Replaced by new session on another node (multi-login prohibited)';

/**
 * UserSessionRegistry implementation with ClusterDirectory and NodeInbox integration.
 * Enforces single-session policy: one userId = one WebSocket.
 * Same-node: new client closes existing. Cross-node: publishes kick to old node's inbox.
 */
@Injectable()
export class UserSessionRegistryService implements UserSessionRegistry {
  /** One userId = one WebSocket (multi-login prohibited). */
  private readonly userToSocket = new Map<string, WebSocket>();

  constructor(
    @Inject(CLUSTER_DIRECTORY)
    private readonly clusterDirectory: ClusterDirectory,
    @Inject(NODE_INBOX_CHANNEL)
    private readonly nodeInboxChannel: NodeInboxChannel,
    @Inject(NODE_ID)
    private readonly nodeId: string,
  ) {}

  /**
   * Bind client to userId. Kicks existing session (same or cross node), registers with ClusterDirectory.
   * @param client - WebSocket client
   * @param userId - User ID
   */
  async bind(client: WebSocket, userId: string): Promise<void> {
    const prev = (client as unknown as { _userId?: string })[META_KEY];
    if (prev && prev !== userId) {
      this.unbindClient(client, prev);
    }
    const existing = this.userToSocket.get(userId);
    if (existing && existing !== client) {
      existing.close(KICK_CLOSE_CODE, KICK_REASON_SAME_NODE);
    }
    const oldNodeId = await this.clusterDirectory.getNodeId(userId);
    if (oldNodeId && oldNodeId !== this.nodeId) {
      await this.nodeInboxChannel.publish(oldNodeId, {
        type: 'kick',
        userId,
      });
    }
    this.userToSocket.set(userId, client);
    (client as unknown as { _userId: string })[META_KEY] = userId;
    if (!existing) {
      this.clusterDirectory.registerSession(userId, this.nodeId).catch((e) => {
        console.error('[UserSessionRegistry] registerSession failed:', e);
      });
    }
  }

  /**
   * Handle kick from another node: close WebSocket for userId.
   * @param userId - User ID to kick
   */
  handleKick(userId: string): void {
    const socket = this.userToSocket.get(userId);
    if (socket) {
      socket.close(KICK_CLOSE_CODE, KICK_REASON_CROSS_NODE);
    }
  }

  /**
   * Unbind client. Unregisters from ClusterDirectory if this was the primary session.
   * @param client - WebSocket client
   */
  unbind(client: WebSocket): void {
    const userId = (client as unknown as { _userId?: string })[META_KEY];
    if (!userId) return;
    if (this.userToSocket.get(userId) === client) {
      this.userToSocket.delete(userId);
      this.clusterDirectory.unregisterSession(userId, this.nodeId).catch((e) => {
        console.error('[UserSessionRegistry] unregisterSession failed:', e);
      });
    }
    delete (client as unknown as { _userId?: string })[META_KEY];
  }

  private unbindClient(client: WebSocket, prevUserId: string): void {
    if (this.userToSocket.get(prevUserId) === client) {
      this.userToSocket.delete(prevUserId);
      this.clusterDirectory.unregisterSession(prevUserId, this.nodeId).catch((e) => {
        console.error('[UserSessionRegistry] unregisterSession failed:', e);
      });
    }
  }

  /**
   * Get WebSocket(s) for userId. Returns Set of one socket (single-session policy).
   * @param userId - User ID
   * @returns Set of WebSockets or undefined
   */
  getSockets(userId: string): Set<WebSocket> | undefined {
    const socket = this.userToSocket.get(userId);
    return socket ? new Set([socket]) : undefined;
  }

  /**
   * Refresh ClusterDirectory lease for client's userId (heartbeat).
   * @param client - WebSocket client
   */
  refreshLease(client: WebSocket): void {
    const userId = (client as unknown as { _userId?: string })[META_KEY];
    if (userId && this.userToSocket.get(userId) === client) {
      this.clusterDirectory.refreshLease(userId, this.nodeId).catch((e) => {
        console.error('[UserSessionRegistry] refreshLease failed:', e);
      });
    }
  }
}
