# Docker Build

Docker images for SwiftStateTree servers, with clear separation between **build image** and **run image**. Designed for CI/CD and Kubernetes deployment.

## Image Types

| Image | Purpose | Use Case |
|-------|---------|----------|
| **Build image** | Full Swift toolchain for compilation | CI pipelines, local builds |
| **Run image** | Minimal runtime with compiled binary only | Deployment, Kubernetes |

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
