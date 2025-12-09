// Minimal JWT helper (HS256) borrowed from Playground for Vue demo use.

export interface JWTPayload {
    playerID: string;
    deviceID?: string;
    username?: string;
    [key: string]: unknown;
}

function base64UrlEncode(data: Uint8Array): string {
    const base64 = btoa(String.fromCharCode(...data));
    return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

export async function generateJWT(
    secretKey: string,
    payload: JWTPayload,
    expiresInHours = 2
): Promise<string> {
    if (!payload.playerID) {
        throw new Error("playerID is required in JWT payload");
    }

    const header = { alg: "HS256", typ: "JWT" };
    const now = Math.floor(Date.now() / 1000);
    const exp = now + expiresInHours * 3600;
    const jwtPayload = { ...payload, iat: now, exp };

    const encodedHeader = base64UrlEncode(new TextEncoder().encode(JSON.stringify(header)));
    const encodedPayload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(jwtPayload)));

    const message = `${encodedHeader}.${encodedPayload}`;
    const keyData = new TextEncoder().encode(secretKey);

    const cryptoKey = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, [
        "sign",
    ]);
    const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
    const encodedSignature = base64UrlEncode(new Uint8Array(signature));

    return `${encodedHeader}.${encodedPayload}.${encodedSignature}`;
}

export function decodeJWT(token: string): { header: unknown; payload: unknown } {
    const parts = token.split(".");
    if (parts.length !== 3) {
        throw new Error("Invalid JWT format");
    }

    const base64UrlDecode = (str: string): string => {
        let base64 = str.replace(/-/g, "+").replace(/_/g, "/");
        const padding = (4 - (base64.length % 4)) % 4;
        base64 += "=".repeat(padding);
        return atob(base64);
    };

    const header = JSON.parse(base64UrlDecode(parts[0]));
    const payload = JSON.parse(base64UrlDecode(parts[1]));

    return { header, payload };
}
