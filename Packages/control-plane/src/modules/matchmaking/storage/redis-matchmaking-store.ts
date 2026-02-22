import { InjectQueue } from '@nestjs/bullmq';
import { Injectable } from '@nestjs/common';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../../../infra/contracts/assignment.dto';
import { QueuedTicket } from '../match-queue';
import { MatchmakingStore } from '../matchmaking-store';

const GROUP_TO_TICKET_KEY = 'matchmaking:groupToTicket';
const ASSIGNED_KEY_PREFIX = 'matchmaking:assigned:';
const QUEUED_KEY = 'matchmaking:queued';

/** TTL in seconds for assignment keys. Align with JWT exp (1h) to avoid "token valid but status not found". */
const ASSIGNMENT_TTL_SECONDS = 3600;

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
    const key = `${ASSIGNED_KEY_PREFIX}${ticketId}`;
    const raw = await redis.get(key);
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
    const key = `${ASSIGNED_KEY_PREFIX}${ticketId}`;
    await redis.set(key, JSON.stringify(ticket), 'EX', ASSIGNMENT_TTL_SECONDS);
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

  async listAllQueuedTickets(): Promise<QueuedTicket[]> {
    const redis = await this.getRedis();
    const raw = await redis.hgetall(QUEUED_KEY);
    if (!raw || Object.keys(raw).length === 0) return [];
    return Object.values(raw).map((v) => {
      const t = JSON.parse(v as string) as QueuedTicket;
      t.createdAt = new Date(t.createdAt as unknown as string);
      return t;
    });
  }
}
