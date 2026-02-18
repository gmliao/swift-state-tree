import { AssignmentResult } from '../../infra/contracts/assignment.dto';

/** Match group submitted for enqueue. */
export interface MatchGroup {
  groupId: string;
  queueKey: string;
  members: string[];
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

/** Ticket in the matchmaking queue with optional assignment. */
export interface QueuedTicket {
  ticketId: string;
  groupId: string;
  queueKey: string;
  members: string[];
  groupSize: number;
  region?: string;
  status: 'queued' | 'assigned' | 'cancelled' | 'expired';
  assignment?: AssignmentResult;
  createdAt: Date;
}

/** Match queue interface (enqueue, cancel, status, assignment). */
export interface MatchQueue {
  enqueue(group: MatchGroup): Promise<QueuedTicket>;
  cancel(ticketId: string): Promise<boolean>;
  getStatus(ticketId: string): Promise<QueuedTicket | null>;
  updateAssignment(ticketId: string, assignment: AssignmentResult): Promise<void>;
  /** List all queued tickets for a given queueKey (for periodic matchmaking). */
  listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]>;
  /** List all queue keys that have queued tickets. */
  listQueueKeysWithQueued(): Promise<string[]>;
  /**
   * Add ticket from job payload (queue-worker only). Used when MATCHMAKING_ROLE=api sends job.
   * Returns false if groupId already queued (dedup).
   */
  addTicketFromJob?(ticket: QueuedTicket): Promise<boolean>;
}
