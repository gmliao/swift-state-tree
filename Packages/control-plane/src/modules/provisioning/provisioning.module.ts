import { Module } from '@nestjs/common';
import { ProvisioningController } from './provisioning.controller';
import { InMemoryProvisioningClient } from './inmemory-provisioning.client';
import { ClusterDirectoryModule } from '../../infra/cluster-directory/cluster-directory.module';

/**
 * Provisioning module: server registry + in-memory allocate.
 * Replaces external HttpProvisioningClient.
 */
@Module({
  imports: [ClusterDirectoryModule],
  controllers: [ProvisioningController],
  providers: [
    InMemoryProvisioningClient,
    {
      provide: 'ProvisioningClientPort',
      useExisting: InMemoryProvisioningClient,
    },
  ],
  exports: ['ProvisioningClientPort'],
})
export class ProvisioningModule {}
