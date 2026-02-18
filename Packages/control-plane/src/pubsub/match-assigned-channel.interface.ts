import type { AssignmentResult } from '../contracts/assignment.dto';
import type { WsEnvelope } from '../realtime/ws-envelope.dto';

/** Payload for match.assigned channel. */
export interface MatchAssignedPayload {
  ticketId: string;
  envelope: WsEnvelope<{ ticketId: string; assignment: AssignmentResult }>;
}

/** Injection token for DI. */
export const MATCH_ASSIGNED_CHANNEL = 'MatchAssignedChannel' as const;

/**
 * Channel interface: publish (worker) + subscribe (API).
 * MatchmakingService calls publish; RealtimeGateway calls subscribe.
 */
export interface MatchAssignedChannel {
  publish(payload: MatchAssignedPayload): Promise<void>;
  subscribe(handler: (payload: MatchAssignedPayload) => void): void;
}
