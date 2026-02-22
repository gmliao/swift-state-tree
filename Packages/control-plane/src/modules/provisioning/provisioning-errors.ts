/**
 * Expected provisioning errors (transient, ticket stays queued).
 * Callers may catch and retry; do not rethrow.
 */
export class NoServerAvailableError extends Error {
  constructor(landType: string) {
    super(`No server available for landType: ${landType}`);
    this.name = 'NoServerAvailableError';
    Object.setPrototypeOf(this, NoServerAvailableError.prototype);
  }
}
