import { ApiProperty } from '@nestjs/swagger';

/**
 * Result of a successful match assignment.
 * Returned when a queued ticket is matched and provisioned.
 */
export class AssignmentResultDto {
  @ApiProperty({
    description: 'Unique assignment identifier',
    example: 'assign-1709123456789-abc123',
  })
  assignmentId!: string;

  @ApiProperty({
    description: 'JWT token for authenticating with the game server',
    example: 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...',
  })
  matchToken!: string;

  @ApiProperty({
    description: 'WebSocket URL to connect to the game server',
    example: 'ws://localhost:8080/game/hero-defense?landId=hero-defense:room-1',
  })
  connectUrl!: string;

  @ApiProperty({
    description: 'Land identifier for the allocated game session',
    example: 'hero-defense:room-1',
  })
  landId!: string;

  @ApiProperty({
    description: 'Server that hosts the allocated land',
    example: 'game-server-1',
  })
  serverId!: string;

  @ApiProperty({
    description: 'ISO 8601 timestamp when the assignment expires',
    example: '2025-02-14T05:00:00.000Z',
  })
  expiresAt!: string;
}

/**
 * Assignment result type used internally and in API responses.
 */
export interface AssignmentResult {
  assignmentId: string;
  matchToken: string;
  connectUrl: string;
  landId: string;
  serverId: string;
  expiresAt: string;
}
