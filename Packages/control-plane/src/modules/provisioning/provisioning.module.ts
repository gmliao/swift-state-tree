import { Module } from '@nestjs/common';
import { ProvisioningController } from './provisioning.controller';
import { InMemoryProvisioningClient } from './inmemory-provisioning.client';
import { ServerRegistryService } from './server-registry.service';

/**
 * Provisioning module: server registry + in-memory allocate.
 * Replaces external HttpProvisioningClient.
 */
@Module({
  controllers: [ProvisioningController],
  providers: [
    ServerRegistryService,
    InMemoryProvisioningClient,
    {
      provide: 'ProvisioningClientPort',
      useExisting: InMemoryProvisioningClient,
    },
  ],
  exports: ['ProvisioningClientPort', ServerRegistryService],
})
export class ProvisioningModule {}
