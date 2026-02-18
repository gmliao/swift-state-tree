import { Controller, Get } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse } from '@nestjs/swagger';
import * as crypto from 'crypto';
import { JwtIssuerService } from './jwt-issuer.service';

/**
 * JWKS (JSON Web Key Set) controller.
 * Exposes public keys for JWT validation by game servers.
 */
@ApiTags('jwks')
@Controller('.well-known')
export class JwksController {
  constructor(private readonly jwtIssuer: JwtIssuerService) {}

  /**
   * Returns the JWKS document with public keys for RS256 JWT validation.
   * Game servers use this to verify match tokens.
   */
  @Get('jwks.json')
  @ApiOperation({
    summary: 'Get JWKS',
    description:
      'Returns JSON Web Key Set for validating match tokens. Game servers fetch this to verify JWT signatures.',
  })
  @ApiResponse({
    status: 200,
    description: 'JWKS document with keys array',
    schema: {
      type: 'object',
      properties: {
        keys: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              kty: { type: 'string', example: 'RSA' },
              kid: { type: 'string', example: 'mm-dev-1' },
              alg: { type: 'string', example: 'RS256' },
              use: { type: 'string', example: 'sig' },
            },
          },
        },
      },
    },
  })
  getJwks() {
    const publicKey = this.jwtIssuer.getPublicKey();
    const kid = this.jwtIssuer.getKid();
    const key = crypto.createPublicKey(publicKey);
    const jwk = key.export({ format: 'jwk' }) as {
      kty: string;
      n?: string;
      e?: string;
    };
    return {
      keys: [
        {
          ...jwk,
          kid,
          alg: 'RS256',
          use: 'sig',
        },
      ],
    };
  }
}
