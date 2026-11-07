#!/usr/bin/env python3
"""Convert run.sh's raw outputs into one results/<cell>-rep<n>.json per cell and repeat, with
every gate of the design evaluated (stdlib only).

For every sweep raw/<RUN_ID>/ whose run.json isn't superseded, each cell directory <cell>/ that
cell.py finished becomes one result: the metrics (§ D4), the raw counts the gates compare, and
`gates`, a map of each gate to whether it held, with `failures` naming every one that didn't.
regenerate.py refuses any result with a failure. A sweep of a few cells (CELLS=...) is skipped.

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, collections, glob, gzip, json, pathlib, re, sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import cells  # noqa: E402

MASK = 0xFFFF_FFFF_FFFF_FFFF
JOIN_SALT, LEAVE_SALT = 3, 4
CLOSE_RECORD_LIMIT = 200  # ws-loadtest's cap on a phase's join-failure records (src/run.ts)
PROFILE_INTERVAL_MS = 1000
CANCEL_MARGIN_MS = 250
OUTCOMES = ("applied", "failed", "timedOut", "errored")


def mix(seed, index, salt):
    """SimulatedExternalService.mix (SplitMix64 of the seed, the index and a salt), in UInt64."""
    z = (seed + ((index * 0x9E37_79B9_7F4A_7C15) & MASK) + ((salt * 0xD1B5_4A32_D192_ED03) & MASK)) & MASK
    z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK
    z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & MASK
    return z ^ (z >> 31)


def fails(seed, index, salt, rate):
    return (mix(seed, index, salt) >> 11) / float(1 << 53) < rate


def expected_failures(seed, checks, salt, rate):
    """A land's failed checks of one kind among its first `checks` (its counter starts at 0)."""
    return sum(fails(seed, n, salt, rate) for n in range(checks))


def percentile(buckets, q):
    """The q-quantile of a histogram {value: count}: the smallest value covering q of the count."""
    total = sum(buckets.values())
    if total == 0:
        return None
    seen = 0
    for value in sorted(buckets):
        seen += buckets[value]
        if seen >= q * total:
            return value
    return max(buckets)


def jsonl(path):
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()] if path.exists() else []


def samples(*directories):
    for f in sorted(f for directory in directories for f in glob.glob(str(directory / "w*.ndjson.gz"))):
        with gzip.open(f, "rt") as stream:
            for line in stream:
                if line.strip():
                    yield json.loads(line)


def sweeps(raw):
    claimed = {}
    for record_path in sorted(raw.glob("*/run.json")):
        record = json.loads(record_path.read_text())
        if record.get("superseded"):
            continue
        if record["repeat"] in claimed:
            sys.exit(f"repeat {record['repeat']} is claimed by both {claimed[record['repeat']][0].parent.name} "
                     f"and {record_path.parent.name}; mark one superseded (runmeta.py supersede)")
        claimed[record["repeat"]] = (record_path, record)
    return sorted(claimed.values(), key=lambda s: s[1]["repeat"])


