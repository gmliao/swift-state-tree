import fs from "node:fs";
import http from "node:http";
import type { ControlCommand, ControlReply } from "./worker-runner";
import type { ConvergenceConnection } from "./worker";

/**
 * The convergence control channel of one client instance (`--control-socket`, design § 6):
 * HTTP over a Unix socket, served by the instance's main process, which relays each command to
 * its workers. A pathname Unix socket is reachable from every network namespace on the host (the
 * filesystem is shared), so the convergence driver never sends through the shaped path.
 *
 * - `POST /stop-sending`: every worker stops its action and event sends; connections stay open.
 * - `GET /lands`: every connection's land, players, open and reconnected flags, decode errors and
 *   last patch time, without states.
 * - `GET /lands?land=<land>&states=<land>`: `land` (repeatable) limits the reply to those lands;
 *   `states` (repeatable) adds the normalised reconstructed state of each open connection there.
 */

export interface ControlTarget {
    control(command: ControlCommand, timeoutMs: number): Promise<ControlReply>;
}

/** How long a worker may take to answer a control command. */
const WORKER_CONTROL_TIMEOUT_MS = 10_000;

export interface ControlServer {
    close(): Promise<void>;
}

export async function startControlServer(socketPath: string, workers: ControlTarget[]): Promise<ControlServer> {
    // A socket file left by an earlier run would make listen fail; nothing else lives at this path.
    if (fs.existsSync(socketPath)) {
        fs.unlinkSync(socketPath);
    }
    const all = (command: ControlCommand) => Promise.all(workers.map((worker) => worker.control(command, WORKER_CONTROL_TIMEOUT_MS)));
    const server = http.createServer((request, response) => {
        const reply = (status: number, body: unknown) => {
            response.writeHead(status, { "content-type": "application/json" });
            response.end(JSON.stringify(body));
        };
        const url = new URL(request.url ?? "/", "http://control");
        (async () => {
            if (request.method === "POST" && url.pathname === "/stop-sending") {
                const replies = await all({ name: "stopSending" });
                return reply(200, { stoppedWorkers: replies.filter((r) => r.stopped).length });
            }
            if (request.method === "GET" && url.pathname === "/lands") {
                const replies = await all({
                    name: "lands",
                    only: url.searchParams.getAll("land"),
                    withStates: url.searchParams.getAll("states")
                });
                const connections: ConvergenceConnection[] = replies.flatMap((r) => r.connections ?? []);
                return reply(200, { connections });
            }
            return reply(404, { error: `no route ${request.method} ${url.pathname}` });
        })().catch((error) => reply(500, { error: String(error) }));
    });
    await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socketPath, () => resolve());
    });
    return {
        close: () =>
            new Promise<void>((resolve) => {
                server.close(() => resolve());
                server.closeAllConnections?.();
            })
    };
}

/** One request to an instance's control socket; the JSON reply, or an error naming the socket. */
export function controlRequest<T>(socketPath: string, method: "GET" | "POST", pathAndQuery: string, timeoutMs = 30_000): Promise<T> {
    return new Promise<T>((resolve, reject) => {
        const request = http.request({ socketPath, method, path: pathAndQuery, timeout: timeoutMs }, (response) => {
            const chunks: Buffer[] = [];
            response.on("data", (chunk: Buffer) => chunks.push(chunk));
            response.on("end", () => {
                const text = Buffer.concat(chunks).toString("utf8");
                if (response.statusCode !== 200) {
                    reject(new Error(`${socketPath} ${method} ${pathAndQuery}: HTTP ${response.statusCode} ${text.slice(0, 200)}`));
                    return;
                }
                try {
                    resolve(JSON.parse(text) as T);
                } catch (error) {
                    reject(new Error(`${socketPath} ${method} ${pathAndQuery}: bad JSON (${String(error)})`));
                }
            });
        });
        request.on("timeout", () => request.destroy(new Error(`${socketPath} ${method} ${pathAndQuery}: timed out after ${timeoutMs} ms`)));
        request.on("error", reject);
        request.end();
    });
}

/** The server's schema (`/schema` on the scenario server's host), for the state views. */
export async function fetchSchema(serverUrl: string): Promise<unknown> {
    const base = new URL(serverUrl);
    base.protocol = base.protocol === "wss:" ? "https:" : "http:";
    base.pathname = "/schema";
    base.search = "";
    const response = await fetch(base, { signal: AbortSignal.timeout(15_000) });
    if (!response.ok) {
        throw new Error(`--reconstruct: GET ${base} answered HTTP ${response.status}`);
    }
    return response.json();
}
