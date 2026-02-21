import { Controller, Get } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { ServerRegistryService } from '../provisioning/server-registry.service';
import { AdminQueueService } from './admin-queue.service';
import {
  QueueSummaryResponseDto,
  ServerListResponseDto,
} from './dto/admin-response.dto';

/**
 * Read-only admin API for dashboard and monitoring.
 */
@Controller('v1/admin')
@ApiTags('admin')
export class AdminController {
  constructor(
    private readonly registry: ServerRegistryService,
    private readonly queueSummary: AdminQueueService,
  ) {}

  @Get('servers')
  getServers(): ServerListResponseDto {
    const list = this.registry.listAllServers();
    return {
      servers: list.map((e) => ({
        serverId: e.serverId,
        host: e.host,
        port: e.port,
        landType: e.landType,
        connectHost: e.connectHost,
        connectPort: e.connectPort,
        connectScheme: e.connectScheme,
        registeredAt: e.registeredAt.toISOString(),
        lastSeenAt: e.lastSeenAt.toISOString(),
        isStale: e.isStale,
      })),
    };
  }

  @Get('queue/summary')
  async getQueueSummary(): Promise<QueueSummaryResponseDto> {
    return this.queueSummary.getQueueSummary();
  }
}
