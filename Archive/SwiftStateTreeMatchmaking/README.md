# SwiftStateTreeMatchmaking (Archived)

This directory contains the former **SwiftStateTreeMatchmaking** in-process matchmaking and lobby module, preserved for reference only. It is **not** built or tested as part of the main SwiftStateTree repository.

## Why Matchmaking Was Archived

- **Architecture change:** Matchmaking is now handled by the external **NestJS Matchmaking Control Plane** (`Packages/matchmaking-control-plane`). Game servers register via `SwiftStateTreeNIOProvisioning` and clients get assignments (connectUrl, matchToken) from the control plane REST API.
- **No active consumers:** `GameServer` and `DemoServer` use the NestJS control plane. The only previous consumer was `Archive/SwiftStateTreeHummingbird`, which is also archived.
- **Simpler stack:** Removing in-process matchmaking reduces maintenance and clarifies that matchmaking is an external service concern.

## Current Matchmaking Architecture

- **Control plane:** NestJS (`Packages/matchmaking-control-plane`) – enqueue, poll status, assignment with JWT
- **Provisioning:** Game servers register via `POST /v1/provisioning/servers/register` (ProvisioningMiddleware)
- **Client flow:** Enqueue → poll status → get connectUrl (via nginx LB when configured) → connect with token

## Contents

- `SwiftStateTreeMatchmaking/` – MatchmakingService, LobbyContainer, DefaultMatchmakingStrategy, etc.
- `SwiftStateTreeMatchmakingTests/` – Former unit tests.

## Note

This code is **not** part of the main package and may drift from the current SwiftStateTree API. The `MatchmakingStrategy` protocol remains in `SwiftStateTreeTransport` for potential future use; `DefaultMatchmakingStrategy` was in this archived module.
