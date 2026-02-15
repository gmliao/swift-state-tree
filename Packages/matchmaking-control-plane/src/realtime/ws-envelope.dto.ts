import { AssignmentResult } from '../contracts/assignment.dto';

/** Server-to-client WebSocket event types. */
export type WsEventType = 'match.assigned';

/** Envelope for all server-pushed WebSocket messages. */
export interface WsEnvelope<T = unknown> {
  type: WsEventType;
  v: number;
  data: T;
}

/** Event type for match.assigned. */
export const WS_EVENT_MATCH_ASSIGNED = 'match.assigned' as const;
export const WS_ENVELOPE_VERSION = 1;

/** Build match.assigned envelope. */
export function buildMatchAssignedEnvelope(
  ticketId: string,
  assignment: AssignmentResult,
): WsEnvelope<{ ticketId: string; assignment: AssignmentResult }> {
  return {
    type: WS_EVENT_MATCH_ASSIGNED,
    v: WS_ENVELOPE_VERSION,
    data: { ticketId, assignment },
  };
}
