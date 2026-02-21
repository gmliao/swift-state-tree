# Control Plane Admin UI

Read-only management and monitoring dashboard for the matchmaking control plane.

## Tech Stack

- Vue 3, Vuetify 3, Pinia, Vue Router
- Vite, Vitest, Playwright

## Development

**Prerequisites:** Control plane and Redis running.

1. Start Redis: `cd Packages/control-plane && docker compose up -d`
2. Start control plane: `cd Packages/control-plane && npm run start:dev`
3. Start admin UI: `cd Packages/control-plane-admin-ui && npm run dev`

Open http://localhost:5174. The dev server proxies `/api` to the control plane at localhost:3000.

## Scripts

- `npm run dev` - Start dev server (port 5174)
- `npm run build` - Production build
- `npm run test` - Unit tests (Vitest)
- `npm run test:e2e` - Playwright e2e (starts dev server; control plane must be running for API data)
