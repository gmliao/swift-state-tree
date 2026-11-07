import { describe, it, expect } from "vitest";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { PROFILE_WAIT_TIMEOUT_MS } from "../src/server-sync";
import { SHUTDOWN_REPLY_TIMEOUT_MS, WORKER_EXIT_TIMEOUT_MS } from "../src/run";

const SCRIPT = path.join(__dirname, "..", "scripts", "impair.sh");

/** Runs impair.sh in dry-run mode: commands are printed, not run. */
function impair(args: string[], state: string, nowMs = 1_000_000, env: Record<string, string> = {}) {
    const result = spawnSync("bash", [SCRIPT, ...args], {
        encoding: "utf8",
        env: { ...process.env, IMPAIR_DRY_RUN: "1", IMPAIR_STATE: state, IMPAIR_FAKE_NOW_MS: String(nowMs), ...env }
    });
    return { status: result.status, out: result.stdout, err: result.stderr };
}

function commands(out: string): string[] {
    return out.split("\n").filter((l) => l.startsWith("+ ")).map((l) => l.slice(2));
}

describe("load_test_timeout (run-ws-loadtest.sh)", () => {
    const helper = path.join(__dirname, "..", "scripts", "load-test-timeout.sh");
    const timeout = (...args: string[]) =>
        execFileSync("bash", ["-c", `. "${helper}"; load_test_timeout "$@"`, "bash", ...args], { encoding: "utf8" }).trim();

    // Phases 120 s in 3 phases: 120 + 3 x 10 (transitions) + 30 (shutdown) + 10 (exit) + 3 (profile) + 15 (margin).
    it("is the wait until --start-at, the phases and the client's end budget", () => {
        expect(timeout("120", "3")).toBe("208");
        expect(timeout("120", "1")).toBe("188");
        expect(timeout("120", "3", "1000060000", "1000000000")).toBe("268");
        expect(timeout("120", "3", "1000000001", "1000000000")).toBe("209", "a partial second rounds up");
        expect(timeout("120", "3", "1000000000", "1000000500")).toBe("208", "a start already past adds nothing");
        expect(timeout("120", "3", "1000000000", "1000005000")).toBe("208", "nor takes anything away");
    });

    it("budgets at least the client's own end bounds", () => {
        const value = (name: string) =>
            Number(execFileSync("bash", ["-c", `. "${helper}"; echo "$` + "{" + `${name}}"`], { encoding: "utf8" }).trim());
        expect(value("LOAD_TEST_SHUTDOWN_S") * 1000).toBeGreaterThanOrEqual(SHUTDOWN_REPLY_TIMEOUT_MS);
        expect(value("LOAD_TEST_WORKER_EXIT_S") * 1000).toBeGreaterThanOrEqual(WORKER_EXIT_TIMEOUT_MS);
        expect(value("LOAD_TEST_PROFILE_WAIT_S") * 1000).toBeGreaterThanOrEqual(PROFILE_WAIT_TIMEOUT_MS);
    });
});

