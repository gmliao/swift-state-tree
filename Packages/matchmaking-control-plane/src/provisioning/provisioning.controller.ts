import {
  Body,
  Controller,
  Delete,
  HttpCode,
  HttpStatus,
  Param,
  Post,
} from '@nestjs/common';
import { ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger';
import {
  ProvisioningResponseDto,
  provisioningSuccess,
} from './dto/provisioning-response.dto';
import { ServerRegisterDto } from './dto/server-register.dto';
import { ServerRegistryService } from './server-registry.service';

/**
 * Provisioning API.
 * Game servers register here; same endpoint used for initial register and heartbeat.
 * Deregister on shutdown via DELETE.
 * All responses use standard envelope: { success, result?, error? }.
 */
@ApiTags('provisioning')
@Controller('v1/provisioning')
export class ProvisioningController {
  constructor(private readonly registry: ServerRegistryService) {}

  @Post('servers/register')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Register or heartbeat a game server' })
  @ApiResponse({ status: 200, description: 'Success', type: ProvisioningResponseDto })
  async register(@Body() dto: ServerRegisterDto) {
    this.registry.register(dto.serverId, dto.host, dto.port, dto.landType, {
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
    this.registry.deregister(serverId);
    return provisioningSuccess();
  }
}
