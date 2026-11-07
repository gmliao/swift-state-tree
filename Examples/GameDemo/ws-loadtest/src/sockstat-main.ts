import { runSampler } from "./sockstat";

/**
 * `node dist/sockstat-main.js --out <file.jsonl> [--netns a,b,c] [--interval-ms 1000]`
 *
 * Samples TCP socket memory and queues (`sockstat.ts`) until SIGINT or SIGTERM. `--netns`
 * lists `ip netns` names; `-` stands for the sampler's own namespace. Default: its own only.
 */
const USAGE = "Usage: node dist/sockstat-main.js --out <file.jsonl> [--netns a,b,-] [--interval-ms 1000]";

function parse(argv: string[]): { out: string; namespaces: string[]; intervalMs: number } {
    let out: string | undefined;
    let namespaces = [""];
    let intervalMs = 1000;
    for (let i = 0; i < argv.length; i += 2) {
        const [flag, value] = [argv[i], argv[i + 1]];
        if (flag === "--out" && value) {
            out = value;
        } else if (flag === "--netns" && value) {
            namespaces = value.split(",").map((name) => (name === "-" ? "" : name));
        } else if (flag === "--interval-ms" && Number(value) >= 100) {
            intervalMs = Number(value);
        } else {
            throw new Error(`${USAGE}\n(bad argument: ${flag} ${value ?? ""})`);
        }
    }
    if (!out) {
        throw new Error(USAGE);
    }
    return { out, namespaces, intervalMs };
}

const { out, namespaces, intervalMs } = parse(process.argv.slice(2));
const controller = new AbortController();
process.on("SIGINT", () => controller.abort());
process.on("SIGTERM", () => controller.abort());
runSampler(namespaces, out, intervalMs, controller.signal).then(
    (count) => console.log(`sockstat: ${count} samples in ${out}`),
    (error) => {
        console.error(error);
        process.exit(1);
    }
);
