import { Controller, Get, Inject } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
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
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
    private readonly queueSummary: AdminQueueService,
  ) {}

  @Get('servers')
  async getServers(): Promise<ServerListResponseDto> {
    const list = await this.serverIdDirectory.listAllServers();
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