describe("impair.sh (dry run)", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "impair-"));
    const state = path.join(dir, "state");
    const timeline = path.join(dir, "timeline.json");

    it("setup builds the router topology and both qdisc trees with explicit limits", () => {
        const { status, out } = impair(["setup", "--limit-down", "20000", "--limit-up", "12000", "--with-good"], state);
        expect(status).toBe(0);
        const cmds = commands(out);
        expect(cmds).toContain("ip netns exec lt-router tc qdisc add dev veth-c1 root handle 1: netem delay 0ms limit 20000");
        expect(cmds).toContain("ip netns exec lt-router tc qdisc add dev veth-c1 parent 1:1 pfifo limit 20000");
        expect(cmds).toContain("ip netns exec lt-router tc qdisc add dev veth-g1 root pfifo limit 20000");
        // Unclassified traffic (ARP) goes to the unshaped band; only lt-client's sources to netem.
        expect(cmds).toContain("ip netns exec lt-router tc qdisc add dev veth-s1 root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
        expect(cmds).toContain("ip netns exec lt-router tc qdisc add dev veth-s1 parent 1:2 handle 20: netem delay 0ms limit 12000");
        expect(cmds).toContain("ip netns exec lt-router tc filter add dev veth-s1 parent 1: protocol ip prio 1 u32 match ip src 10.201.0.0/24 flowid 1:2");
        // The server namespace routes both client subnets through the router; the clients default to it.
        expect(cmds).toContain("ip route add 10.201.0.0/24 via 10.200.0.2");
        expect(cmds).toContain("ip route add 10.202.0.0/24 via 10.200.0.2");
        expect(cmds).toContain("ip netns exec lt-client ip route add default via 10.201.0.1");
        expect(cmds).toContain("ip netns exec lt-router sysctl -qw net.ipv4.ip_forward=1");
        // No netem on either TCP endpoint's own egress.
        expect(cmds.filter((c) => c.includes("netem")).every((c) => c.includes("lt-router"))).toBe(true);
        // Offloads off on every veth end.
        for (const dev of ["veth-s0", "veth-s1", "veth-c1", "veth-c0", "veth-g1", "veth-g0"]) {
            expect(cmds.some((c) => c.includes(`ethtool -K ${dev} tso off gso off gro off`))).toBe(true);
        }
        expect(fs.readFileSync(state, "utf8")).toContain("LIMIT_DOWN=20000");
    });

    it("refuses setup without limits", () => {
        const { status, err } = impair(["setup"], path.join(dir, "none"));
        expect(status).toBe(1);
        expect(err).toMatch(/--limit-down N and --limit-up N/);
    });

    it("apply and lift change in place, always passing the setup's limits, and log each to the timeline", () => {
        let r = impair(["apply", "BO75", "--timeline", timeline], state, 2_000_000);
        expect(r.status).toBe(0);
        expect(commands(r.out)).toEqual([
            "ip netns exec lt-router tc qdisc change dev veth-c1 root handle 1: netem delay 0ms loss 100% rate 0bit limit 20000",
            "ip netns exec lt-router tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 0ms loss 100% rate 0bit limit 12000"
        ]);
        r = impair(["lift", "--timeline", timeline], state, 2_075_000);
        // The lift first takes every impaired socket's state (RTO, backoff), on both ends.
        expect(commands(r.out)).toEqual([
            "ip netns exec lt-client ss -tin",
            "ss -tin dst 10.201.0.0/24",
            "ip netns exec lt-router tc qdisc change dev veth-c1 root handle 1: netem delay 0ms loss 0% rate 0bit limit 20000",
            "ip netns exec lt-router tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 0ms loss 0% rate 0bit limit 12000"
        ]);
        const entries = JSON.parse(fs.readFileSync(timeline, "utf8"));
        expect(entries.map((e: any) => [e.action, e.profile, e.wallMsAfter])).toEqual([
            ["apply", "BO75", 2_000_000],
            ["lift", "P0", 2_075_000]
        ]);
        expect(entries[0].commands).toHaveLength(2);
        expect(entries[0]).toHaveProperty("before");
        expect(entries[0]).toHaveProperty("after");
        expect(entries[0]).toHaveProperty("monoSBefore");
    });

    it("maps each planned profile to its netem arguments; rate profiles need --rate", () => {
        const down = (profile: string, extra: string[] = []) =>
            commands(impair(["apply", profile, ...extra, "--timeline", path.join(dir, "t2.json")], state).out)[0];
        expect(down("D50J10")).toContain("netem delay 50ms 10ms loss 0% rate 0bit limit 20000");
        expect(down("L5")).toContain("netem delay 25ms loss 5% rate 0bit limit 20000");
        expect(down("RATE", ["--rate", "40mbit"])).toContain("netem delay 0ms loss 0% rate 40mbit limit 20000");
        expect(down("COMBO", ["--rate", "64mbit"])).toContain("netem delay 40ms 10ms loss 1% rate 64mbit limit 20000");
        // COMBO without its rate, both directions, and no --rate needed (the calibration of COMBO's delay).
        const norate = commands(impair(["apply", "COMBO_NORATE", "--timeline", path.join(dir, "t5.json")], state).out);
        expect(norate).toEqual([
            "ip netns exec lt-router tc qdisc change dev veth-c1 root handle 1: netem delay 40ms 10ms loss 1% rate 0bit limit 20000",
            "ip netns exec lt-router tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 40ms 10ms loss 1% rate 0bit limit 12000"
        ]);
        // SR shapes nothing (its clients pause their reads) but is recorded as SR in the timeline.
        const srFile = path.join(dir, "t6.json");
        const sr = commands(impair(["apply", "SR", "--timeline", srFile], state).out);
        expect(sr).toEqual([
            "ip netns exec lt-router tc qdisc change dev veth-c1 root handle 1: netem delay 0ms loss 0% rate 0bit limit 20000",
            "ip netns exec lt-router tc qdisc change dev veth-s1 parent 1:2 handle 20: netem delay 0ms loss 0% rate 0bit limit 12000"
        ]);
        expect(JSON.parse(fs.readFileSync(srFile, "utf-8"))[0].profile).toBe("SR");
        const noRate = impair(["apply", "RATE", "--timeline", path.join(dir, "t3.json")], state);
        expect(noRate.status).toBe(1);
        expect(noRate.err).toMatch(/RATE needs --rate/);
        expect(impair(["apply", "NOPE", "--timeline", path.join(dir, "t3.json")], state).err).toMatch(/unknown profile/);
    });

    it("fails a change whose qdiscs don't show the profile, after writing its timeline entry", () => {
        // The dumps a host captured: COMBO applied, then a lift whose `tc qdisc change` kept the
        // rate (it wasn't restated), so the "unimpaired" recovery stayed at 135 kbit/s.
        const fixture = (name: string) => path.join(__dirname, "fixtures", name);
        const comboState = path.join(dir, "combo-state");
        expect(impair(["setup", "--limit-down", "168", "--limit-up", "10000"], comboState).status).toBe(0);
        const file = path.join(dir, "t7.json");
        const applied = impair(["apply", "COMBO", "--rate", "134907bit", "--timeline", file], comboState, 1_000, {
            IMPAIR_FAKE_AFTER_DUMP: fixture("impair-after-combo-apply.txt")
        });
        expect(applied.status, applied.err).toBe(0);
        const lifted = impair(["lift", "--timeline", file], comboState, 2_000, {
            IMPAIR_FAKE_AFTER_DUMP: fixture("impair-after-lift-rate-kept.txt")
        });
        expect(lifted.status).toBe(1);
        expect(lifted.err).toMatch(/lift P0 at 2000: the qdiscs don't show the profile/);
        expect(lifted.err).toMatch(/downstream \(veth-c1 1:\): rate 134904 bit\/s, wanted none/);
        // The entry is still there, with the dump that failed.
        const entries = JSON.parse(fs.readFileSync(file, "utf8"));
        expect(entries.map((e: any) => [e.action, e.profile])).toEqual([["apply", "COMBO"], ["lift", "P0"]]);
        expect(entries[1].after).toContain("rate 134904bit");
        // The netem line a host showed after the explicit lift (`rate 0bit`), in the same dump: passes.
        const fixed = impair(["lift", "--timeline", file], comboState, 2_500, {
            IMPAIR_FAKE_AFTER_DUMP: fixture("impair-after-lift-p0.txt")
        });
        expect(fixed.status, fixed.err).toBe(0);
        // The rate-kept lift dump checked as COMBO's own after-state also fails: delay and loss are gone.
        const asCombo = impair(["apply", "COMBO", "--rate", "134907bit", "--timeline", file], comboState, 3_000, {
            IMPAIR_FAKE_AFTER_DUMP: fixture("impair-after-lift-rate-kept.txt")
        });
        expect(asCombo.status).toBe(1);
        expect(asCombo.err).toMatch(/delayUs 0, wanted 40000/);
        expect(asCombo.err).toMatch(/lossPct 0, wanted 1/);
    });

    it("schedule applies at --at and lifts --for seconds later, and refuses a past start", () => {
        const file = path.join(dir, "t4.json");
        const r = impair(["schedule", "L5", "--at", "3000000", "--for", "60", "--timeline", file], state, 2_999_000);
        expect(r.status).toBe(0);
        expect(r.out).toContain("+ sleep until 3000000");
        expect(r.out).toContain("+ sleep until 3060000");
        const entries = JSON.parse(fs.readFileSync(file, "utf8"));
        expect(entries.map((e: any) => [e.action, e.profile])).toEqual([["apply", "L5"], ["lift", "P0"]]);
        const late = impair(["schedule", "L5", "--at", "3000000", "--for", "60", "--timeline", file], state, 3_000_001);
        expect(late.status).toBe(1);
        expect(late.err).toMatch(/already past/);
    });

    it("a lift whose socket capture exceeds the argument limit still records its entry", () => {
        // 3 MB: above Linux's 128 KiB single-argument limit and the whole ARG_MAX on macOS and Linux.
        const file = path.join(dir, "big.json");
        const r = impair(["schedule", "BO75", "--at", "3000000", "--for", "75", "--timeline", file], state, 2_999_000,
            { IMPAIR_FAKE_SOCKETS_BYTES: "3000000" });
        expect(r.status, r.err).toBe(0);
        const entries = JSON.parse(fs.readFileSync(file, "utf8"));
        expect(entries.map((e: any) => [e.action, e.profile])).toEqual([["apply", "BO75"], ["lift", "P0"]]);
        const lift = entries[1];
        expect(lift.socketsAtLiftFile).toBe("big-sockets-at-lift-1.txt");
        const side = path.join(dir, lift.socketsAtLiftFile);
        expect(fs.statSync(side).size).toBe(lift.socketsAtLiftBytes);
        expect(lift.socketsAtLiftBytes).toBeGreaterThan(3_000_000);
        expect(fs.readFileSync(side, "utf8")).toContain("ss -tin dst 10.201.0.0/24");
        // The capture's own times, numbers, taken before the change.
        expect(typeof lift.socketsAtLiftWallMsStart).toBe("number");
        expect(lift.socketsAtLiftWallMsStart).toBeLessThanOrEqual(lift.socketsAtLiftWallMsEnd);
        expect(lift.socketsAtLiftWallMsEnd).toBeLessThanOrEqual(lift.wallMsBefore);
        expect(lift).not.toHaveProperty("socketsAtLift");
        // Order: the before-snapshot, then the sockets, then the change, then the after-snapshot.
        const trace = path.join(dir, "lift.trace");
        impair(["lift", "--timeline", path.join(dir, "order.json")], state, 3_200_000, { IMPAIR_TRACE: trace });
        expect(fs.readFileSync(trace, "utf8").split("\n").filter(Boolean).map((s) => s.split(" ").slice(0, 9).join(" "))).toEqual([
            "snapshot",
            "sockets",
            "ip netns exec lt-router tc qdisc change dev veth-c1",
            "ip netns exec lt-router tc qdisc change dev veth-s1",
            "snapshot"
        ]);
        expect(entries[0]).not.toHaveProperty("socketsAtLiftFile");

        impair(["lift", "--timeline", file], state, 3_100_000);
        const again = JSON.parse(fs.readFileSync(file, "utf8"));
        expect(again[2].socketsAtLiftFile).toBe("big-sockets-at-lift-2.txt");
        expect(fs.existsSync(path.join(dir, "big-sockets-at-lift-1.txt"))).toBe(true);
    });

    it("a lift whose timeline entry can't be written fails loudly, naming when the change ran", () => {
        const unwritable = path.join(dir, "dir.json");
        fs.mkdirSync(unwritable);
        const r = impair(["lift", "--timeline", unwritable], state, 4_000_000);
        expect(r.status).not.toBe(0);
        expect(r.err).toMatch(/lift P0 ran at 4000000 .*could not be written to .*dir\.json/);
        // Its capture stays, and the next lift's capture doesn't overwrite it.
        expect(fs.existsSync(path.join(dir, "dir-sockets-at-lift-1.txt"))).toBe(true);
        impair(["lift", "--timeline", unwritable], state, 4_100_000);
        expect(fs.existsSync(path.join(dir, "dir-sockets-at-lift-2.txt"))).toBe(true);
    });

    it("teardown removes the namespaces and the state", () => {
        const { status, out } = impair(["teardown"], state);
        expect(status).toBe(0);
        expect(commands(out)).toContain("ip netns del lt-router");
        expect(fs.existsSync(state)).toBe(false);
        expect(execFileSync("bash", ["-n", SCRIPT]).toString()).toBe("");
    });
});
