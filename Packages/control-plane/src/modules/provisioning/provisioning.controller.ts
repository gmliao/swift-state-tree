import {
  Body,
  Controller,
  Delete,
  HttpCode,
  HttpStatus,
  Inject,
  Param,
  Post,
} from '@nestjs/common';
import { ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
import {
  ProvisioningResponseDto,
  provisioningSuccess,
} from './dto/provisioning-response.dto';
import { ServerRegisterDto } from './dto/server-register.dto';

/**
 * Provisioning API.
 * Game servers register here; same endpoint used for initial register and heartbeat.
 * Deregister on shutdown via DELETE.
 * All responses use standard envelope: { success, result?, error? }.
 */
@ApiTags('provisioning')
@Controller('v1/provisioning')
export class ProvisioningController {
  constructor(
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
  ) {}

  @Post('servers/register')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Register or heartbeat a game server' })
  @ApiResponse({ status: 200, description: 'Success', type: ProvisioningResponseDto })
  async register(@Body() dto: ServerRegisterDto) {
    await this.serverIdDirectory.register(dto.serverId, dto.host, dto.port, dto.landType, {
      connectHost: dto.connectHost,
      connectPort: dto.connectPort,
      connectScheme: dto.connectScheme,
    });
    return provisioningSuccess();
  }

  @Delete('servers/:serverId')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Deregister a game server on shutdown' })
  @ApiResponse({ status: 200, description: 'Success', type: ProvisioningResponseDto })
  async deregister(@Param('serverId') serverId: string) {
    await this.serverIdDirectory.deregister(serverId);
    return provisioningSuccess();
  }
}
