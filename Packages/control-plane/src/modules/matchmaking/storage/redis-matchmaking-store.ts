import { InjectQueue } from '@nestjs/bullmq';
import { Injectable } from '@nestjs/common';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../../../infra/contracts/assignment.dto';
import { QueuedTicket } from '../match-queue';
import { MatchmakingStore } from '../matchmaking-store';

const GROUP_TO_TICKET_KEY = 'matchmaking:groupToTicket';
const ASSIGNED_KEY = 'matchmaking:assigned';
const QUEUED_KEY = 'matchmaking:queued';

/**
 * Redis-backed implementation of MatchmakingStore.
 * Uses enqueueTicket queue's Redis client (group dedup, assigned tickets).
 */
@Injectable()
export class RedisMatchmakingStore implements MatchmakingStore {
  constructor(
    @InjectQueue('enqueueTicket') private readonly queue: Queue,
  ) {}

  private async getRedis() {
    return this.queue.client;
  }

  async getGroupTicket(groupId: string): Promise<string | null> {
    const redis = await this.getRedis();
    const id = await redis.hget(GROUP_TO_TICKET_KEY, groupId);
    return id;
  }

  async setGroupTicket(groupId: string, ticketId: string): Promise<void> {
    const redis = await this.getRedis();
    await redis.hset(GROUP_TO_TICKET_KEY, groupId, ticketId);
  }

  async removeGroupTicket(groupId: string): Promise<void> {
    const redis = await this.getRedis();
    await redis.hdel(GROUP_TO_TICKET_KEY, groupId);
  }

  async getAssignedTicket(ticketId: string): Promise<QueuedTicket | null> {
    const redis = await this.getRedis();
    const raw = await redis.hget(ASSIGNED_KEY, ticketId);
    if (!raw) return null;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.createdAt = new Date(ticket.createdAt as unknown as string);
    if (ticket.assignment) {
      ticket.assignment = ticket.assignment as AssignmentResult;
    }
    return ticket;
  }

  async setAssignedTicket(ticketId: string, ticket: QueuedTicket): Promise<void> {
    const redis = await this.getRedis();
    await redis.hset(ASSIGNED_KEY, ticketId, JSON.stringify(ticket));
  }

  async getQueuedTicket(ticketId: string): Promise<QueuedTicket | null> {
    const redis = await this.getRedis();
    const raw = await redis.hget(QUEUED_KEY, ticketId);
    if (!raw) return null;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.createdAt = new Date(ticket.createdAt as unknown as string);
    return ticket;
  }

  async setQueuedTicket(ticketId: string, ticket: QueuedTicket): Promise<void> {
    const redis = await this.getRedis();
    await redis.hset(QUEUED_KEY, ticketId, JSON.stringify(ticket));
  }

  async removeQueuedTicket(ticketId: string): Promise<void> {
    const redis = await this.getRedis();
    await redis.hdel(QUEUED_KEY, ticketId);
  }
}
