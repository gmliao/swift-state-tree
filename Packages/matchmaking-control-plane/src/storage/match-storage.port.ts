import { AssignmentResult } from '../contracts/assignment.dto';

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

/** Port for match storage (queue persistence). */
export interface MatchStoragePort {
  enqueue(group: MatchGroup): Promise<QueuedTicket>;
  cancel(ticketId: string): Promise<boolean>;
  getStatus(ticketId: string): Promise<QueuedTicket | null>;
  updateAssignment(ticketId: string, assignment: AssignmentResult): Promise<void>;
  /** List all queued tickets for a given queueKey (for periodic matchmaking). */
  listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]>;
  /** List all queue keys that have queued tickets. */
  listQueueKeysWithQueued(): Promise<string[]>;
}
