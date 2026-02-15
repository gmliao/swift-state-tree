import { InjectQueue } from '@nestjs/bullmq';
import { Injectable } from '@nestjs/common';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../contracts/assignment.dto';
import {
  MatchGroup,
  MatchStoragePort,
  QueuedTicket,
} from './match-storage.port';

const TICKETS_KEY = 'matchmaking:tickets';
const GROUP_TO_TICKET_KEY = 'matchmaking:groupToTicket';
const QUEUED_BY_QUEUE_PREFIX = 'matchmaking:queued:';
const TICKET_COUNTER_KEY = 'matchmaking:ticketCounter';

@Injectable()
export class RedisMatchStorage implements MatchStoragePort {
  constructor(
    @InjectQueue('matchmaking-tickets') private readonly queue: Queue,
  ) {}

  private async getRedis() {
    return this.queue.client;
  }

  async enqueue(group: MatchGroup): Promise<QueuedTicket> {
    const redis = await this.getRedis();
    const existing = await redis.hget(GROUP_TO_TICKET_KEY, group.groupId);
    if (existing) {
      const raw = await redis.hget(TICKETS_KEY, existing);
      if (raw) {
        const ticket = JSON.parse(raw) as QueuedTicket;
        ticket.createdAt = new Date(ticket.createdAt as unknown as string);
        if (ticket.status === 'queued') return ticket;
      }
    }

    const id = await redis.incr(TICKET_COUNTER_KEY);
    const ticketId = `ticket-${id}`;
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
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hset(GROUP_TO_TICKET_KEY, group.groupId, ticketId);
    await redis.sadd(QUEUED_BY_QUEUE_PREFIX + group.queueKey, ticketId);
    return ticket;
  }

  async cancel(ticketId: string): Promise<boolean> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return false;
    const ticket = JSON.parse(raw) as QueuedTicket;
    if (ticket.status !== 'queued') return false;
    ticket.status = 'cancelled';
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hdel(GROUP_TO_TICKET_KEY, ticket.groupId);
    await redis.srem(QUEUED_BY_QUEUE_PREFIX + ticket.queueKey, ticketId);
    return true;
  }

  async getStatus(ticketId: string): Promise<QueuedTicket | null> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return null;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.createdAt = new Date(ticket.createdAt as unknown as string);
    if (ticket.assignment) {
      ticket.assignment = ticket.assignment as AssignmentResult;
    }
    return ticket;
  }

  async updateAssignment(
    ticketId: string,
    assignment: AssignmentResult,
  ): Promise<void> {
    const redis = await this.getRedis();
    const raw = await redis.hget(TICKETS_KEY, ticketId);
    if (!raw) return;
    const ticket = JSON.parse(raw) as QueuedTicket;
    ticket.assignment = assignment;
    ticket.status = 'assigned';
    await redis.hset(TICKETS_KEY, ticketId, JSON.stringify(ticket));
    await redis.hdel(GROUP_TO_TICKET_KEY, ticket.groupId);
    await redis.srem(QUEUED_BY_QUEUE_PREFIX + ticket.queueKey, ticketId);
  }

  async listQueuedByQueue(queueKey: string): Promise<QueuedTicket[]> {
    const redis = await this.getRedis();
    const ids = await redis.smembers(QUEUED_BY_QUEUE_PREFIX + queueKey);
    const tickets: QueuedTicket[] = [];
    for (const id of ids) {
      const raw = await redis.hget(TICKETS_KEY, id);
      if (!raw) continue;
      const t = JSON.parse(raw) as QueuedTicket;
      t.createdAt = new Date(t.createdAt as unknown as string);
      if (t.status === 'queued') tickets.push(t);
    }
    return tickets;
  }

  async listQueueKeysWithQueued(): Promise<string[]> {
    const redis = await this.getRedis();
    const keys = await redis.keys(QUEUED_BY_QUEUE_PREFIX + '*');
    const queueKeys: string[] = [];
    for (const k of keys) {
      const count = await redis.scard(k);
      if (count > 0) {
        queueKeys.push(k.replace(QUEUED_BY_QUEUE_PREFIX, ''));
      }
    }
    return queueKeys;
  }
}
