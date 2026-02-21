import { Inject, Injectable } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../../../infra/contracts/assignment.dto';
import {
  MatchGroup,
  MatchQueue,
  QueuedTicket,
} from '../match-queue';
import { MatchmakingStore } from '../matchmaking-store';

/** Job names for enqueueTicket queue. */
export const ENQUEUE_JOB = 'enqueue';
export const CANCEL_JOB = 'cancel';

/** Payload for enqueue job (Option A: API sends full payload, Worker adds to queue). */
export interface EnqueueJobPayload {
  ticketId: string;
  groupId: string;
  queueKey: string;
  members: string[];
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

/** Payload for cancel job. */
export interface CancelJobPayload {
  ticketId: string;
}

/**
 * API-only MatchQueue implementation.
 * Adds jobs to BullMQ; Worker (on another instance) processes and owns LocalMatchQueue.
 * getStatus reads from Redis (queued + assigned).
 */
@Injectable()
export class ApiMatchQueue implements MatchQueue {
  constructor(
    @Inject('MatchmakingStore') private readonly store: MatchmakingStore,
    @InjectQueue('enqueueTicket') private readonly queue: Queue,
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

    await this.store.setGroupTicket(group.groupId, ticketId);
    await this.store.setQueuedTicket(ticketId, ticket);

    const payload: EnqueueJobPayload = {
      ticketId,
      groupId: group.groupId,
      queueKey: group.queueKey,
      members: group.members,
      groupSize: group.groupSize,
      region: group.region,
      constraints: group.constraints,
    };
    await this.queue.add(ENQUEUE_JOB, payload, { jobId: ticketId });
    return ticket;
  }

  async cancel(ticketId: string): Promise<boolean> {
    const existing = await this.getStatus(ticketId);
    if (!existing || existing.status !== 'queued') return false;
    // Update store immediately so getStatus returns null before worker processes cancel job.
    await this.store.removeQueuedTicket(ticketId);
    await this.store.removeGroupTicket(existing.groupId);
    await this.queue.add(CANCEL_JOB, { ticketId } as CancelJobPayload);
    return true;
  }

  async getStatus(ticketId: string): Promise<QueuedTicket | null> {
    const assigned = await this.store.getAssignedTicket(ticketId);
    if (assigned) return assigned;
    return this.store.getQueuedTicket(ticketId);
  }

  async updateAssignment(_ticketId: string, _assignment: AssignmentResult): Promise<void> {
    // API instance never updates assignment; Worker does.
  }

  async listQueuedByQueue(_queueKey: string): Promise<QueuedTicket[]> {
    return [];
  }

  async listQueueKeysWithQueued(): Promise<string[]> {
    return [];
  }
}
