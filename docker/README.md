# Docker Build

Docker images for SwiftStateTree servers, with clear separation between **build image** and **run image**. Designed for CI/CD and Kubernetes deployment.

## Image Types

| Image | Purpose | Use Case |
|-------|---------|----------|
| **Build image** | Full Swift toolchain for compilation | CI pipelines, local builds |
| **Run image** | Runtime only: `swift:<tag>-slim` (Ubuntu 24.04, the Swift runtime libraries, no compiler) | Deployment, Kubernetes |

The run images' runtime stage is the official slim image of the builder's toolchain, `swift:6.4.3-noble-slim` (#848). It carries the Swift runtime libraries (`/usr/lib/swift/linux`) and the packages Foundation needs (libcurl4, libxml2, tzdata), so the Dockerfiles keep no package list of their own and copy no libraries from the builder. Foundation's ICU is bundled with the runtime libraries (`lib_FoundationICU.so`), so no system libicu is installed.

Both stages are pinned by digest:
- the builder to the same `swift:<tag>@sha256:…` as CI;
- the runtime to the slim tag's own digest (Docker Hub's index digest of `swift:<tag>-slim`).

`scripts/check-ci-image-pin.sh` checks that the slim tag is the builder's version and distro, that every slim `FROM` carries one digest, and that it isn't the builder's. When the toolchain is bumped, both digests move together. Any `FROM ubuntu` line must still be the pin's distro; none is left.

### Why not as small as Node Alpine?

| Factor | Node | Swift (this project) |
|--------|------|----------------------|
| **Alpine** | Official `node:alpine` (~40MB); single runtime binary. | No official Swift Alpine. Swift uses glibc and dynamic Swift runtime libs (~50–80MB of `.so`). |
| **Static binary** | Not required for Node. | `--static-swift-stdlib` exists but still needs system libs (libicu, libcurl). Fully static/musl is a Swift 6+ feature and not used here. |
| **Result** | Can be ~40MB with Alpine. | Run image: Ubuntu 24.04 + Foundation's packages + the Swift runtime (the slim image); sizes measured in #848. |

To get closer to “Alpine small” you’d need either (1) official Swift support for Alpine/musl, or (2) a Swift 6 static Linux (musl) build and an Alpine base—both are outside this Dockerfile’s scope for now.

## Quick Start

```bash
# Build all images (build + DemoServer run + GameServer run)
./docker/build.sh

# Or build individually
./docker/build.sh build   # Build image only
./docker/build.sh demo    # DemoServer run image
./docker/build.sh game    # GameServer run image
```

## Run Images

### DemoServer

```bash
docker build -f docker/Dockerfile.DemoServer -t demo:latest .
docker run -p 8080:8080 demo:latest
```

### GameServer (Hero Defense)

```bash
docker build -f docker/Dockerfile.GameServer -t game:latest .
docker run -p 8080:8080 game:latest
```

## Environment Variables

Both run images support:

| Variable | Default | Description |
|----------|---------|--------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8080` | Listen port |
| `TRANSPORT_ENCODING` | (varies) | `json`, `jsonOpcode`, or `messagepack` |

Example:

```bash
docker run -p 3000:3000 -e PORT=3000 -e TRANSPORT_ENCODING=messagepack game:latest
```

## E2E Verification

```bash
# Build, run container, and run E2E tests against it
./docker/test-e2e-docker.sh          # All encodings (json, jsonOpcode, messagepack)
./docker/test-e2e-docker.sh json     # Single encoding
```

## Kubernetes

Run images are k8s-ready:

- Non-root user (`appuser`)
- Minimal attack surface (slim base)
- Configurable via env vars

Example Deployment (placeholder for future k8s manifests):

```yaml
# k8s/ will be added in a follow-up
# apiVersion: apps/v1
# kind: Deployment
# ...
```

## Custom Tags

```bash
DOCKER_BUILD_TAG=myorg/build:1.0 \
DOCKER_DEMO_TAG=myorg/demo:v1 \
DOCKER_GAME_TAG=myorg/game:v1 \
./docker/build.sh all
```
