// Where the demo's server lives: one source for the game WebSocket, the admin HTTP API and the
// replay/monitor WebSockets, so a server on another host or port needs no code change.
//
// The connect URL the user enters (ConnectView) is the source. Its default is
// `VITE_SERVER_URL` (a server base such as `ws://host:18080` or `http://host:18080`, or a full
// game URL), else ws://localhost:8080/game/hero-defense. Everything else is derived from it:
// the same host and port, ws -> http and wss -> https.

import { ref } from "vue";

const defaultGamePath = "/game/hero-defense";
const defaultServer = "ws://localhost:8080";

/** The connect URL `VITE_SERVER_URL` gives: a base gets the default game path. */
function defaultConnectURL(): string {
  const configured = (import.meta.env.VITE_SERVER_URL as string | undefined)?.trim();
  const url = new URL(configured || defaultServer);
  url.protocol = url.protocol === "https:" || url.protocol === "wss:" ? "wss:" : "ws:";
  if (url.pathname === "" || url.pathname === "/") {
    url.pathname = defaultGamePath;
  }
  return url.toString();
}

/** The game WebSocket URL; ConnectView edits it. */
export const connectURL = ref(defaultConnectURL());

/** Admin API key; `VITE_ADMIN_API_KEY` overrides the demo default. */
export const adminAPIKey: string =
  (import.meta.env.VITE_ADMIN_API_KEY as string | undefined)?.trim() || "hero-defense-admin-key";

/** `ws(s)://host:port` of a WebSocket or HTTP URL. */
export function webSocketOrigin(from: string = connectURL.value): string {
  const url = new URL(from);
  const secure = url.protocol === "https:" || url.protocol === "wss:";
  return `${secure ? "wss" : "ws"}://${url.host}`;
}

/** `http(s)://host:port` of a WebSocket or HTTP URL: where the admin API and /schema are. */
export function httpOrigin(from: string = connectURL.value): string {
  const url = new URL(from);
  const secure = url.protocol === "https:" || url.protocol === "wss:";
  return `${secure ? "https" : "http"}://${url.host}`;
}
