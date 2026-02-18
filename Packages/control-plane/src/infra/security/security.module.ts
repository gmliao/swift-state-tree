import { Module } from '@nestjs/common';
import { JwtIssuerService } from './jwt-issuer.service';
import { JwksController } from './jwks.controller';

/** Security module: JWT issuer and JWKS endpoint. */
@Module({
  controllers: [JwksController],
  providers: [JwtIssuerService],
  exports: [JwtIssuerService],
})
export class SecurityModule {}
