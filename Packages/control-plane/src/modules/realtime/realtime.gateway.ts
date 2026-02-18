import { Inject, forwardRef } from '@nestjs/common';
import type { OnModuleInit } from '@nestjs/common';
import {
  WebSocketGateway,
  WebSocketServer,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { MatchmakingService } from '../matchmaking/matchmaking.service';
import { MATCH_ASSIGNED_CHANNEL } from '../../infra/channels/match-assigned-channel.interface';
import type { MatchAssignedChannel } from '../../infra/channels/match-assigned-channel.interface';
import { isKickPayload, NODE_INBOX_CHANNEL } from '../../infra/channels/node-inbox-channel.interface';
import type { NodeInboxChannel } from '../../infra/channels/node-inbox-channel.interface';
import { NODE_ID } from '../../infra/config/env.config';
import { USER_SESSION_REGISTRY } from './user-session-registry.interface';
import type { UserSessionRegistry } from './user-session-registry.interface';
import { buildEnqueuedEnvelope, type WsErrorResponse } from './ws-envelope.dto';
import type { WsEnqueueMessage } from './ws-envelope.dto';
import { Server, WebSocket as WsWebSocket } from 'ws';
import { IncomingMessage } from 'http';

/** Maps ticketId -> Set of WebSocket clients subscribed to that ticket. */
const ticketSubscriptions = new Map<string, Set<WsWebSocket>>();

/** Client metadata attached to WebSocket. */
interface ClientMeta {
  _ticketId?: string;
  _userId?: string;
}

/**
 * Get metadata object from WebSocket client.
 * @param client - WebSocket client
 * @returns Client metadata
 */
function getMeta(client: WsWebSocket): ClientMeta {
  return client as unknown as ClientMeta;
}

/**
 * RealtimeGateway: WebSocket entry for matchmaking.
 * - Subscribes to MatchAssignedChannel (broadcast) and NodeInboxChannel (routed).
 * - Pushes match.assigned to clients subscribed by ticketId.
 * - Handles kick payloads from node inbox (multi-login prohibited, cross-node).
 */
@WebSocketGateway({ path: '/realtime' })
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect, OnModuleInit {
  @WebSocketServer()
  server!: Server;

  constructor(
    @Inject(forwardRef(() => MatchmakingService))
    private readonly matchmakingService: MatchmakingService,
    @Inject(MATCH_ASSIGNED_CHANNEL)
    private readonly matchAssignedChannel: MatchAssignedChannel,
    @Inject(NODE_INBOX_CHANNEL)
    private readonly nodeInboxChannel: NodeInboxChannel,
    @Inject(USER_SESSION_REGISTRY)
    private readonly userSessionRegistry: UserSessionRegistry,
    @Inject(NODE_ID)
    private readonly nodeId: string,
  ) {}

  /**
   * Subscribe to match.assigned (broadcast) and node inbox (routed + kick).
   * Node inbox: kick -> handleKick; match.assigned -> pushMatchAssigned.
   */
  onModuleInit(): void {
    this.matchAssignedChannel.subscribe((payload) => {
      this.pushMatchAssigned(payload.ticketId, payload.envelope);
    });
    this.nodeInboxChannel.subscribe(this.nodeId, (payload) => {
      if (isKickPayload(payload)) {
        this.userSessionRegistry.handleKick(payload.userId);
      } else {
        this.pushMatchAssigned(payload.ticketId, payload.envelope);
      }
    });
  }

  handleConnection(client: WsWebSocket, request: IncomingMessage) {
    const url = new URL(request.url ?? '', `http://${request.headers.host}`);
    const ticketId = url.searchParams.get('ticketId');
    const userId = url.searchParams.get('userId');

    if (userId) {
      this.userSessionRegistry.bind(client, userId).catch((e) => {
        console.error('[RealtimeGateway] bind failed:', e);
      });
    }

    if (ticketId) {
      this.subscribeClient(client, ticketId);
    } else {
      getMeta(client)._ticketId = undefined;
      this.setupMessageHandler(client);
    }
  }

  private subscribeClient(client: WsWebSocket, ticketId: string): void {
    const prev = getMeta(client)._ticketId;
    if (prev) {
      ticketSubscriptions.get(prev)?.delete(client);
    }
    let set = ticketSubscriptions.get(ticketId);
    if (!set) {
      set = new Set();
      ticketSubscriptions.set(ticketId, set);
    }
    set.add(client);
    getMeta(client)._ticketId = ticketId;
  }

  private setupMessageHandler(client: WsWebSocket): void {
    client.on('message', (data: Buffer | string) => {
      let msg: unknown;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        this.sendError(client, 'Invalid JSON');
        return;
      }
      const m = msg as { action?: string };
      if (m?.action === 'enqueue') {
        this.handleEnqueue(client, m as WsEnqueueMessage);
        return;
      }
      if (m?.action === 'heartbeat') {
        this.handleHeartbeat(client);
        return;
      }
      this.sendError(client, 'Expected action: enqueue or heartbeat');
    });
  }

  private async handleEnqueue(client: WsWebSocket, m: WsEnqueueMessage): Promise<void> {
    try {
      const result = await this.matchmakingService.enqueue(
        {
          groupId: m.groupId,
          queueKey: m.queueKey,
          members: m.members,
          groupSize: m.groupSize,
          region: m.region,
          constraints: m.constraints,
        },
        (ticketId) => this.subscribeClient(client, ticketId),
      );
      const primaryUserId = m.members?.[0];
      if (primaryUserId && !getMeta(client)._userId) {
        this.userSessionRegistry.bind(client, primaryUserId).catch((e) => {
          console.error('[RealtimeGateway] bind failed:', e);
        });
      }
      client.send(JSON.stringify(buildEnqueuedEnvelope(result.ticketId)));
    } catch (err) {
      this.sendError(client, err instanceof Error ? err.message : 'Enqueue failed');
    }
  }

  private handleHeartbeat(client: WsWebSocket): void {
    this.userSessionRegistry.refreshLease(client);
  }

  private sendError(client: WsWebSocket, message: string): void {
    if (client.readyState === 1) {
      const payload: WsErrorResponse = { type: 'error', message };
      client.send(JSON.stringify(payload));
    }
  }

  handleDisconnect(client: WsWebSocket) {
    const ticketId = getMeta(client)._ticketId;
    if (ticketId) {
      const set = ticketSubscriptions.get(ticketId);
      if (set) {
        set.delete(client);
        if (set.size === 0) ticketSubscriptions.delete(ticketId);
      }
    }
    this.userSessionRegistry.unbind(client);
  }

  /**
   * Push match.assigned envelope to all clients subscribed to this ticketId.
   * @param ticketId - Matchmaking ticket ID
   * @param envelope - WebSocket envelope (type, v, data)
   */
  pushMatchAssigned(ticketId: string, envelope: object): void {
    const set = ticketSubscriptions.get(ticketId);
    if (!set) return;
    const msg = JSON.stringify(envelope);
    for (const ws of set) {
      if (ws.readyState === 1) ws.send(msg);
    }
  }
}
