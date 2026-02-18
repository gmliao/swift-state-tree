import { Injectable } from '@nestjs/common';
import * as crypto from 'crypto';
import * as jwt from 'jsonwebtoken';

/** JWT claims for match assignment token. */
export interface AssignmentTokenPayload {
  assignmentId: string;
  playerId: string;
  landId: string;
  exp: number;
  jti: string;
}

/**
 * Issues RS256 JWT tokens for match assignments.
 * Game servers validate tokens using JWKS endpoint.
 */
@Injectable()
export class JwtIssuerService {
  private keyPair: { publicKey: string; privateKey: string };
  private readonly kid = 'mm-dev-1';

  constructor() {
    const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    this.keyPair = { publicKey, privateKey };
  }

  /** Signs and returns a JWT with assignment claims. */
  async issue(payload: AssignmentTokenPayload): Promise<string> {
    return jwt.sign(payload, this.keyPair.privateKey, {
      algorithm: 'RS256',
      keyid: this.kid,
    });
  }

  /** Returns PEM public key for JWKS. */
  getPublicKey(): string {
    return this.keyPair.publicKey;
  }

  /** Returns key ID for JWKS. */
  getKid(): string {
    return this.kid;
  }
}
