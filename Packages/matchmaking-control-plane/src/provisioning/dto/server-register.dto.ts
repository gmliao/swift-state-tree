import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsNumber, IsOptional, IsString, IsIn } from 'class-validator';

/** Request body for POST /v1/provisioning/servers/register. */
export class ServerRegisterDto {
  @ApiProperty()
  @IsString()
  serverId!: string;

  @ApiProperty({ description: 'Host the server binds to (used for connectUrl when connectHost not set)' })
  @IsString()
  host!: string;

  @ApiProperty({ description: 'Port the server binds to (used for connectUrl when connectPort not set)' })
  @IsNumber()
  port!: number;

  @ApiProperty()
  @IsString()
  landType!: string;

  /** Client-facing host for connectUrl. Use when behind K8s Ingress, nginx LB, etc. */
  @ApiPropertyOptional({ example: 'game.example.com' })
  @IsOptional()
  @IsString()
  connectHost?: string;

  /** Client-facing port for connectUrl. Use with connectHost when behind LB. */
  @ApiPropertyOptional({ example: 443 })
  @IsOptional()
  @IsNumber()
  connectPort?: number;

  /** WebSocket scheme. Default: "wss" when connectPort is 443, else "ws". */
  @ApiPropertyOptional({ enum: ['ws', 'wss'] })
  @IsOptional()
  @IsIn(['ws', 'wss'])
  connectScheme?: 'ws' | 'wss';
}