def evaluate(d, record):
    """One cell directory's metrics, counts and gates."""
    meta = json.loads((d / "cell.json").read_text())
    c, name = meta["spec"], meta["cell"]
    if c != cells.CELLS[name]:
        sys.exit(f"{d}: the cell ran with another definition than cells.py has now")
    env = c["env"]
    seed = int(env["RESOLVER_TEST_SEED"])
    join_rate, leave_rate = float(env["RESOLVER_TEST_JOIN_FAILURE_RATE"]), float(env["RESOLVER_TEST_LEAVE_FAILURE_RATE"])
    gates, failures = {}, []

    def gate(key, ok, why):
        gates[key] = bool(ok)
        if not ok:
            failures.append(f"{key}: {why}")

    gate("cell_finished", meta.get("done") and "failure" not in meta, meta.get("failure", "cell.py didn't finish"))
    if not meta.get("done"):
        return meta, {}, {}, gates, failures
    def report_in(name):
        found = sorted((d / name).glob("ws-loadtest-*.json"))
        if len(found) != 1:
            sys.exit(f"{d}/{name}: expected one report, found {len(found)}")
        return json.loads(found[0].read_text())
    report = report_in("load")
    # The leave cell's second instance: its actions, joins and leaves count with the first's.
    instances = [report] + ([report_in("load-leavers")] if c["leavers"] else [])
    phases = {p["name"]: p for p in report["phases"]}
    steady = phases["steady"]
    profile = jsonl(d / "transport-profile.jsonl")
    probe = jsonl(d / "tick-probe.jsonl")
    states = json.loads((d / "client-states.json").read_text())["connections"]
    converge = json.loads((d / "converge.json").read_text())
    records = json.loads((d / "records.json").read_text())
    steps = meta["steps"]

    # Errors, disconnects and the outcome identity, over every phase.
    totals = [p["phaseTotals"] for r in instances for p in r["phases"]]
    outcomes = {k: sum(t["actionOutcomes"][k] for t in totals) for k in OUTCOMES + ("unmatched", "answeredAfterPhaseEnd")}
    sent = sum(t["actionsSent"] for t in totals)
    ends = [r["phases"][-1]["measurement"]["unanswered"]["phase"] for r in instances]
    pending = sum(e["pendingAtEnd"] + e["timedOutAtEnd"] for e in ends)
    errors = sum(t["errorCount"] for t in totals)
    disconnects = sum(t["disconnectCount"] for t in totals)
    gate("no_errors", errors == 0 and outcomes["errored"] == 0, f"errorCount {errors}, errored {outcomes['errored']}")
    gate("no_disconnects", disconnects == 0, f"{disconnects} disconnects")
    gate("one_outcome_per_request", sent == sum(outcomes[k] for k in OUTCOMES) + pending and outcomes["unmatched"] == 0,
         f"sent {sent}, outcomes {outcomes}, pending at the end {pending}")
    gate("none_pending_at_end", pending == 0, f"{pending} requests unanswered when the run ended")
    for kind in ("failed", "timedOut"):
        if kind in c["injects"]:
            gate(f"{kind}_injected", outcomes[kind] > 0, f"the cell injects {kind} and none came")
        else:
            gate(f"{kind}_not_injected", outcomes[kind] == 0, f"{outcomes[kind]} {kind} answers in a cell that injects none")

    # Per land: the client's applied answers, the state, the record and the replay.
    land_of, applied_by_land, joined_by_land = {}, collections.Counter(), collections.Counter()
    last_sent, leaves_by_land = 0, collections.Counter()
    read_at = steps["states"]["readAt"]
    for r in samples(d / "samples", d / "samples-leavers"):
        if r["r"] == "join":
            land_of[r["k"]] = r["land"]
            joined_by_land[r["land"]] += 1
        elif r["r"] == "rtt":
            last_sent = max(last_sent, r["sentAt"])
            if r.get("outcome") == "applied":
                applied_by_land[r["k"]] += 1
        elif r["r"] == "late" and r["outcome"] == "applied":
            # The first answer to a request a phase end left unanswered.
            applied_by_land[r["k"]] += 1
        elif r["r"] == "close" and r["initiator"] == "client" and r["joined"] and r["t"] <= read_at:
            leaves_by_land[r["landInstanceId"]] += 1
    client_applied = collections.Counter()
    for k, n in applied_by_land.items():
        client_applied[land_of[k]] += n
    state_of = {}
    for conn in states:
        if conn["open"] and conn.get("state") is not None:
            state_of.setdefault(conn["land"], conn["state"])
    lands = [l.split(":", 1)[1] for l in steps["records"]["lands"]]
    gate("rooms", len(lands) == meta["rooms"], f"{len(lands)} lands, the cell has {meta['rooms']} rooms")
    values = lambda land: (state_of.get(land) or {}).get("values", state_of.get(land) or {})
    mismatched = [l for l in lands if not (client_applied[l] == values(l).get("applied") == records[f"{cells_land_type()}:{l}"]["recordedActions"])]
    gate("applied_per_room", not mismatched,
         f"rooms where client answers, state and record differ: " +
         ", ".join(f"{l} {client_applied[l]}/{values(l).get('applied')}/{records[cells_land_type() + ':' + l]['recordedActions']}" for l in mismatched[:5]))
    replayed = [v for v in records.values() if v["replayed"]]
    gate("replay", replayed and all(v["passed"] for v in replayed), f"{sum(not v['passed'] for v in replayed)} of {len(replayed)} replays failed")
    t = converge["totals"]
    gate("convergence", t["lands"] == len(lands) and t["converged"] + t["convergedLate"] == t["lands"]
         and not (t["mismatched"] or t["missingClients"] or t["inconclusive"] or t["errors"]), f"convergence totals {t}")

    # Server counters: timeouts and dropped leaves against the client.
    timeouts = sum(l["counters"]["resolverTimeouts"] for l in profile)
    gate("timeouts_match_server", timeouts == outcomes["timedOut"], f"server timeouts {timeouts}, client timedOut {outcomes['timedOut']}")
    abandoned = [l["counters"]["abandonedResolvers"] for l in profile]
    gate("drained", steps["drain"]["zeroTs"] is not None and abandoned and abandoned[-1] == 0,
         f"gauge at the end {abandoned[-1] if abandoned else None}")

    # Joins and leaves: each land's checks against the seeded draws.
    failure_records = [f for r in instances for p in r["phases"] for f in p["connectionLifecycle"]["joinFailureRecords"]]
    join_failures = [p["connectionLifecycle"]["joinFailures"] for r in instances for p in r["phases"]]
    gate("join_records_complete", all(j["phase"] <= CLOSE_RECORD_LIMIT for j in join_failures), "a phase's join-failure records were capped")
    gate("only_injected_join_failures", all(j["phase"] == j["injected"] for j in join_failures), f"join failures {join_failures}")
    injected_by_land = collections.Counter(f["land"] for f in failure_records)
    expected_joins, expected_leaves, bad_joins, bad_leaves = 0, 0, [], []
    for land in lands:
        attempts = joined_by_land[land] + injected_by_land[land]
        fail_j = expected_failures(seed, attempts, JOIN_SALT, join_rate)
        expected_joins += fail_j
        if not (values(land).get("joins") == attempts - fail_j and injected_by_land[land] == fail_j):
            bad_joins.append(f"{land}: attempts {attempts}, expected failures {fail_j}, injected {injected_by_land[land]}, joins {values(land).get('joins')}")
        fail_l = expected_failures(seed, leaves_by_land[land], LEAVE_SALT, leave_rate)
        expected_leaves += fail_l
        if values(land).get("leaves") != leaves_by_land[land] - fail_l:
            bad_leaves.append(f"{land}: leaves {leaves_by_land[land]}, expected drops {fail_l}, handled {values(land).get('leaves')}")
    # The leavers left before the quiet and drain waits, so every line holding their drops ends
    # before the states were read; the first instance's own leaves come after its tail.
    dropped = sum(l["counters"]["onLeaveDropped"] for l in profile if l["ts"] <= read_at)
    gate("joins_per_room", not bad_joins, "; ".join(bad_joins[:5]))
    gate("leaves_per_room", not bad_leaves, "; ".join(bad_leaves[:5]))
    gate("dropped_leaves_match_server", dropped == expected_leaves, f"server dropped {dropped}, expected {expected_leaves}")
    if leave_rate > 0:
        gate("leaves_happened", sum(leaves_by_land.values()) > 0, "no client left before the read")

    # Tick gaps over the probe windows inside the steady phase.
    lo = steady["measurement"]["originAt"]
    hi = lo + meta["steadyS"] * 1000
    inside = [l for l in probe if l["fromTs"] >= lo and l["ts"] <= hi]
    gate("probe_contiguous", inside and all(b["fromTs"] == a["ts"] for a, b in zip(inside, inside[1:]))
         and len({l["writeFailures"] for l in inside}) == 1, f"{len(inside)} windows, not contiguous or with write failures")
    buckets = collections.Counter()
    for l in inside:
        for ms, n in l["buckets"].items():
            buckets[int(ms)] += n
    advances = collections.Counter()
    for l in inside:
        for ticks, n in l.get("tickAdvances", {}).items():
            advances[int(ticks)] += n
    # Drain: the first profiler line after the last send whose gauge is 0 and stays 0. Its
    # resolution is one profiler interval; server and client clocks are one host's.
    drained_ts = None
    for i, l in enumerate(profile):
        if l["ts"] > last_sent and all(x["counters"]["abandonedResolvers"] == 0 for x in profile[i:]):
            drained_ts = l["ts"]
            break
    gate("gauge_settles", drained_ts is not None, "the gauge didn't stay at 0 after the last send")
    if cells.cooperative(c):
        # During the load the gauge samples cancellations in flight, which end promptly; a task
        # that outlives its deadline shows after the last send. Cooperative: the gauge is 0 for
        # good within the longest call plus one profiler interval of the last send, with a margin
        # for the cancellation's own latency.
        bound = last_sent + cells.longest_call_ms(c) + PROFILE_INTERVAL_MS + CANCEL_MARGIN_MS
        gate("cooperative_drained_in_time", drained_ts is not None and drained_ts <= bound,
             f"gauge at 0 for good at {drained_ts}, bound {bound} (last send + longest call + 1 interval + 250 ms)")

    rss = [s["rssMb"] for s in json.loads((d / "system-metrics.json").read_text())["system"]]
    metrics = {
        "tick_gap_p50_ms": percentile(buckets, 0.5), "tick_gap_p99_ms": percentile(buckets, 0.99),
        "tick_gap_max_ms": max((l["maxGapUs"] for l in inside), default=0) / 1000, "tick_gaps": sum(buckets.values()),
        "applied": outcomes["applied"], "failed": outcomes["failed"], "timed_out": outcomes["timedOut"],
        # No applied action in the steady phase (a cell where every call times out): no RTT.
        # The ack: send to the server's answer once the resolvers finished and the input was
        # queued; the handler applies it in the next tick (a land with a tick handler acks early).
        "ack_p50_ms": steady["phaseTotals"]["appliedRtt"]["p50"] if steady["phaseTotals"]["appliedRtt"]["count"] else None,
        "ack_p99_ms": steady["phaseTotals"]["appliedRtt"]["p99"] if steady["phaseTotals"]["appliedRtt"]["count"] else None,
        "tick_advance_p50": percentile(advances, 0.5), "tick_advance_p99": percentile(advances, 0.99),
        "tick_advance_count": sum(advances.values()),
        "abandoned_max": max(abandoned, default=0), "drain_ms": None if drained_ts is None else drained_ts - last_sent,
        "rss_mb_peak": max(rss, default=None),
        "replayed_rooms": len(replayed), "converged_rooms": t["converged"] + t["convergedLate"],
    }
    counts = {"abandonedEnd": abandoned[-1] if abandoned else None, "actionsSent": sent, "outcomes": outcomes, "pendingAtEnd": pending, "serverTimeouts": timeouts,
              "expectedJoinFailures": expected_joins, "expectedLeaveFailures": expected_leaves, "serverDroppedLeaves": dropped,
              "clientLeaves": sum(leaves_by_land.values()), "joinFailures": join_failures}
    return meta, metrics, counts, gates, failures


