/**
 * Matchmaking API error codes.
 * Used in error responses for client handling.
 */
export const ErrorCodes = {
  INVALID_REQUEST: 'INVALID_REQUEST',
  QUEUE_KEY_REQUIRED: 'QUEUE_KEY_REQUIRED',
  GROUP_ID_REQUIRED: 'GROUP_ID_REQUIRED',
  MEMBERS_REQUIRED: 'MEMBERS_REQUIRED',
  TICKET_NOT_FOUND: 'TICKET_NOT_FOUND',
  PROVISIONING_FAILED: 'PROVISIONING_FAILED',
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];
