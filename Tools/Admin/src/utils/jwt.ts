/**
 * JWT Token Generator for Admin Tool
 * 
 * Uses Web Crypto API to generate HS256 JWT tokens
 * Compatible with SwiftStateTree's DefaultJWTAuthValidator
 */

export interface JWTPayload {
  playerID: string
  deviceID?: string
  username?: string
  schoolid?: string
  level?: string
  metadata?: Record<string, string>
  [key: string]: any
}

/**
 * Base64 URL encode (RFC 4648 §5)
 */
function base64UrlEncode(data: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...data))
  return base64
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '')
}

/**
 * Generate JWT token using Web Crypto API
 * 
 * @param secretKey - Secret key for HMAC-SHA256 signing
 * @param payload - JWT payload (must include playerID)
 * @param expiresInHours - Token expiration time in hours (default: 2)
 * @returns JWT token string
 */
export async function generateJWT(
  secretKey: string,
  payload: JWTPayload,
  expiresInHours: number = 2
): Promise<string> {
  if (!payload.playerID) {
    throw new Error('playerID is required in JWT payload')
  }

  // Prepare header
  const header = {
    alg: 'HS256',
    typ: 'JWT'
  }

  // Prepare payload with expiration
  const now = Math.floor(Date.now() / 1000)
  const exp = now + (expiresInHours * 3600)
  
  const jwtPayload = {
    ...payload,
    iat: now,
    exp: exp
  }

  // Encode header and payload
  const encodedHeader = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(header))
  )
  const encodedPayload = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(jwtPayload))
  )

  // Create signature
  const message = `${encodedHeader}.${encodedPayload}`
  const keyData = new TextEncoder().encode(secretKey)
  
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )

  const signature = await crypto.subtle.sign(
    'HMAC',
    cryptoKey,
    new TextEncoder().encode(message)
  )

  const encodedSignature = base64UrlEncode(new Uint8Array(signature))

  // Return complete JWT token
  return `${encodedHeader}.${encodedPayload}.${encodedSignature}`
}

/**
 * Decode JWT token (without verification)
 * Useful for debugging
 */
export function decodeJWT(token: string): { header: any, payload: any } {
  const parts = token.split('.')
  if (parts.length !== 3) {
    throw new Error('Invalid JWT format')
  }

  // Base64 URL decode
  const base64UrlDecode = (str: string): string => {
    let base64 = str.replace(/-/g, '+').replace(/_/g, '/')
    const padding = (4 - (base64.length % 4)) % 4
    base64 += '='.repeat(padding)
    return atob(base64)
  }

  const header = JSON.parse(base64UrlDecode(parts[0]))
  const payload = JSON.parse(base64UrlDecode(parts[1]))

  return { header, payload }
}
