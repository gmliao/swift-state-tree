#!/usr/bin/env python3
"""A helper, not a gate: finds accesses to the keeper's model while a turn body holds it.

Not run by CI or pre-push. It reads text, not Swift syntax, so it guards against honest mistakes
during a conversion, not against code written to get past it; what it doesn't see is listed
below. A syntax-based rule (SwiftParser) is the follow-up that could become a gate.

A turn body holds `LandKeeper.model` for its whole call: `withTurn` passes it `inout` as `m`, and
the functions the body calls take it as `_ m: inout KeeperModel<State>` (or by value, to read).
While the hold is open, any other access to `self.model` overlaps it. `model` is a stored property
of an actor, so the overlap is checked at run time, in release builds too, and traps
("Simultaneous accesses ... modification requires exclusive access"). The compiler can't see it,
and a test finds it only on a path the test runs.

This lint checks every path by name. A *holder* is a member function with a parameter
`_ m: inout KeeperModel<` or `_ m: KeeperModel<`, or a closure passed to `withTurn` or
`withTurnSubmitting`. A member *reaches* the model when its body names `model`, or when it calls
or reads (transitively) a member that does. A holder must not name `model`, and must not call or
read a member that reaches it, except a holder overload called with `m` first (`f(&m, ...)`,
`f(m, ...)`). Code inside `Task { ... }` runs after the hold ends and isn't checked.

It matches names, not types. A local that shares a member's name can make a false report (rename
the local), and a call through another receiver (`other.f()`) is not followed. The run-time check
in the debug test suite stays the proof for the paths the tests run.

Usage: scripts/lint-model-holds.py [--self-test] [--list] [file ...]
       (default file: Sources/SwiftStateTree/Runtime/LandKeeper.swift)
"""
import re
import sys
import tempfile
from pathlib import Path

DEFAULT = [Path("Sources/SwiftStateTree/Runtime/LandKeeper.swift")]
HOLD_PARAM = re.compile(r"_ m: (inout )?KeeperModel<")
MEMBER_FUNC = re.compile(
    r"^    (?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|package|public|internal|fileprivate|nonisolated|static|mutating|override)\s+)*"
    r"func\s+([A-Za-z_]\w*)"
)
MEMBER_VAR = re.compile(
    r"^    (?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|package|public|internal|fileprivate|nonisolated|static|override)\s+)*"
    r"(?:private\(set\)\s+)?var\s+([A-Za-z_]\w*)\s*:[^=]*\{"
)
TURN_CLOSURE = re.compile(r"\bwithTurn(?:Submitting)?\s*\{")
TASK_START = re.compile(r"\bTask(?:\.detached)?\s*(?:\([^)]*\))?\s*\{")
MODEL = re.compile(r"(?<![\w.\"])model\b|\bself\.model\b")
# A call or a read of a member: `name(`, `self.name`, or a bare `name` not after a dot.
NAME = re.compile(r"(?:(?<![\w.])|(?<=self\.))([A-Za-z_]\w*)\b(\s*\()?")


def code(line: str) -> str:
    """The line without its `//` comment."""
    return re.sub(r"//.*", "", line)


def block_end(lines, start):
    """The index of the line that closes the brace opened first at or after `start`."""
    depth = 0
    opened = False
    for k in range(start, len(lines)):
        for ch in code(lines[k]):
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
        if opened and depth <= 0:
            return k
    return len(lines) - 1


class Member:
    def __init__(self, name, start, end, holder, is_func):
        self.name, self.start, self.end, self.holder, self.is_func = name, start, end, holder, is_func


KEEPER = re.compile(r"^(?:[a-z@][\w@() ]* )?(?:actor|extension) LandKeeper\b")


def keeper_ranges(lines):
    """The line ranges of `actor LandKeeper` and its extensions: only their members count."""
    ranges = []
    for k, line in enumerate(lines):
        if KEEPER.match(line):
            ranges.append((k, block_end(lines, k)))
    return ranges


def parse(lines):
    members = []
    inside = keeper_ranges(lines)
    k = 0
    while k < len(lines):
        if not any(a < k <= b for a, b in inside):
            k += 1
            continue
        line = lines[k]
        m = MEMBER_FUNC.match(line)
        v = MEMBER_VAR.match(line) if not m else None
        if m or v:
            end = block_end(lines, k)
            if m:
                # The signature runs until the line that opens the body.
                sig_end = k
                while sig_end < end and "{" not in code(lines[sig_end]):
                    sig_end += 1
                signature = " ".join(lines[k:sig_end + 1])
                members.append(Member(m.group(1), sig_end, end, bool(HOLD_PARAM.search(signature)), True))
            else:
                members.append(Member(v.group(1), k, end, False, False))
            k = end + 1
            continue
        k += 1
    return members


def is_label(text, match):
    """An argument label or a declared name (`failure:`, `let failure =`), not a use."""
    after = text[match.end(1):]
    before = text[:match.start(1)]
    return bool(re.match(r"\s*:(?!:)", after)) or bool(re.search(r"\b(let|var|case|func)\s+$", before))


def task_lines(lines, start, end):
    """Lines inside `Task { ... }` blocks between start and end: they run after the hold."""
    skipped = set()
    for k in range(start, end + 1):
        if k in skipped:
            continue
        if TASK_START.search(code(lines[k])):
            close = block_end(lines, k)
            skipped.update(range(k, close + 1))
    return skipped


