import Denque = require('denque');
import { Inject, Injectable } from '@nestjs/common';
import { AssignmentResult } from '../../../infra/contracts/assignment.dto';
import {
  MatchGroup,
  MatchQueue,
  QueuedTicket,
} from '../match-queue';
import { MatchmakingStore } from '../matchmaking-store';

/**
 * In-memory match queue using Denque for FIFO per queueKey.
 * Queued tickets live in memory; assigned tickets are stored via MatchmakingStore (Redis).
 * Per MVP design: single worker, local queue, BullMQ job only triggers processing.
 */
@Injectable()
export class LocalMatchQueue implements MatchQueue {
  /** Map<queueKey, Denque<QueuedTicket>> - FIFO queue per queueKey. */
  private readonly queuesByKey = new Map<string, Denque<QueuedTicket>>();
  /** Map<ticketId, queueKey> - for cancel and getStatus lookup. */
  private readonly ticketToQueueKey = new Map<string, string>();

  constructor(
    @Inject('MatchmakingStore') private readonly store: MatchmakingStore,
  ) {}

  async enqueue(group: MatchGroup): Promise<QueuedTicket> {
    const existingId = await this.store.getGroupTicket(group.groupId);
    if (existingId) {
      const existing = await this.getStatus(existingId);
      if (existing && existing.status === 'queued') return existing;
    }

    const ticketId = `ticket-${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`;
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

    let queue = this.queuesByKey.get(group.queueKey);
    if (!queue) {
      queue = new Denque<QueuedTicket>();
      this.queuesByKey.set(group.queueKey, queue);
    }
    queue.push(ticket);
    this.ticketToQueueKey.set(ticketId, group.queueKey);
    await this.store.setGroupTicket(group.groupId, ticketId);

    return ticket;
  }

  async cancel(ticketId: string): Promise<boolean> {
    const queueKey = this.ticketToQueueKey.get(ticketId);
    if (!queueKey) return false;

    const queue = this.queuesByKey.get(queueKey);
    if (!queue) return false;

    const arr = queue.toArray();
    const idx = arr.findIndex((t: QueuedTicket) => t.ticketId === ticketId);
    if (idx < 0) return false;

    queue.removeOne(idx);
    this.ticketToQueueKey.delete(ticketId);
    const ticket = arr[idx];
    if (ticket) {
      await this.store.removeGroupTicket(ticket.groupId);
      await this.store.removeQueuedTicket(ticketId);
    }
    return true;
  }

  async getStatus(ticketId: string): Promise<QueuedTicket | null> {
    const assigned = await this.store.getAssignedTicket(ticketId);
    if (assigned) return assigned;

    const queueKey = this.ticketToQueueKey.get(ticketId);
    if (!queueKey) return null;

    const queue = this.queuesByKey.get(queueKey);
    if (!queue) return null;

    const arr = queue.toArray();
    const ticket = arr.find((t: QueuedTicket) => t.ticketId === ticketId);
    return ticket ?? null;
  }

  async updateAssignment(
    ticketId: string,
    assignment: AssignmentResult,
  ): Promise<void> {
    const queueKey = this.ticketToQueueKey.get(ticketId);
    if (!queueKey) return;

    const queue = this.queuesByKey.get(queueKey);
    if (!queue) return;

    const arr = queue.toArray();
    const idx = arr.findIndex((t: QueuedTicket) => t.ticketId === ticketId);
    if (idx < 0) return;

    const ticket = arr[idx];
    if (!ticket) return;

    queue.removeOne(idx);
    this.ticketToQueueKey.delete(ticketId);
    await this.store.removeGroupTicket(ticket.groupId);
    await this.store.removeQueuedTicket(ticketId);

    const assigned: QueuedTicket = {
      ...ticket,
      status: 'assigned',
      assignment,
    };
    await this.store.setAssignedTicket(ticketId, assigned);
  }

  async listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]> {
    const queue = this.queuesByKey.get(queueKey);
    if (!queue) return [];
    return queue.toArray();
  }

  async listQueueKeysWithQueued(): Promise<string[]> {
    const keys: string[] = [];
    for (const [key, queue] of this.queuesByKey) {
      if (queue.size() > 0) keys.push(key);
    }
    return keys;
  }

  /** Add ticket from job payload (Option A: API sends job, Worker adds to queue). */
  async addTicketFromJob(ticket: QueuedTicket): Promise<boolean> {
    const existingId = await this.store.getGroupTicket(ticket.groupId);
    if (existingId) {
      const existing = await this.getStatus(existingId);
      if (existing && existing.status === 'queued') return false;
    }

    let queue = this.queuesByKey.get(ticket.queueKey);
    if (!queue) {
      queue = new Denque<QueuedTicket>();
      this.queuesByKey.set(ticket.queueKey, queue);
    }
    queue.push(ticket);
    this.ticketToQueueKey.set(ticket.ticketId, ticket.queueKey);
    await this.store.setGroupTicket(ticket.groupId, ticket.ticketId);
    await this.store.setQueuedTicket(ticket.ticketId, ticket);
    return true;
  }
}
