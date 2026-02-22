import { IsArray, IsInt, IsNotEmpty, IsOptional, IsString, Min } from 'class-validator';
import { AssignmentResult } from '../../infra/contracts/assignment.dto';

/** Server-to-client WebSocket event types. */
export type WsEventType = 'match.assigned' | 'enqueued';

/**
 * Envelope for all server-pushed WebSocket messages.
 * @template T - Data payload type
 */
export interface WsEnvelope<T = unknown> {
  /** Event type. */
  type: WsEventType;
  /** Schema version. */
  v: number;
  /** Event payload. */
  data: T;
}

/** Event type for match.assigned. */
export const WS_EVENT_MATCH_ASSIGNED = 'match.assigned' as const;
/** Event type for enqueued (response to client enqueue via WS). */
export const WS_EVENT_ENQUEUED = 'enqueued' as const;
/** Current envelope schema version. */
export const WS_ENVELOPE_VERSION = 1;

/**
 * Server-to-client: enqueued response (data part of envelope).
 * Response to WsEnqueueMessage.
 */
export interface WsEnqueuedResponse {
  ticketId: string;
  status: 'queued';
}

/**
 * Server-to-client: match.assigned push (data part of envelope).
 * Pushed when matchmaking assigns a ticket.
 */
export interface WsMatchAssignedResponse {
  ticketId: string;
  assignment: AssignmentResult;
}

/**
 * Server-to-client: error message (not in WsEnvelope format).
 * Sent when request fails (e.g. invalid JSON, enqueue failed).
 */
export interface WsErrorResponse {
  type: 'error';
  message: string;
}

/**
 * Client-to-server: enqueue via WebSocket (avoids race: connect first, then enqueue).
 */
export interface WsEnqueueMessage {
  action: 'enqueue';
  groupId?: string;
  queueKey: string;
  members: string[];
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

/** Validated DTO for WsEnqueueMessage. Use plainToInstance + validate before calling handleEnqueue. */
export class WsEnqueueMessageDto implements WsEnqueueMessage {
  action!: 'enqueue';

  @IsOptional()
  @IsString()
  groupId?: string;

  @IsNotEmpty({ message: 'queueKey is required' })
  @IsString()
  queueKey!: string;

  @IsNotEmpty({ message: 'members is required' })
  @IsArray()
  @IsString({ each: true })
  members!: string[];

  @IsInt()
  @Min(1)
  groupSize!: number;

  @IsOptional()
  @IsString()
  region?: string;

  @IsOptional()
  constraints?: Record<string, unknown>;
}

/** Client-to-server: heartbeat to refresh ClusterDirectory lease. */
export interface WsHeartbeatMessage {
  action: 'heartbeat';
}

/**
 * Build match.assigned envelope for WebSocket push.
 * @param ticketId - Matchmaking ticket ID
 * @param assignment - Assignment result (connectUrl, landId, matchToken, etc.)
 * @returns WebSocket envelope
 */
export function buildMatchAssignedEnvelope(
  ticketId: string,
  assignment: AssignmentResult,
): WsEnvelope<WsMatchAssignedResponse> {
  return {
    type: WS_EVENT_MATCH_ASSIGNED,
    v: WS_ENVELOPE_VERSION,
    data: { ticketId, assignment },
  };
}

/**
 * Build enqueued envelope (response to WS enqueue).
 * @param ticketId - Matchmaking ticket ID
 * @returns WebSocket envelope
 */
export function buildEnqueuedEnvelope(ticketId: string): WsEnvelope<WsEnqueuedResponse> {
  return {
    type: WS_EVENT_ENQUEUED,
    v: WS_ENVELOPE_VERSION,
    data: { ticketId, status: 'queued' },
  };
}
