[English](auth.md) | [中文版](auth.zh-TW.md)

# JWT and Guest Mode

`NIOLandHost` (module `SwiftStateTreeNIO`) can validate a JWT during the WebSocket upgrade and let clients without a token join as guests. Authentication is configured per registered land type, through `NIOLandServerConfiguration`. Admin routes use a separate API key; see [Admin Routes](#admin-routes).

## Design Notes

- WebSocket in browser environments can easily pass tokens through query parameters
- JWT validation completes during the handshake, so unauthorized connections never reach the game layer
- Guest mode allows connections without tokens, used for demo or low-barrier experience
- The token check sits behind `TokenValidatorProtocol` (in `SwiftStateTreeTransport`), so a server can swap in its own validator without touching the transport

## Connection Parameters

The JWT is passed in the `token` query parameter of the WebSocket URL:

```
ws://host:port/game?token=<jwt-token>
```

The value is percent-decoded before validation. The same rules apply to `webSocketPath` and to any path below it (for example `/game/room-abc` for a land registered at `/game`).

What happens on upgrade depends on the land's configuration:

| Configuration | Token present | No token |
|---|---|---|
| No `jwtConfig` and no `jwtValidator` | Token ignored, connection accepted | Connection accepted |
| JWT enabled, `allowGuestMode = false` (default) | Validated; rejected if invalid | Rejected |
| JWT enabled, `allowGuestMode = true` | Validated; rejected if invalid | Accepted, joins as a guest |

"JWT enabled" means `jwtValidator` or `jwtConfig` is set. Validation runs right after the HTTP upgrade is accepted; a rejected connection is closed by the server before it is attached to a land session.

## Configuration

`NIOLandServerConfiguration` fields:

| Field | Default | Meaning |
|---|---|---|
| `jwtConfig` | `nil` | `JWTConfiguration` for the built-in `DefaultJWTAuthValidator` |
| `jwtValidator` | `nil` | Custom validator (`JWTAuthValidator`); takes precedence over `jwtConfig` |
| `allowGuestMode` | `false` | With JWT enabled, accept connections that send no token |
| `createGuestSession` | `nil` | Factory `(SessionID, ClientID) -> PlayerSession` for guest sessions; `nil` uses the default below |

```swift
import SwiftStateTree
import SwiftStateTreeNIO

let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

// Create NIOLandHost to manage the HTTP/WebSocket server and game logic
let host = NIOLandHost(configuration: NIOLandHostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration
try await host.register(
    landType: "demo",
    land: demoLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: NIOLandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true
    )
)

try await host.runUntilShutdownSignal()
```

### JWTConfiguration

| Parameter | Default | Meaning |
|---|---|---|
| `secretKey` | `nil` | HMAC secret; required by the default validator |
| `publicKey` | `nil` | Reserved; the default validator does not use it |
| `algorithm` | `.HS256` | Must match the token header's `alg` |
| `validateExpiration` | `true` | Reject tokens past `exp` or before `nbf` |
| `validateIssuer` / `expectedIssuer` | `false` / `nil` | Require `iss` to equal `expectedIssuer` |
| `validateAudience` / `expectedAudience` | `false` / `nil` | Require `aud` (a single string) to equal `expectedAudience` |

`DefaultJWTAuthValidator` supports `HS256`, `HS384` and `HS512`. The `RS*` and `ES*` cases exist in `JWTAlgorithm`, but the default validator rejects every token with them; use a custom `jwtValidator` for asymmetric keys.

### Token Payload

The default validator decodes the payload into `JWTPayload` and turns it into `AuthenticatedInfo`:

- `playerID` claim, or the standard `sub` claim when `playerID` is absent; one of them must be a non-empty string
- `deviceID` (optional)
- `metadata` (optional): an object whose values are all strings
- Every other non-standard top-level claim (for example `username`) is copied into metadata as a string; numbers and booleans are converted, nested values are stored as JSON text

### Custom Validator

Conform to `JWTAuthValidator` (a `TokenValidatorProtocol`) and implement `validate(token:)`. Throwing rejects the upgrade:

```swift
struct MyValidator: JWTAuthValidator {
    func validate(token: String) async throws -> AuthenticatedInfo {
        // Verify the token with your own keys or auth service
        AuthenticatedInfo(playerID: "player-123", deviceID: nil, metadata: [:])
    }
}

let configuration = NIOLandServerConfiguration(jwtValidator: MyValidator())
```

### Environment Variables

`JWTConfiguration.fromEnvironment()` (also exposed as `NIOEnvConfig.fromEnvironment().jwtConfiguration`) reads:

| Key | Default | Notes |
|---|---|---|
| `JWT_SECRET_KEY` | (none) | Unset or empty: returns `nil` |
| `JWT_ALGORITHM` | `HS256` | An unknown name returns `nil` |
| `JWT_ISSUER` | (none) | When set, the issuer is validated |
| `JWT_AUDIENCE` | (none) | When set, the audience is validated |

Expiration is always validated. The host does not read these variables on its own; pass the result as `jwtConfig`:

```swift
// nil when JWT_SECRET_KEY is not set: JWT stays disabled for this land
let jwtConfig = JWTConfiguration.fromEnvironment()

try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: NIOLandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: false  // Don't allow Guest mode
    )
)
```

```bash
export JWT_SECRET_KEY="your-secret-key-here"
export JWT_ALGORITHM="HS256"
export JWT_ISSUER="my-game-server"    # Optional
export JWT_AUDIENCE="my-game-client"  # Optional
```

## PlayerSession Priority

**The playerID.** With a JWT, the token's `playerID` is the player's identity:
- A join request that carries no `playerID`, or the token's own, joins as the token's player.
- A join request that carries a different `playerID` is rejected with `JOIN_PLAYER_MISMATCH` before any land is looked up or created, and the server logs the mismatch at warning level.
- On a land with a JWT validator or configuration, a connection without a token (guest mode) is a guest: a join request that carries a `playerID` is rejected with `JOIN_PLAYER_MISMATCH`, and one without joins as the guest session's player.
- On a land without JWT, the join request's `playerID` is used, else the guest session's.

A join with a JWT is never a guest. A join without a JWT is a guest when it carries no `playerID`.

**Device ID and metadata** keep this priority order:

1. join request content
2. JWT payload
3. guest session

Metadata is merged: JWT metadata first, then join request metadata overrides keys it also sets.

## Flow Overview

```
Client --(ws?token=...)--> NIOWebSocketServer (upgrade)
  -> NIOLandHost auth resolver: JWT validate (if configured)
  -> TransportAdapter.onConnect(authInfo)
  -> join request
  -> CanJoin / OnJoin
```

## JWT Token Generation

### Server-Side Generation (Example)

In real applications, JWT tokens are usually generated by authentication services. Here's an example using SwiftJWT:

```swift
import SwiftJWT

struct MyClaims: Claims {
    let playerID: String
    let deviceID: String?
    let exp: Date
    let iat: Date
}

func generateJWT(playerID: String, deviceID: String?) throws -> String {
    let myHeader = Header(typ: "JWT")
    let expiration = Date().addingTimeInterval(3600 * 2) // 2 hours
    let myClaims = MyClaims(
        playerID: playerID,
        deviceID: deviceID,
        exp: expiration,
        iat: Date()
    )
    
    var myJWT = JWT(header: myHeader, claims: myClaims)
    let jwtSigner = JWTSigner.hs256(key: Data("your-secret-key".utf8))
    let signedJWT = try myJWT.sign(using: jwtSigner)
    
    return signedJWT
}
```

The validator reads `exp`, `iat` and `nbf` as integer Unix timestamps; configure the signing library to encode dates that way.

### Client-Side Generation (TypeScript Example)

For local testing, you can generate a JWT on the client with the Web Crypto API. Don't ship the secret to real clients:

```typescript
async function generateJWT(
  secretKey: string,
  payload: { playerID: string; deviceID?: string },
  expiresInHours: number = 2
): Promise<string> {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const exp = now + (expiresInHours * 3600);
  
  const jwtPayload = {
    ...payload,
    iat: now,
    exp: exp
  };
  
  // Encode header and payload
  const encodedHeader = btoa(JSON.stringify(header))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  const encodedPayload = btoa(JSON.stringify(jwtPayload))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  // Create signature
  const message = `${encodedHeader}.${encodedPayload}`;
  const keyData = new TextEncoder().encode(secretKey);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signature = await crypto.subtle.sign(
    'HMAC',
    cryptoKey,
    new TextEncoder().encode(message)
  );
  
  const encodedSignature = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  return `${encodedHeader}.${encodedPayload}.${encodedSignature}`;
}

// Usage example
const token = await generateJWT('your-secret-key', {
  playerID: 'player-123',
  deviceID: 'device-456'
});

// Connect to WebSocket
const ws = new WebSocket(`ws://localhost:8080/game?token=${token}`);
```

## Guest Mode

### Use Cases

Guest mode is suitable for the following scenarios:

- **Demo or test environments**: Don't need complete authentication flow
- **Quick experience**: Lower barrier to entry for users
- **Development phase**: Simplify development and testing process

### Guest Sessions

A join becomes a guest session when it carries no `playerID` and the connection has no authenticated info. This also happens when JWT is not configured at all. The default guest session uses:

- `playerID`: the session ID (a UUID generated per connection)
- `deviceID`: the client ID
- `isGuest: true`, and `metadata["isGuest"] = "true"`

Pass `createGuestSession` to choose other values:

```swift
let configuration = NIOLandServerConfiguration(
    jwtConfig: jwtConfig,
    allowGuestMode: true,
    createGuestSession: { sessionID, clientID in
        PlayerSession(
            playerID: "guest-\(sessionID.rawValue)",
            deviceID: clientID.rawValue,
            isGuest: true
        )
    }
)
```

### Guest Session Handling

Handlers see the flag as `session.isGuest` in `CanJoin` and `ctx.isGuest` in `OnJoin`:

```swift
Rules {
    OnJoin { state, ctx in
        state.players[ctx.playerID] = PlayerState(
            name: ctx.isGuest
                ? "Guest \(ctx.playerID.rawValue.suffix(8))"
                : (ctx.metadata["displayName"] ?? ctx.playerID.rawValue),
            isGuest: ctx.isGuest
        )
    }
}
```

### Guest Mode Limitations

It's recommended to implement some limitations in Guest mode:

```swift
struct GuestNotAllowed: Error {}

Rules {
    CanJoin { state, session, ctx in
        // Limit Guest player count
        let guestCount = state.players.values.filter { $0.isGuest }.count
        if session.isGuest && guestCount >= 10 {
            return .deny(reason: "Too many guest players")
        }
        return .allow(playerID: PlayerID(session.playerID))
    }
    
    HandleAction(PremiumAction.self) { state, action, ctx in
        // Guest players cannot perform certain actions
        if state.players[ctx.playerID]?.isGuest == true {
            throw GuestNotAllowed()
        }
        // Normal processing...
    }
}
```

## Admin Routes

Admin routes do not use JWT. They are registered when the host starts (`NIOLandHost.run()` or `runUntilShutdownSignal()`) if `NIOLandHostConfiguration.adminAPIKey` is set, and are disabled otherwise:

```swift
let host = NIOLandHost(configuration: NIOLandHostConfiguration(
    host: "localhost",
    port: 8080,
    adminAPIKey: "your-admin-api-key"
))
```

The key is checked by `NIOAdminAuth` and can be passed through:

1. **HTTP Header**: `X-API-Key: your-secure-api-key`
2. **Query Parameter**: `?apiKey=your-secure-api-key`

A matching key grants the `admin` role. `AdminRole` also defines `operator` and `viewer` (hierarchy `admin` > `operator` > `viewer`); read routes require `viewer`, the others `admin`, but the API key is the only credential, so every authenticated request is `admin`.

### Admin Route Endpoints

Responses are JSON envelopes `{ "success": ..., "data": ..., "error": ... }`.

| Route | Role | Effect |
|---|---|---|
| `GET /admin/lands` | viewer | List land IDs |
| `GET /admin/lands/:landID` | viewer | Stats for one land |
| `GET /admin/lands/:landID/stats` | viewer | Same as above |
| `GET /admin/stats` | viewer | `totalLands` and `totalPlayers` |
| `DELETE /admin/lands/:landID` | admin | Stop a land: its sessions leave and are closed with 4014, then it is destroyed (destroy handlers, the save). OnLeave runs before the destroy on a tickless land; a tick land's queued leaves are currently dropped (#512). 200 `{ "stopped": true }`, with `"timedOut": true` when the stop passed the host's `shutdownTimeout` (the destroy and the save then finish in the background); 404 for an unknown ID. Requests for one land during its stop share it |
| `POST /admin/lands` | admin | Not implemented (501) |
| `GET /admin/lands/:landID/reevaluation-record` | admin | Download a re-evaluation record |
| `GET /admin/reevaluation/records` | viewer | List re-evaluation records |
| `POST /admin/reevaluation/start` | admin | Start a re-evaluation monitor land for a record |
| `POST /admin/reevaluation/replay/start` | admin | Start a replay land for a record |

Both reevaluation starts take a JSON body `{ landType, recordFilePath, expectedLandDefinitionID?, expectedRecordVersion? }` (`ReevaluationMonitorStartRequest` for the monitor). The route checks that the record is within the records directory, exists and is compatible, then returns the land's ID (`monitorLandID` or `replayLandID`). That ID is a ticket the server signed for that record: only an ID the route issued creates the land, within five minutes of issue, and a ticket for one kind of land never opens the other. The monitor land starts verifying the ticket's record when it is created; the `StartVerification` action only restarts a finished run on the same record, and its `landType` and `recordFilePath` fields are ignored.

```bash
curl -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/lands
```

Response:
```json
{
  "success": true,
  "data": ["game-room-1", "game-room-2"]
}
```

### Debug State Routes (testing only)

Used by E2E state convergence checks. They are registered only when the admin API key is set **and** `ENABLE_DEBUG_STATE_ROUTES=true`, and require the `admin` role. They return full land state, and a freeze pauses the land, so an enabled deployment gives any key holder a denial-of-service lever. **Never enable them in production.**

| Route | Effect |
|---|---|
| `POST /admin/lands/:landID/debug/freeze` | Pause the land (no tick or sync starts, tickless inputs are held), wait for in-flight work, then send one settle sync. Returns `{ freezeToken, tickId, freezeCount, reused }`. Freezes are reference counted; a freeze while frozen returns the same token without a new settle. If in-flight work or a running sync keeps the drain and settle past their deadline (10 s), the freeze is released and the route answers 503; if the freeze is released before its settle finishes, it answers 409. |
| `GET /admin/lands/:landID/debug/projection?playerID=...` | The state the settle sync described for that player (broadcast plus per-player fields), or broadcast fields only without `playerID`. Values use the state-wire shape (e.g. `Position2` as raw fixed-point integers). `membershipChanged` is true after a join or leave during the freeze. Answers 409 when the land is not frozen. |
| `POST /admin/lands/:landID/debug/resume?freezeToken=...` | Drop one reference of the freeze that returned `freezeToken` (query or JSON body `{ "freezeToken": ... }`; 400 without it). The last one resumes the land and runs syncs requested while frozen. A token of a freeze that was already released (e.g. by auto-resume) is a no-op (`resumed: false`), so it cannot release a newer freeze. |

A frozen land resumes on its own after `DEBUG_FREEZE_TIMEOUT_SECONDS` (default 30); every freeze call restarts the timer.

## Error Handling

### Rejected Connections

When JWT validation fails, or JWT is enabled with guest mode off and no token is sent, the server closes the connection right after the upgrade, without a WebSocket close frame. The client may see `open` first, then a `close` with code 1006 and no reason; the server logs `JWT/auth validation failed, rejecting upgrade` with the error.

```typescript
ws.onclose = (event) => {
  if (!event.wasClean) {
    // Could be an invalid or expired token: refresh it and reconnect
    handleAuthError();
  }
};
```

### Admin Route Errors

Admin routes return standard HTTP status codes:

- `401 Unauthorized`: missing or wrong API key
- `404 Not Found`: the land or record doesn't exist
- `400 Bad Request`: missing parameters

## Security Recommendations

### 1. Secret Key Management

- **Don't hardcode secret key in code**: Use environment variables or key management services
- **Use strong keys**: At least 32-character random string
- **Rotate regularly**: Regularly change secret key

```swift
// ✅ Correct: Read from environment variable
let jwtConfig = JWTConfiguration.fromEnvironment()

// ❌ Wrong: Hardcoded in code
let jwtConfig = JWTConfiguration(secretKey: "my-secret-key")
```

### 2. Token Expiration Time

Set reasonable token expiration time. Tokens travel in the URL and can end up in proxy or access logs, so keep them short-lived:

```swift
// Set expiration time when generating token
let expiration = Date().addingTimeInterval(3600 * 2) // 2 hours
```

### 3. HTTPS/WSS

In production, always use HTTPS and WSS (typically terminated at a load balancer or ingress in front of the NIO server):

```swift
// Production should use WSS
let wsURL = "wss://your-domain.com/game?token=\(token)"
```

### 4. Admin API Key

- **Use strong random string**: At least 32 characters
- **Prefer the header**: a key in `?apiKey=` ends up in logs like a token does
- **Limit access sources**: Use IP whitelist or VPN
- **Log all Admin operations**: For auditing

### 5. Guest Mode Limitations

In production, it's recommended to implement limitations for Guest mode:

```swift
// Limit Guest player count
// Limit Guest player actions
// Regularly clean up inactive Guest players
```

## Related Documentation

- [Transport Layer](README.md) - Understand connection management mechanisms
- [Server Integration Guide](server-integration.md) - `TokenValidatorProtocol` and auth resolvers for other frameworks
- [FAQ](../FAQ.md) - Frequently asked questions
