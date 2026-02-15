# Docker Build

Docker images for SwiftStateTree servers, with clear separation between **build image** and **run image**. Designed for CI/CD and Kubernetes deployment.

## Image Types

| Image | Purpose | Use Case |
|-------|---------|----------|
| **Build image** | Full Swift toolchain for compilation | CI pipelines, local builds |
| **Run image** | Minimal runtime (~150MB, ubuntu:24.04 + Swift runtime libs) | Deployment, Kubernetes |

Run images use `ubuntu:24.04` + minimal deps (libicu74, libcurl4, etc.) + Swift runtime libs from builder—**not** swift:slim (~450MB).

### Why not as small as Node Alpine?

| Factor | Node | Swift (this project) |
|--------|------|----------------------|
| **Alpine** | Official `node:alpine` (~40MB); single runtime binary. | No official Swift Alpine. Swift uses glibc and dynamic Swift runtime libs (~50–80MB of `.so`). |
| **Static binary** | Not required for Node. | `--static-swift-stdlib` exists but still needs system libs (libicu, libcurl). Fully static/musl is a Swift 6+ feature and not used here. |
| **Result** | Can be ~40MB with Alpine. | Run image is ~100–150MB (ubuntu:24.04 + deps + Swift runtime). |

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
