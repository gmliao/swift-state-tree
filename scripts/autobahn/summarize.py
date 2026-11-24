#!/usr/bin/env python3
"""Summarizes an Autobahn|Testsuite report: cases by result, by section, and the FAILED ids.

A case's result is the worse of its `behavior` (the data exchange) and its `behaviorClose` (the
closing handshake), in the order FAILED, UNIMPLEMENTED, NON-STRICT, INFORMATIONAL, OK.
`behaviorClose` can carry Autobahn's close-specific verdicts (`WRONG CODE`, `UNCLEAN`,
`FAILED BY CLIENT`); these are normalized to their severity equivalents before the comparison.

The script also validates the index: it exits non-zero unless the agent has exactly
EXPECTED_CASE_COUNT cases and every case has both `behavior` and `behaviorClose`.

Usage: summarize.py <reports/servers/index.json> [--failed-only | --expected-failures]
With --failed-only it prints just the FAILED case ids, one per line, sorted by section.
With --expected-failures it prints the FAILED cases as "<case id> <cause>" lines, the format of
expected-failures.txt. A cause is a guess from the case's report file (next to index.json):
  text-as-binary       the echo has the right payload in a binary frame where the case sent text
                       (the server sends every frame as binary, #798), and nothing else differs;
  guess:reserved-bits  section 3: a frame with RSV bits set wasn't failed;
  guess:reserved-opcode  section 4: a frame with a reserved opcode wasn't failed;
  guess:fragmentation  section 5: a bad fragment sequence wasn't failed, or fragments with pings
                       between them came back differently;
  guess:utf8           section 6: invalid UTF-8 in a text message wasn't failed with 1007;
  guess:close-code     section 7: an invalid close code or payload wasn't answered with 1002;
  guess:utf8-close-reason  section 7, specifically an invalid UTF-8 close reason;
  other                anything else.
Causes prefixed `guess:` are derived from the section number, not from the case report; they may
be wrong for individual cases.
"""
import json
import os
import sys
from collections import Counter, defaultdict

SEVERITY = ["FAILED", "UNIMPLEMENTED", "NON-STRICT", "INFORMATIONAL", "OK"]

# Autobahn close-specific verdicts not in SEVERITY; mapped to their severity equivalent.
CLOSE_VERDICT_MAP = {
    "WRONG CODE": "NON-STRICT",   # wrong close code, but connection closed
    "UNCLEAN": "FAILED",          # close handshake not completed
    "FAILED BY CLIENT": "NON-STRICT",  # Autobahn client couldn't complete close
}

# Cases that run today with the config in fuzzingclient.json (all except 9.*, 12.*, 13.*).
EXPECTED_CASE_COUNT = 247


def case_key(case_id: str):
    return [int(part) for part in case_id.split(".")]


def result_of(entry: dict) -> str:
    behavior = entry.get("behavior", "OK")
    close = entry.get("behaviorClose", "OK")
    close = CLOSE_VERDICT_MAP.get(close, close)
    results = [behavior, close]
    for result in SEVERITY:
        if result in results:
            return result
    return results[0]


SECTION_CAUSE = {
    "3": "guess:reserved-bits",
    "4": "guess:reserved-opcode",
    "5": "guess:fragmentation",
    "6": "guess:utf8",
    "7": "guess:close-code",
}

# Per-case overrides that contradict the section-level guess.
CASE_OVERRIDES = {
    # 7.5.1: code 1000 with an invalid UTF-8 reason; expected 1007/1002, not 1002 alone.
    "7.5.1": "guess:utf8-close-reason",
}


def cause_of(case_id: str, entry: dict, index_dir: str) -> str:
    """A guess at why a FAILED case failed; see the module's docstring."""
    if case_id in CASE_OVERRIDES:
        return CASE_OVERRIDES[case_id]
    try:
        with open(os.path.join(index_dir, entry["reportfile"]), encoding="utf-8") as f:
            report = json.load(f)
        expected = report["expected"].get("OK", [])
        received = report["received"]
        pairs = lambda events: [tuple(event[:2]) for event in events]
        flags = lambda events: [event[2] for event in events if event[0] == "message"]
        if (expected and pairs(expected) == pairs(received)
                and flags(expected) != flags(received)):
            return "text-as-binary"
    except (OSError, KeyError, ValueError):
        pass
    return SECTION_CAUSE.get(case_id.split(".")[0], "other")


def main(argv: list[str]) -> int:
    failed_only = "--failed-only" in argv
    expected_failures = "--expected-failures" in argv
    paths = [arg for arg in argv[1:] if not arg.startswith("--")]
    if len(paths) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    with open(paths[0], encoding="utf-8") as f:
        index = json.load(f)

    for agent, cases in index.items():
        # Validate completeness before summarizing.
        if len(cases) != EXPECTED_CASE_COUNT:
            print(
                f"summarize: {agent}: expected {EXPECTED_CASE_COUNT} cases, got {len(cases)}",
                file=sys.stderr,
            )
            return 8
        missing = [
            cid for cid, entry in cases.items()
            if "behavior" not in entry or "behaviorClose" not in entry
        ]
        if missing:
            print(
                f"summarize: {agent}: missing behavior/behaviorClose in {missing[:5]}"
                + (" ..." if len(missing) > 5 else ""),
                file=sys.stderr,
            )
            return 9

    for agent, cases in index.items():
        results = {case_id: result_of(entry) for case_id, entry in cases.items()}
        failed = sorted((c for c, r in results.items() if r == "FAILED"), key=case_key)
        if failed_only:
            print("\n".join(failed))
            continue
        if expected_failures:
            index_dir = os.path.dirname(os.path.abspath(paths[0]))
            for case_id in failed:
                print(f"{case_id} {cause_of(case_id, cases[case_id], index_dir)}")
            continue
        total = Counter(results.values())
        by_section: dict[str, Counter] = defaultdict(Counter)
        for case_id, result in results.items():
            by_section[case_id.split(".")[0]][result] += 1

        print(f"Autobahn|Testsuite summary for {agent}: {len(results)} cases")
        print("  " + ", ".join(f"{name}: {total.get(name, 0)}" for name in SEVERITY))
        print()
        print("  section  cases  " + "  ".join(f"{name:>13}" for name in SEVERITY))
        for section in sorted(by_section, key=int):
            counts = by_section[section]
            print(f"  {section:>7}  {sum(counts.values()):>5}  "
                  + "  ".join(f"{counts.get(name, 0):>13}" for name in SEVERITY))
        print()
        print(f"  FAILED ({len(failed)}): " + (", ".join(failed) if failed else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
