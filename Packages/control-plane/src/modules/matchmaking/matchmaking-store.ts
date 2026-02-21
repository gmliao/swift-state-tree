import { QueuedTicket } from './match-queue';

/**
 * Store for matchmaking data (group dedup, assigned tickets).
 * Persists to Redis or in-memory; used by LocalMatchQueue.
 */
export interface MatchmakingStore {
  /** Get ticketId for groupId if already queued. */
  getGroupTicket(groupId: string): Promise<string | null>;

  /** Associate groupId with ticketId. */
  setGroupTicket(groupId: string, ticketId: string): Promise<void>;

  /** Remove groupId association (on cancel or assign). */
  removeGroupTicket(groupId: string): Promise<void>;

  /** Get assigned ticket by ticketId (for status polling). */
  getAssignedTicket(ticketId: string): Promise<QueuedTicket | null>;

  /** Store assigned ticket (after match is formed). */
  setAssignedTicket(ticketId: string, ticket: QueuedTicket): Promise<void>;

  /** Get queued ticket by ticketId (for API-only instances, status polling). */
  getQueuedTicket(ticketId: string): Promise<QueuedTicket | null>;

  /** Store queued ticket (when Worker adds from job payload). */
  setQueuedTicket(ticketId: string, ticket: QueuedTicket): Promise<void>;

  /** Remove queued ticket (on cancel or assign). */
  removeQueuedTicket(ticketId: string): Promise<void>;

  /** List all queued tickets (for admin dashboard). */
  listAllQueuedTickets(): Promise<QueuedTicket[]>;
}