def body_lines(lines, start, end):
    """The body's lines, from the text after the brace that opens it on line `start`."""
    skipped = task_lines(lines, start, end)
    out = []
    for k in range(start, end + 1):
        if k in skipped:
            continue
        text = code(lines[k])
        if k == start:
            text = text[text.index("{") + 1:] if "{" in text else ""
        out.append((k, text))
    return out


def check(path: Path):
    lines = path.read_text(encoding="utf-8").split("\n")
    members = parse(lines)
    by_name = {}
    for mem in members:
        by_name.setdefault(mem.name, []).append(mem)

    # The members that reach the model: naming it, or (transitively) using a member that does.
    # A member is keyed by name and kind (a function or a property), so a property and a function
    # of the same name (`failure`, `failure(for:)`) stay apart.
    properties = {mem.name for mem in members if not mem.is_func}

    def target(match):
        """The member a use names: a call is a function; a bare name is a property of that name,
        or else a function passed as a value (`map(held)`), which may run during the hold."""
        name, call = match.group(1), match.group(2)
        return (name, bool(call) or name not in properties)

    plain = [mem for mem in members if not mem.holder]
    reaches = set()
    uses = {}
    for mem in plain:
        key = (mem.name, mem.is_func)
        body = body_lines(lines, mem.start, mem.end)
        if any(MODEL.search(text) for _, text in body):
            reaches.add(key)
        uses[key] = uses.get(key, set()) | {
            target(n) for _, text in body for n in NAME.finditer(text) if not is_label(text, n)
        }
    changed = True
    while changed:
        changed = False
        for key, used in uses.items():
            if key not in reaches and used & reaches:
                reaches.add(key)
                changed = True

    # The holders: functions taking the model, and the closures given to `withTurn`.
    holders = [(mem.name, mem.start, mem.end) for mem in members if mem.holder]
    for k, line in enumerate(lines):
        if TURN_CLOSURE.search(code(line)) and not MEMBER_FUNC.match(line):
            holders.append(("withTurn body", k, block_end(lines, k)))

    failures = []
    for name, start, end in holders:
        for k, text in body_lines(lines, start, end):
            if MODEL.search(text):
                failures.append((k + 1, name, "names `model` while the body holds it; use `m`"))
            for n in NAME.finditer(text):
                used, call = n.group(1), n.group(2)
                if target(n) not in reaches or is_label(text, n):
                    continue
                if call:
                    rest = text[n.end():].lstrip()
                    has_holder_overload = any(mem.holder for mem in by_name.get(used, []))
                    if has_holder_overload and re.match(r"&?m\b", rest):
                        continue
                failures.append((k + 1, name, f"`{used}` reaches `model` while the body holds it"))
    return holders, failures


def run(paths, list_holders=False) -> int:
    status = 0
    for path in paths:
        holders, failures = check(path)
        if list_holders:
            for name, start, end in holders:
                print(f"holder {path}:{start + 1}-{end + 1} {name}")
        for line, name, why in sorted(set(failures)):
            print(f"FAIL  {path}:{line} in {name}: {why}")
            status = 1
        if not holders:
            print(f"FAIL  {path}: no holders found; the patterns stopped matching")
            status = 1
        print(f"{'ok' if status == 0 else 'failed'}: {len(holders)} holders in {path}")
    return status


SELF_TEST_SOURCE = """\
actor LandKeeper<State> {
    private var model: KeeperModel<State>

    private func withTurn<R>(_ body: (inout KeeperModel<State>) -> R) -> R {
        body(&model)
    }

    private func touches() { model.count += 1 }

    private func reachesThroughACall() { touches() }

    private var readsTheModel: Int { model.count }

    private var shared: Int { 0 }

    private func shared(_ n: Int) -> Int { model.count + n }

    private func clean() {}

    private func helper() { helper(&model) }

    private func helper(_ m: inout KeeperModel<State>) { m.count += 1 }

    private func goodHolder(_ m: inout KeeperModel<State>) {
        // model is named in a comment only.
        helper(&m)
        clean()
        let s = shared
        Task { await self.touches() }
        drainTask = Task {
            self.model.count = 0
        }
    }

    private func badDirect(_ m: inout KeeperModel<State>) {
        model.count += 1
    }

    private func badTransitive(_ m: inout KeeperModel<State>) {
        reachesThroughACall()
    }

    private func badOverload(_ m: KeeperModel<State>) {
        helper()
    }

    private func badProperty(_ m: inout KeeperModel<State>) {
        let n = readsTheModel
    }

    func entry() {
        withTurn { m in
            helper(&m)
        }
        withTurn { m in
            touches()
        }
    }
}
"""

SELF_TEST_EXPECTED = {"badDirect", "badTransitive", "badOverload", "badProperty", "withTurn body"}


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "LandKeeper.swift"
        path.write_text(SELF_TEST_SOURCE, encoding="utf-8")
        holders, failures = check(path)
    failed = {name for _, name, _ in failures}
    lines = {line for line, _, _ in failures}
    names = {name for name, _, _ in holders}
    ok = (
        failed == SELF_TEST_EXPECTED
        and len(failures) == len(SELF_TEST_EXPECTED)
        and {"goodHolder", "helper", "withTurn body"} <= names
        and len(lines) == len(failures)
    )
    if not ok:
        print("self-test FAILED")
        for failure in sorted(failures):
            print("  got:", failure)
        print("  expected failures in:", sorted(SELF_TEST_EXPECTED))
        return 1
    print("self-test ok")
    return 0


def main(argv) -> int:
    if "--self-test" in argv:
        return self_test()
    list_holders = "--list" in argv
    paths = [Path(a) for a in argv if not a.startswith("--")] or DEFAULT
    return run(paths, list_holders)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
