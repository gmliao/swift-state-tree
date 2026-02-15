import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import {
  ApiTags,
  ApiOperation,
  ApiResponse,
  ApiBody,
  ApiParam,
} from '@nestjs/swagger';
import { CancelRequest, EnqueueRequest } from '../contracts/matchmaking.dto';
import {
  EnqueueResponseDto,
  CancelResponseDto,
  StatusResponseDto,
} from '../contracts/matchmaking.dto';
import { MatchmakingService } from './matchmaking.service';

/**
 * Matchmaking API controller.
 * Handles enqueue, cancel, and status polling for the matchmaking queue.
 */
@ApiTags('matchmaking')
@Controller('v1/matchmaking')
export class MatchmakingController {
  constructor(private readonly matchmakingService: MatchmakingService) {}

  /**
   * Enqueue a match group. Returns immediately with ticketId and status "queued".
   * Client should poll GET /status/:ticketId until status becomes "assigned".
   */
  @Post('enqueue')
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({
    summary: 'Enqueue match group',
    description:
      'Add a group to the matchmaking queue. Returns ticketId for status polling. Assignment happens asynchronously via periodic matchmaking tick.',
  })
  @ApiBody({ type: EnqueueRequest })
  @ApiResponse({
    status: 201,
    description: 'Ticket created and queued',
    type: EnqueueResponseDto,
  })
  @ApiResponse({ status: 400, description: 'Validation error' })
  async enqueue(@Body() dto: EnqueueRequest) {
    return this.matchmakingService.enqueue(dto);
  }

  /**
   * Cancel a queued ticket. Only tickets with status "queued" can be cancelled.
   */
  @Post('cancel')
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({
    summary: 'Cancel queued ticket',
    description: 'Cancel a ticket that is still in the queue. Fails if already assigned or cancelled.',
  })
  @ApiBody({ type: CancelRequest })
  @ApiResponse({
    status: 201,
    description: 'Cancellation result',
    type: CancelResponseDto,
  })
  async cancel(@Body() dto: CancelRequest) {
    return this.matchmakingService.cancel(dto.ticketId);
  }

  /**
   * Get ticket status. Poll this endpoint until status is "assigned".
   */
  @Get('status/:ticketId')
  @ApiOperation({
    summary: 'Get ticket status',
    description:
      'Returns current ticket status. Poll until status is "assigned" to get assignment (connectUrl, matchToken, etc.).',
  })
  @ApiParam({ name: 'ticketId', description: 'Ticket ID from enqueue', example: 'ticket-1' })
  @ApiResponse({
    status: 200,
    description: 'Ticket status (queued, assigned, cancelled, or expired)',
    type: StatusResponseDto,
  })
  @ApiResponse({ status: 404, description: 'Ticket not found' })
  async status(@Param('ticketId') ticketId: string) {
    return this.matchmakingService.getStatus(ticketId);
  }
}
