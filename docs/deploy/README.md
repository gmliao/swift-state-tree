# Deploy & Load Balancing

## Path-Based Routing for K8s / Ingress

SwiftStateTree supports WebSocket paths with instanceId for load balancing:

| Path | Description |
|------|-------------|
| `/game/{landType}` | Base path (e.g. `/game/hero-defense`) |
| `/game/{landType}/{instanceId}` | Path with room ID for LB routing (e.g. `/game/hero-defense/room-abc`) |

The server accepts both. Client must send Join with `landID: "landType:instanceId"` (e.g. `hero-defense:room-abc`).

**LB requirement**: Same room must hit same server (players in one room share state). Use path-hash: `hash $uri consistent` (path only, no query) so `/game/hero-defense/room-abc` always routes to the same backend.

### nginx Example

Simplest way to test path-based LB (nginx is lightweight and commonly used as LB):

**Single-backend test** (verify path is accepted):

```bash
# 1. Start GameServer on default port 8080
swift run -C Examples/GameDemo GameServer

# 2. In another terminal: nginx
nginx -p $(pwd) -c docs/deploy/nginx-websocket-path-routing.conf

# 3. Client via nginx (port 9090), all paths -> :8080
# ws://localhost:9090/game/hero-defense
# ws://localhost:9090/game/hero-defense/room-abc
```

**Multi-backend test** (path-hash: same room → same server):

```bash
# 1. Start 3 backends
PORT=8080 swift run -C Examples/GameDemo GameServer &
PORT=8081 swift run -C Examples/GameDemo GameServer &
PORT=8082 swift run -C Examples/GameDemo GameServer &

# 2. nginx (hash $uri consistent)
nginx -p $(pwd) -c docs/deploy/nginx-websocket-path-routing.conf

# 3. Same path (same room) -> same server
# /game/hero-defense/room-abc always hashes to same backend
# Different rooms distribute across backends
```

The config uses `hash $uri consistent` (path only; excludes query e.g. ?token=) so all connections to the same room path hit the same server.

### Docker + Test Script

```bash
# From repo root - starts GameServers + nginx, runs CLI test
./docs/deploy/test-nginx-lb.sh
```

Or manually:
```bash
# Terminal 1-3: GameServers
cd Examples/GameDemo && PORT=8080 swift run GameServer
cd Examples/GameDemo && PORT=8081 swift run GameServer
cd Examples/GameDemo && PORT=8082 swift run GameServer

# Terminal 4: nginx in Docker (uses host.docker.internal)
docker compose -f docs/deploy/docker-compose.nginx.yml up -d

# Terminal 5: CLI test
cd Tools/CLI && npm run dev -- connect -u ws://localhost:9090/game/hero-defense/room-abc -l hero-defense:room-abc --once

# Verify same room → same process (uses admin API to check which backend has the land)
./docs/deploy/verify-same-room-same-process.sh
```

### K8s / k3s 本地測試

本地可用輕量 K8s 測試，例如：

| 工具 | 說明 |
|------|------|
| **[k3s](https://k3s.io/)** | 單二進制、低資源，適合本機單節點 |
| **[k3d](https://k3d.io/)** | k3s in Docker，適合多節點／CI |
| **minikube** | 傳統本機 K8s 選項 |

```bash
# k3s 安裝
curl -sfL https://get.k3s.io | sh -
# 或用 k3d（Docker 內跑 k3s）
k3d cluster create
```

k3s 預設用 Traefik；若要用 nginx-ingress 的 path-hash，可再安裝 nginx-ingress controller。K8s Service 會自動維護 Endpoints，scale 時無需改 config。

### K8s Ingress

Same pattern applies. Example (nginx-ingress):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: game-ws
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  rules:
  - host: game.example.com
    http:
      paths:
      - path: /game/hero-defense
        pathType: Prefix
        backend:
          service:
            name: game-server
            port:
              number: 8080
```

Path `/game/hero-defense/room-xyz` will match and route to your game-server service.
