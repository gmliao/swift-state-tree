import fs from "node:fs";
import { controlRequest } from "./control";
import { MAX_CONCURRENCY, runConvergence, type ConvergenceInstance, type DebugStateApi } from "./converge";
import { loadSdkCore } from "./reconstruction";
import type { ConvergenceConnection } from "./worker";

/**
 * `node dist/converge-main.js --control <name>=<socket> [--control ...] --admin-url <url>
 *    --api-key <key> --out <convergence.json> [--land-type hero-defense] [--concurrency 20]
 *    [--deadline-s <s>]`
 *
 * The convergence check at the end of a network impairment run (design § 6, `converge.ts`):
 * stops every instance's sends through its control socket (`--control-socket` of each client
 * instance, run with `--reconstruct`), checks every land through the admin debug routes, and
 * writes the report. Exits 0 once the report is written, whatever it says; the analysis judges it.
 * `--deadline-s` stops starting land checks that late after the start (the lands left are errors),
 * so the check ends before the scenario's phase end closes the connections.
 */
const USAGE =
    "Usage: node dist/converge-main.js --control <name>=<socket> [--control ...] --admin-url <url> --api-key <key> --out <file> [--land-type <type>] [--concurrency <n>] [--deadline-s <s>]";

interface Args {
    controls: Array<{ name: string; socket: string }>;
    adminUrl: string;
    apiKey: string;
    out: string;
    landType: string;
    concurrency: number;
    deadlineMs?: number;
}

export function parseConvergeArgs(argv: string[]): Args {
    const controls: Args["controls"] = [];
    let adminUrl: string | undefined;
    let apiKey: string | undefined;
    let out: string | undefined;
    let landType = "hero-defense";
    let concurrency = MAX_CONCURRENCY;
    let deadlineMs: number | undefined;
    for (let i = 0; i < argv.length; i += 2) {
        const [flag, value] = [argv[i], argv[i + 1]];
        if (value === undefined || value.startsWith("--")) {
            throw new Error(`${USAGE}\n(${flag} needs a value)`);
        }
        if (flag === "--control") {
            const match = /^([^=]+)=(.+)$/.exec(value);
            if (!match) throw new Error(`--control must be <name>=<socket> (got ${value})`);
            controls.push({ name: match[1], socket: match[2] });
        } else if (flag === "--admin-url") {
            adminUrl = value;
        } else if (flag === "--api-key") {
            apiKey = value;
        } else if (flag === "--out") {
            out = value;
        } else if (flag === "--land-type") {
            landType = value;
        } else if (flag === "--concurrency" && Number.isInteger(Number(value)) && Number(value) > 0) {
            if (Number(value) > MAX_CONCURRENCY) {
                throw new Error(`--concurrency ${value} is above ${MAX_CONCURRENCY}, the design's limit on lands frozen at once`);
            }
            concurrency = Number(value);
        } else if (flag === "--deadline-s" && Number(value) > 0) {
            deadlineMs = Number(value) * 1000;
        } else {
            throw new Error(`${USAGE}\n(bad argument: ${flag} ${value})`);
        }
    }
    if (controls.length === 0 || !adminUrl || !apiKey || !out) {
        throw new Error(USAGE);
    }
    return { controls, adminUrl, apiKey, out, landType, concurrency, deadlineMs };
}

function instance(name: string, socket: string): ConvergenceInstance {
    return {
        name,
        async stopSending() {
            await controlRequest(socket, "POST", "/stop-sending");
        },
        async lands(only?: string[], withStates?: string[]) {
            const query = new URLSearchParams();
            for (const land of only ?? []) query.append("land", land);
            for (const land of withStates ?? []) query.append("states", land);
            const text = query.toString();
            const reply = await controlRequest<{ connections: ConvergenceConnection[] }>(socket, "GET", `/lands${text ? `?${text}` : ""}`);
            return reply.connections;
        }
    };
}

/** `/admin/lands/:landID/debug/{freeze,projection,resume}`, as `Tools/CLI`'s `DebugStateClient` calls them. */
function debugApi(adminUrl: string, apiKey: string): DebugStateApi {
    const base = adminUrl.replace(/\/+$/, "");
    const call = async <T>(method: string, landID: string, route: string): Promise<T> => {
        const url = `${base}/admin/lands/${encodeURIComponent(landID)}/debug/${route}`;
        const response = await fetch(url, { method, headers: { "X-API-Key": apiKey }, signal: AbortSignal.timeout(15_000) });
        const text = await response.text();
        let body: { success?: boolean; data?: T; error?: { message?: string } } | undefined;
        try {
            body = text ? JSON.parse(text) : undefined;
        } catch {
            body = undefined;
        }
        if (!response.ok || !body?.success || body.data === undefined) {
            throw new Error(`${method} ${route.split("?")[0]} (${landID}) answered HTTP ${response.status}: ${body?.error?.message ?? text.slice(0, 200)}`);
        }
        return body.data;
    };
    return {
        freeze: (landID) => call("POST", landID, "freeze"),
        projection: (landID, playerID) => call("GET", landID, `projection?playerID=${encodeURIComponent(playerID)}`),
        resume: (landID, token) => call("POST", landID, `resume?freezeToken=${encodeURIComponent(token)}`)
    };
}

async function main(): Promise<void> {
    const args = parseConvergeArgs(process.argv.slice(2));
    const { compareStates } = await loadSdkCore();
    const report = await runConvergence({
        instances: args.controls.map((c) => instance(c.name, c.socket)),
        debug: debugApi(args.adminUrl, args.apiKey),
        compareStates,
        landType: args.landType,
        concurrency: args.concurrency,
        deadlineMs: args.deadlineMs
    });
    fs.writeFileSync(args.out, `${JSON.stringify(report, null, 2)}\n`);
    const t = report.totals;
    console.log(
        `convergence: lands=${t.lands} converged=${t.converged} convergedLate=${t.convergedLate} (max ${t.lateMaxMs ?? "–"} ms) ` +
            `mismatched=${t.mismatched} missingClients=${t.missingClients} ` +
            `inconclusive=${t.inconclusive} errors=${t.errors} reconnected=${t.reconnected.converged}/${t.reconnected.compared} ` +
            `in ${((report.endedAt - report.startedAt) / 1000).toFixed(1)} s -> ${args.out}`
    );
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error instanceof Error ? error.message : String(error));
        process.exit(1);
    });
}
