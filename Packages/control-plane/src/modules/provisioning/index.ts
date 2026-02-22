/**
 * Provisioning module - server registration, allocate, and related types.
 * Game servers register via POST /v1/provisioning/servers/register.
 * Allocate is internal (InMemoryProvisioningClient).
 */
export { ProvisioningController } from './provisioning.controller';
export { ProvisioningModule } from './provisioning.module';
export { ServerEntry, SERVER_TTL_MS } from '../../infra/contracts/server-entry.dto';
export { InMemoryProvisioningClient } from './inmemory-provisioning.client';
export { ProvisioningClientPort } from './provisioning-client.port';
export { ServerRegisterDto } from './dto/server-register.dto';
export {
  ProvisioningAllocateRequest,
  ProvisioningAllocateResponse,
  ProvisioningError,
} from './provisioning.contract';
