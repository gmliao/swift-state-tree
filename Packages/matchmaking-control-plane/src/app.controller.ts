import { Controller, Get } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse } from '@nestjs/swagger';

/**
 * Root application controller.
 * Provides health check and other global endpoints.
 */
@ApiTags('health')
@Controller()
export class AppController {
  /**
   * Health check endpoint for load balancers and monitoring.
   */
  @Get('health')
  @ApiOperation({
    summary: 'Health check',
    description: 'Returns ok if the service is running. Used by load balancers and monitoring.',
  })
  @ApiResponse({
    status: 200,
    description: 'Service is healthy',
    schema: { properties: { ok: { type: 'boolean', example: true } }, type: 'object' },
  })
  getHealth() {
    return { ok: true };
  }
}
