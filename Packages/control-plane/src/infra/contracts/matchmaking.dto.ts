import {
  IsNotEmpty,
  IsString,
  IsArray,
  IsInt,
  Min,
  IsOptional,
} from 'class-validator';
import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { AssignmentResult } from './assignment.dto';
import { AssignmentResultDto } from './assignment.dto';

/** Ticket status in the matchmaking queue. */
export type TicketStatus = 'queued' | 'assigned' | 'cancelled' | 'expired';

/**
 * Request body for enqueueing a match group.
 * Client sends this to join the matchmaking queue.
 */
export class EnqueueRequest {
  @ApiProperty({
    description: 'Queue identifier (e.g., "standard:asia", "ranked:2v2")',
    example: 'standard:asia',
  })
  @IsNotEmpty({ message: 'queueKey is required' })
  @IsString()
  queueKey!: string;

  @ApiPropertyOptional({
    description:
      'Unique group identifier for dedup and party matching. Omit for solo queue (server generates).',
    example: 'solo-p1',
  })
  @IsOptional()
  @IsString()
  groupId?: string;

  @ApiProperty({
    description: 'Player IDs in this group',
    example: ['p1'],
    type: [String],
  })
  @IsNotEmpty({ message: 'members is required' })
  @IsArray()
  @IsString({ each: true })
  members!: string[];

  @ApiProperty({
    description: 'Number of players in the group (1 for solo)',
    example: 1,
    minimum: 1,
  })
  @IsInt()
  @Min(1)
  groupSize!: number;

  @ApiPropertyOptional({
    description: 'Preferred region for matching',
    example: 'asia',
  })
  @IsOptional()
  @IsString()
  region?: string;

  @ApiPropertyOptional({
    description: 'Additional constraints for matching',
  })
  @IsOptional()
  constraints?: Record<string, unknown>;
}

/**
 * Request body for cancelling a queued ticket.
 */
export class CancelRequest {
  @ApiProperty({
    description: 'Ticket ID returned from enqueue',
    example: 'ticket-1',
  })
  @IsNotEmpty({ message: 'ticketId is required' })
  @IsString()
  ticketId!: string;
}

/**
 * Response when a ticket is queued (enqueue or status poll).
 */
export class EnqueueResponseDto {
  @ApiProperty({ description: 'Ticket ID for status polling', example: 'ticket-1' })
  ticketId!: string;

  @ApiProperty({
    description: 'Current status',
    enum: ['queued'],
    example: 'queued',
  })
  status!: 'queued';
}

/**
 * Response when a ticket is cancelled.
 */
export class CancelResponseDto {
  @ApiProperty({ description: 'Whether the cancellation succeeded', example: true })
  cancelled!: boolean;
}

/**
 * Response for status endpoint.
 * Includes assignment when status is 'assigned'.
 */
export class StatusResponseDto {
  @ApiProperty({ description: 'Ticket ID', example: 'ticket-1' })
  ticketId!: string;

  @ApiProperty({
    description: 'Current ticket status',
    enum: ['queued', 'assigned', 'cancelled', 'expired'],
    example: 'assigned',
  })
  status!: TicketStatus;

  @ApiPropertyOptional({
    description: 'Assignment details (present when status is "assigned")',
    type: () => AssignmentResultDto,
  })
  assignment?: AssignmentResult;
}

/** Status response type used in service layer. */
export interface StatusResponse {
  ticketId: string;
  status: TicketStatus;
  assignment?: AssignmentResult;
}
