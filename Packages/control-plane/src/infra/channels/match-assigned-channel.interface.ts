import type { WsEnvelope, WsMatchAssignedResponse } from '../../modules/realtime/ws-envelope.dto';

/**
 * Payload for match.assigned channel (broadcast or node inbox).
 * Contains ticket ID and the WebSocket envelope to push to clients.
 */
export interface MatchAssignedPayload {
  /** Matchmaking ticket ID. */
  ticketId: string;
  /** WebSocket envelope (type, version, data) to send to subscribed clients. */
  envelope: WsEnvelope<WsMatchAssignedResponse>;
}

/** NestJS injection token for MatchAssignedChannel. */
export const MATCH_ASSIGNED_CHANNEL = 'MatchAssignedChannel' as const;

/**
 * Channel interface for match.assigned delivery.
 * - Publish: MatchmakingService (worker) publishes when match is found.
 * - Subscribe: RealtimeGateway subscribes and pushes to clients with matching ticketId.
 * Supports broadcast (all nodes) or node inbox (routed to specific node when USE_NODE_INBOX_FOR_MATCH_ASSIGNED=true).
 */
export interface MatchAssignedChannel {
  /**
   * Publish match.assigned payload (broadcast to all subscribers).
   * @param payload - Ticket ID and envelope
   */
  publish(payload: MatchAssignedPayload): Promise<void>;
  /**
   * Subscribe to match.assigned events. Handler receives all published payloads.
   * @param handler - Callback for each payload
   */
  subscribe(handler: (payload: MatchAssignedPayload) => void): void;
}