def cells_land_type():
    return "resolver-test"


def collect(raw, results):
    results.mkdir(parents=True, exist_ok=True)
    written = []
    for record_path, record in sweeps(raw):
        directory = record_path.parent
        if record.get("onlyCells"):
            print(f"skipping {directory.name}: only cells {record['onlyCells']}", file=sys.stderr)
            continue
        for d in sorted(p for p in directory.iterdir() if p.is_dir() and (p / "cell.json").exists()):
            meta, metrics, counts, gates, failures = evaluate(d, record)
            toolchain = (d / "load" / "toolchain.txt").read_text() if (d / "load" / "toolchain.txt").exists() else ""
            run_id = f"{meta['cell']}-rep{record['repeat']}"
            out = {
                "meta": {"git_sha": (record.get("git") or {}).get("commit"), "git_dirty": (record.get("git") or {}).get("dirty"),
                         "swift_version": record.get("swiftVersion"), "build_config": record.get("buildConfig"),
                         "node_version": record.get("nodeVersion"), "date": record.get("startedAt"),
                         "client_toolchain": toolchain.strip(), "source_dir": str(d.relative_to(raw))},
                "params": {"cell": meta["cell"], "rooms": meta["rooms"], "pre_s": meta["preS"], "steady_s": meta["steadyS"],
                           "tail_s": meta["tailS"], "players": cells.PLAYERS, "actions_per_second": cells.ACTIONS_PER_SECOND,
                           "outcome": meta["spec"]["outcome"], "injects": meta["spec"]["injects"], "env": meta["spec"]["env"],
                           "repeat": record["repeat"], "sweep": record["runId"]},
                "metrics": metrics, "counts": counts, "gates": gates, "failures": failures,
            }
            (results / f"{run_id}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
            written.append(run_id + ("" if not failures else f"  FAILED: {'; '.join(failures)}"))
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    args = ap.parse_args()
    for line in collect(args.raw, args.results):
        print(line)


if __name__ == "__main__":
    main()
