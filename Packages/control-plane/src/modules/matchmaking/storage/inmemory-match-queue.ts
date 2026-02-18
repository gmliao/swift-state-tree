import { AssignmentResult } from '../../../infra/contracts/assignment.dto';
import {
  MatchGroup,
  MatchQueue,
  QueuedTicket,
} from '../match-queue';

/**
 * In-memory implementation of MatchQueue.
 * Queue state is lost on restart. Deduplicates by groupId.
 */
export class InMemoryMatchQueue implements MatchQueue {
  private tickets = new Map<string, QueuedTicket>();
  private groupToTicket = new Map<string, string>();
  private ticketCounter = 0;

  /** Adds group to queue. Returns existing ticket if same groupId is already queued. */
  async enqueue(group: MatchGroup): Promise<QueuedTicket> {
    const existing = this.groupToTicket.get(group.groupId);
    if (existing) {
      const ticket = this.tickets.get(existing);
      if (ticket && ticket.status === 'queued') {
        return ticket;
      }
    }

    this.ticketCounter += 1;
    const ticketId = `ticket-${this.ticketCounter}`;
    const ticket: QueuedTicket = {
      ticketId,
      groupId: group.groupId,
      queueKey: group.queueKey,
      members: group.members,
      groupSize: group.groupSize,
      region: group.region,
      status: 'queued',
      createdAt: new Date(),
    };
    this.tickets.set(ticketId, ticket);
    this.groupToTicket.set(group.groupId, ticketId);
    return ticket;
  }

  /** Cancels a queued ticket. Returns false if not found or already assigned/cancelled. */
  async cancel(ticketId: string): Promise<boolean> {
    const ticket = this.tickets.get(ticketId);
    if (!ticket) return false;
    if (ticket.status !== 'queued') return false;
    ticket.status = 'cancelled';
    this.groupToTicket.delete(ticket.groupId);
    return true;
  }

  /** Returns ticket by ID or null if not found. */
  async getStatus(ticketId: string): Promise<QueuedTicket | null> {
    return this.tickets.get(ticketId) ?? null;
  }

  /** Updates ticket with assignment and sets status to "assigned". */
  async updateAssignment(
    ticketId: string,
    assignment: AssignmentResult,
  ): Promise<void> {
    const ticket = this.tickets.get(ticketId);
    if (!ticket) return;
    ticket.assignment = assignment;
    ticket.status = 'assigned';
  }

  /** Returns all queued tickets for the given queue. */
  async listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]> {
    return Array.from(this.tickets.values()).filter(
      (t) => t.status === 'queued' && t.queueKey === queueKey,
    );
  }

  /** Returns queue keys that have at least one queued ticket. */
  async listQueueKeysWithQueued(): Promise<string[]> {
    const keys = new Set<string>();
    for (const t of this.tickets.values()) {
      if (t.status === 'queued') keys.add(t.queueKey);
    }
    return Array.from(keys);
  }
}
