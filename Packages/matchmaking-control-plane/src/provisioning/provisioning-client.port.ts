import { AssignmentResult } from '../contracts/assignment.dto';
import { ProvisioningAllocateRequest } from './provisioning.contract';

export type { ProvisioningAllocateRequest };

/** Port for land provisioning (allocate game session). */
export interface ProvisioningClientPort {
  allocate(request: ProvisioningAllocateRequest): Promise<AssignmentResult>;
}
