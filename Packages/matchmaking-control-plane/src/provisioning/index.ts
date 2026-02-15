/**
 * Provisioning module - server registration, allocate, and related types.
 * Game servers register via POST /v1/provisioning/servers/register.
 * Allocate is internal (InMemoryProvisioningClient).
 */
export { ProvisioningController } from './provisioning.controller';
export { ProvisioningModule } from './provisioning.module';
export { ServerRegistryService, SERVER_TTL_MS } from './server-registry.service';
export { InMemoryProvisioningClient } from './inmemory-provisioning.client';
export { ProvisioningClientPort } from './provisioning-client.port';
export { ServerRegisterDto } from './dto/server-register.dto';
export {
  ProvisioningAllocateRequest,
  ProvisioningAllocateResponse,
  ProvisioningError,
} from './provisioning.contract';
