// Checks that the shaped netems show exactly a profile's parameters after a change, from a
// `tc -s qdisc show` dump (impair.sh's after-snapshot). `tc qdisc change ... netem` replaces
// delay, jitter and loss (the base options) but keeps an optional one, like `rate`, that the
// command doesn't restate: a lift that omitted `rate` left the rate limit in place. impair.sh
// states every parameter on every change; this check fails the run if the kernel shows
// anything else.
//
//   node netem-check.mjs --dump <file> --down "<netem args>" --up "<netem args>" --limit-down N --limit-up N
//
// Exits 1, naming every difference, when the downstream netem (veth-c1, handle 1:) or the
// upstream one (veth-s1, handle 20:) doesn't match.
import fs from "node:fs";

const UNITS = { bit: 1, kbit: 1e3, mbit: 1e6, gbit: 1e9, bps: 8, kbps: 8e3, mbps: 8e6, gbps: 8e9 };

function time(value) {
    const m = /^([\d.]+)(us|ms|s)?$/.exec(value);
    if (!m) throw new Error(`not a time: ${value}`);
    return Number(m[1]) * ({ us: 1, ms: 1000, s: 1e6 }[m[2] ?? "us"]);
}

/** netem options, as given to tc or as tc shows them, normalised: absent means 0. */
export function parseNetem(text) {
    const tokens = text.trim().split(/\s+/);
    const out = { limit: undefined, delayUs: 0, jitterUs: 0, lossPct: 0, rateBytes: 0 };
    for (let i = 0; i < tokens.length; i += 1) {
        const t = tokens[i];
        if (t === "limit") out.limit = Number(tokens[++i]);
        else if (t === "delay") {
            out.delayUs = time(tokens[++i]);
            if (tokens[i + 1] && /^[\d.]+(us|ms|s)$/.test(tokens[i + 1])) out.jitterUs = time(tokens[++i]);
        } else if (t === "loss") {
            if (tokens[i + 1] === "random") i += 1;
            out.lossPct = Number(tokens[++i].replace(/%$/, ""));
        } else if (t === "rate") {
            const m = /^([\d.]+)([a-z]+)$/i.exec(tokens[++i]);
            if (!m || !(m[2].toLowerCase() in UNITS)) throw new Error(`not a rate: ${tokens[i]}`);
            // The kernel keeps a rate in whole bytes per second.
            out.rateBytes = Math.floor((Number(m[1]) * UNITS[m[2].toLowerCase()]) / 8);
        }
    }
    return out;
}

/** The options line of the netem with `handle` in the `dev` section of a dump. */
export function shownNetem(dump, dev, handle) {
    const section = dump.split(/^== /m).find((s) => s.startsWith(`tc -s qdisc show dev ${dev}\n`));
    if (!section) throw new Error(`the dump has no qdisc section for ${dev}`);
    const line = section.split("\n").find((l) => l.startsWith(`qdisc netem ${handle} `));
    if (!line) throw new Error(`the dump has no netem ${handle} on ${dev}`);
    // "qdisc netem 1: root refcnt 13 limit 168 delay 40ms  10ms ...": the options follow the parent.
    return line.replace(/^qdisc netem \S+ (root|parent \S+)( refcnt \d+)?/, "");
}

/** Differences between what a change asked for and what the kernel shows, as sentences. */
export function compareNetem(name, wanted, shown) {
    const w = parseNetem(wanted);
    const s = parseNetem(shown);
    const differences = [];
    for (const key of ["limit", "delayUs", "jitterUs", "lossPct"]) {
        if (w[key] !== s[key]) differences.push(`${name}: ${key} ${s[key]}, wanted ${w[key]}`);
    }
    // tc shows the rate rounded through whole bytes per second (134907bit shows as 134904bit).
    const tolerance = Math.max(1, w.rateBytes * 0.001);
    if ((w.rateBytes === 0) !== (s.rateBytes === 0) || Math.abs(w.rateBytes - s.rateBytes) > tolerance) {
        differences.push(`${name}: rate ${s.rateBytes * 8} bit/s, wanted ${w.rateBytes * 8 || "none"}`);
    }
    return differences;
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const args = Object.fromEntries(
        process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith("--") ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), [])
    );
    try {
        const dump = fs.readFileSync(args.dump, "utf8");
        const differences = [
            ...compareNetem("downstream (veth-c1 1:)", `${args.down} limit ${args["limit-down"]}`, shownNetem(dump, "veth-c1", "1:")),
            ...compareNetem("upstream (veth-s1 20:)", `${args.up} limit ${args["limit-up"]}`, shownNetem(dump, "veth-s1", "20:"))
        ];
        if (differences.length > 0) {
            console.error(differences.join("\n"));
            process.exit(1);
        }
    } catch (error) {
        console.error(error instanceof Error ? error.message : String(error));
        process.exit(1);
    }
}
