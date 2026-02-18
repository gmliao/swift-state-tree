import { Module } from '@nestjs/common';
import { ConfigModule as NestConfigModule } from '@nestjs/config';
import { NODE_ID, resolveNodeId } from './env.config';

/**
 * Config module: loads .env and provides centralized env access.
 * NODE_ID: instance identity (env or generated UUID). K8s: inject via ConfigMap/Secret.
 */
@Module({
  imports: [
    NestConfigModule.forRoot({
      isGlobal: true,
      envFilePath: ['.env.local', '.env'],
    }),
  ],
  providers: [{ provide: NODE_ID, useFactory: resolveNodeId }],
  exports: [NestConfigModule, NODE_ID],
})
export class ConfigModule {}
