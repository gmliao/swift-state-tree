import { ApiProperty } from '@nestjs/swagger';

/** Standard response envelope for provisioning endpoints. */
export class ProvisioningResponseDto<T = unknown> {
  @ApiProperty({ example: true })
  success!: boolean;

  @ApiProperty({ required: false })
  result?: T;

  @ApiProperty({ required: false })
  error?: {
    code: string;
    message: string;
    retryable?: boolean;
  };
}

/** Factory for success response (no result). */
export function provisioningSuccess(): ProvisioningResponseDto {
  return { success: true };
}
