# SwiftStateTreeHummingbird (Archived)

This directory contains the former **SwiftStateTreeHummingbird** integration code, preserved for reference only. It is **not** built or tested as part of the main SwiftStateTree repository.

## Why Hummingbird Was Removed from the Main Repo

- **Core should not depend on a specific web framework.** SwiftStateTree and the Transport layer are intended to be framework-agnostic; WebSocket transport is provided by NIO or by an optional hosting integration.
- **Web features (HTTP server, Admin, JWT) belong in the hosting layer**, not inside the WebSocket core. The main repo provides hosting via NIO by default and does not require Hummingbird.
- **Removing Hummingbird from the default build** reduces dependencies and build time for the majority of users who use NIO.

## Why This Code Is Kept

- **Reference:** If you need to integrate SwiftStateTree into an existing Hummingbird project, or want examples of JWT/Admin integration, you can use this code as a guide.
- **Future optional package:** If Hummingbird integration is later offered as a separate package, this archive can be used as the starting point.

## Contents

- `Sources/` – Former SwiftStateTreeHummingbird target (LandHost, LandServer, JWT, Admin routes, etc.).
- `Tests/` – Former SwiftStateTreeHummingbirdTests.

## Note

This code is **not** part of the main package and may drift from the current SwiftStateTree API. If you copy from here into a new package, you may need to update types and imports to match the latest SwiftStateTree and Hummingbird versions.
