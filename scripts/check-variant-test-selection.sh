#!/usr/bin/env bash
# Safe test selection for the push runs' variant jobs, in the sense of Rothermel and Harrold
# (TOSEM 1997): a run is left out only if it can't reach the variable its job varies. The nightly
# runs everything (full_matrix), as the backstop. Two sections:
#
# 1. sync-tables-off. The sync-tables-off job runs only the Transport and NIO tests, with USE_SYNC_TABLES=false and
# TYPED_LEAF_VALUES=false. That is safe only while no other test can read those two flags, so this
# check fails if one could.
#
# The flags are read by every TransportEnvConfig (its `useSyncTables` and `typedLeafValues` default
# to the environment, a config built with `init` included) and by every TransportAdapter built
# without one. So, in every test target outside the filter that depends on SwiftStateTreeTransport,
# directly or through another target (from `swift package dump-package`), comments and string
# literals stripped:
#   R1 every TransportAdapter construction passes `transportEnvConfig:`;
#   R2 every TransportEnvConfig built there is built in a block that also sets both flags
#      (`useSyncTables` or `syncTablesEnabled`, and `typedLeafValues` or `typedLeafValuesEnabled`),
#      and none comes from `fromEnvironment`;
#   R3 nothing builds a LandManager, LandRouter, LandRealm or a land server or host, which build
#      adapters from the environment.
# The filtered targets are read from the job itself: its FILTER line in
# .github/workflows/build-and-test.yml, whose alternatives must each be a whole target (`Name\.`),
# and its one `swift test`, which must pass `${FILTER:+--filter "$FILTER"}`. So the job and this
# check can't name different targets, and the job can't run without the filter it declares.
#
# What it can't see (the nightly runs the whole suite in that job, as the backstop): R1 reads the
# argument labels, not their types, so a non-optional expression that is nil at run time isn't
# caught; R2 is textual, so it doesn't check that the pins set the same variable as the
# construction, and it counts a pin under an inactive `#if` or in a closure that never runs. The
# lexer is simple: a string interpolation holding a nested string literal can end a literal early,
# and a comma in a generic argument (`make<A, B>(…)`) ends the extracted expression there. A dump of
# the package this check can't read fails it rather than scanning nothing.
#
# 2. The build job's in-turn sync legs. On a push, the false leg skips the steps whose `if:` is
# `matrix.in_turn_sync == 'true' || inputs.full_matrix`.
#   S6 the job's matrix has one axis, in_turn_sync, used only as IN_TURN_SYNC (and in the job's
#      name and that `if:`): the legs differ in one variable, read at run time. A new axis, or the
#      axis in a compiler flag or another env var, fails until it is examined.
#   S4 a one-leg step runs only `scripts/<name>.sh [--self-test]`, and neither those scripts nor any
#      script they name (`scripts/*.sh` or `.py`, followed) mentions IN_TURN_SYNC, inTurnSync or
#      InTurnSync. Textual: a script that builds the flag's name from parts isn't seen.
#
# Usage: scripts/check-variant-test-selection.sh [--self-test] [--package-json <file>]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import pathlib
import re
import subprocess
import sys
import tempfile

WORKFLOW = ".github/workflows/build-and-test.yml"
JOB = "sync-tables-off"
TRANSPORT = "SwiftStateTreeTransport"
# The job's filter on a push: `FILTER: ${{ !inputs.full_matrix && '<regex>' || '' }}`, and the
# one `swift test` that must use it.
FILTERED_RUN = '${FILTER:+--filter "$FILTER"}'
FILTER_LINE = re.compile(r"""^\s*FILTER:\s*\$\{\{\s*!inputs\.full_matrix\s*&&\s*'([^']*)'\s*\|\|\s*''\s*\}\}\s*$""")

ADAPTER = re.compile(r"\bTransportAdapter\s*(?:<)?")
# `let a: TransportAdapter<S> = .init(…)`: the `.init(` is the construction.
ADAPTER_INIT = re.compile(r":\s*TransportAdapter\s*<[^=]*>\s*=\s*\.init\s*(?=\()")
CONFIG = re.compile(r"\bTransportEnvConfig\s*(?:\.init\s*)?\(|:\s*TransportEnvConfig\s*=\s*\.init\s*\(")
# Another name for either type would hide its constructions from R1 and R2.
ALIAS = re.compile(r"\btypealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(TransportAdapter|TransportEnvConfig)\b")
# A declaration's body, where a statement can't pin a config built in a stored property's default.
TYPE_BODY = re.compile(r"\b(?:struct|class|enum|extension|actor|protocol)\b[^{}();]*$")
FROM_ENV = re.compile(r"\bTransportEnvConfig\s*\.\s*fromEnvironment\b")
TABLES_PIN = re.compile(r"\.\s*(?:useSyncTables|syncTablesEnabled)\s*=[^=]")
LEAF_PIN = re.compile(r"\.\s*(?:typedLeafValues|typedLeafValuesEnabled)\s*=[^=]")
BUILDERS = re.compile(r"\b(LandManager|LandRouter|LandRealm|LandServer|NIOLandServer|NIOLandHost)\s*(?:<[^()]*>)?\s*\(")


def strip(source):
    """The source with comments and string literals blanked (newlines kept, so lines still count)."""
    out, i, n = [], 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", source[i:j]))
            i = j
        elif source.startswith('"""', i):
            j = source.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(re.sub(r"[^\n]", " ", source[i:j]))
            i = j
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(" " * (j - i))
            i = j
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def matching(text, start, open_char, close_char):
    """The index just past the bracket closing the one at `start`, or None."""
    depth = 0
    for k in range(start, len(text)):
        if text[k] == open_char:
            depth += 1
        elif text[k] == close_char:
            depth -= 1
            if depth == 0:
                return k + 1
    return None


def enclosing_block(text, pos):
    """The innermost `{ … }` holding `pos`, or None at the top level or directly in a type's body
    (a global, a `static let` or a stored property's default), where no statement can pin it."""
    opens = []
    for k in range(pos):
        if text[k] == "{":
            opens.append(k)
        elif text[k] == "}" and opens:
            opens.pop()
    if not opens:
        return None
    header_start = max(text.rfind(c, 0, opens[-1]) for c in "{};") + 1
    if TYPE_BODY.search(text[header_start:opens[-1]]):
        return None
    end = matching(text, opens[-1], "{", "}")
    return text[opens[-1]:end or len(text)]


def argument(args, label):
    """The expression passed for `label:` among the top-level arguments of an argument list
    `( … )`, or None. A label inside a nested call (`transport: make(label: x)`) is not it."""
    parts, depth, start = [], 0, 1
    for k in range(1, len(args)):
        c = args[k]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                parts.append(args[start:k])
                break
            depth -= 1
        elif c == "," and depth == 0:
            parts.append(args[start:k])
            start = k + 1
    for part in parts:
        m = re.match(r"\s*" + label + r"\s*:(.*)$", part, re.S)
        if m:
            return m.group(1).strip()
    return None


def filtered_targets(workflow):
    """The test targets the job runs on a push, from its FILTER line, and any error reading it."""
    lines = workflow.splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(r"^  " + JOB + r":\s*$", line)), None)
    if start is None:
        return set(), [f"{WORKFLOW}: no {JOB} job"]
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[i])), len(lines))
    found = [m for m in map(FILTER_LINE.match, lines[start:end]) if m]
    if len(found) != 1:
        return set(), [f"{WORKFLOW}: the {JOB} job has {len(found)} FILTER lines of the form this check reads, not one"]
    runs = [line for line in lines[start:end] if not line.lstrip().startswith("#") and re.search(r"\bswift test\b", line)]
    if len(runs) != 1 or FILTERED_RUN not in runs[0]:
        return set(), [f"{WORKFLOW}: the {JOB} job must run one `swift test {FILTERED_RUN}`; it has {len(runs)} swift test line(s)"
                       + ("" if len(runs) != 1 else " and that one ignores FILTER")]
    names, errors = set(), []
    for alternative in found[0].group(1).split("|"):
        m = re.fullmatch(r"(\w+)\\\.", alternative)
        if m:
            names.add(m.group(1))
        else:
            errors.append(f"{WORKFLOW}: the {JOB} filter's alternative {alternative!r} isn't a whole target (Name\\.)")
    return names, errors


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def check_source(name, source):
    errors = []
    text = strip(source)
    # Parameters declared `TransportEnvConfig?`: forwarding one may forward nil.
    optional_names = set(re.findall(r"\b(\w+)\s*:\s*TransportEnvConfig\s*\?", text))
    calls = []  # (where the construction starts, its `(`)
    for m in ADAPTER.finditer(text):
        k = m.end()
        if text[m.end() - 1] == "<":
            k = matching(text, m.end() - 1, "<", ">")
            if k is None:
                continue
        while k < len(text) and text[k] in " \t":
            k += 1
        if k < len(text) and text[k] == "(":
            calls.append((m.start(), k))
        # Otherwise a type annotation, `.self` or a generic argument.
    calls += [(m.start(), m.end()) for m in ADAPTER_INIT.finditer(text)]
    for start, paren in calls:
        end = matching(text, paren, "(", ")")
        config = argument(text[paren:end or len(text)], "transportEnvConfig")
        where = f"{name}:{line_of(text, start)}: R1"
        if config is None:
            errors.append(f"{where} a TransportAdapter built without transportEnvConfig: reads USE_SYNC_TABLES and TYPED_LEAF_VALUES from the environment")
        elif config == "nil" or config in optional_names:
            errors.append(f"{where} transportEnvConfig: {config} may be nil, and a nil config reads the flags from the environment")
    for m in ALIAS.finditer(text):
        errors.append(f"{name}:{line_of(text, m.start())}: R1/R2 a typealias for {m.group(1)} hides its constructions from this check")
    for m in FROM_ENV.finditer(text):
        errors.append(f"{name}:{line_of(text, m.start())}: R2 TransportEnvConfig.fromEnvironment reads the flags from the environment")
    for m in CONFIG.finditer(text):
        block = enclosing_block(text, m.start())
        if block is None:
            errors.append(f"{name}:{line_of(text, m.start())}: R2 a TransportEnvConfig built outside a function body (a global, a static or a stored property's default), where no statement can pin its flags")
            continue
        missing = [flag for flag, pin in (("useSyncTables", TABLES_PIN), ("typedLeafValues", LEAF_PIN)) if not pin.search(block)]
        if missing:
            errors.append(f"{name}:{line_of(text, m.start())}: R2 a TransportEnvConfig whose block doesn't set {' and '.join(missing)}, so it takes the environment's value")
    for m in BUILDERS.finditer(text):
        errors.append(f"{name}:{line_of(text, m.start())}: R3 {m.group(1)} builds adapters from the environment")
    return errors


DEPENDENCY_KINDS = {"byName", "target", "product"}


def target_deps(target):
    deps = []
    for d in target.get("dependencies", []):
        for kind in ("byName", "target"):
            if kind in d and d[kind]:
                deps.append(d[kind][0])
    return deps


def graph_errors(package):
    """A manifest dump this check can't read fails it, rather than scanning nothing: another
    toolchain's `dump-package` with no test targets, or a dependency of a kind it doesn't know."""
    targets = package.get("targets")
    if not isinstance(targets, list) or not any(t.get("type") == "test" for t in targets):
        return ["the package dump lists no test targets: this check can't read it (another toolchain's format?)"]
    errors = [f"{t.get('name')}: a test target with no dependencies field: this check can't read the dump"
              for t in targets if t.get("type") == "test" and not isinstance(t.get("dependencies"), list)]
    for t in targets:
        for d in t.get("dependencies", []):
            unknown = set(d) - DEPENDENCY_KINDS
            if unknown:
                errors.append(f"{t.get('name')}: a dependency of a kind this check doesn't know ({', '.join(sorted(unknown))}), so it can't tell whether it reaches {TRANSPORT}")
    return errors


def scanned_targets(package, filtered):
    """The test targets outside the filter that reach SwiftStateTreeTransport, and every target
    under Tests/ in their dependency closure that reaches it too (a test-support library a core test
    could build an adapter through), with their paths."""
    targets = {t["name"]: t for t in package["targets"]}
    path = lambda t: t.get("path") or f"Tests/{t['name']}"

    def reaches(name, seen):
        if name == TRANSPORT:
            return True
        if name in seen or name not in targets:
            return False
        seen.add(name)
        return any(reaches(d, seen) for d in target_deps(targets[name]))

    def closure(name, seen):
        if name in seen or name not in targets:
            return
        seen.add(name)
        for d in target_deps(targets[name]):
            closure(d, seen)

    out = []
    for t in package["targets"]:
        if t.get("type") == "test" and t["name"] not in filtered and reaches(t["name"], set()):
            seen = set()
            closure(t["name"], seen)
            for n in sorted(seen):
                s = targets[n]
                if (n == t["name"] or path(s).startswith("Tests/")) and reaches(n, set()) and (n, path(s)) not in out:
                    out.append((n, path(s)))
    return out


def check(root, package, filtered):
    errors, files = graph_errors(package), 0
    if errors:
        return errors, files
    for name, path in scanned_targets(package, filtered):
        directory = root / path
        if not directory.is_dir():
            errors.append(f"{name}: its directory {path} doesn't exist")
            continue
        for f in sorted(directory.rglob("*.swift")):
            files += 1
            errors += check_source(str(f.relative_to(root)), f.read_text(encoding="utf-8"))
    return errors, files


# Section 2: the build job's in-turn-sync legs. Steps that run in one leg only are safe while the
# leg's one variable can't change what they check.
BUILD_JOB = "build"
LEG_AXIS = "in_turn_sync"
LEG_ENV = "IN_TURN_SYNC"
ONE_LEG_IF = "if: ${{ matrix.in_turn_sync == 'true' || inputs.full_matrix }}"
# What the one-leg steps' scripts must not name: the flag, its key constant or its reader.
FLAG_NAMES = re.compile(r"IN_TURN_SYNC|\binTurnSync\b|\bInTurnSync\b")
SCRIPT_REF = re.compile(r"(?<![\w/.-])(scripts/[\w./-]+\.(?:sh|py))\b")
MATRIX_USE = re.compile(r"\bmatrix\s*(?:\.\s*\w+|\[)")
# The leg's variable anywhere but its env line: `env.IN_TURN_SYNC` in an `if:`, `$IN_TURN_SYNC` in a
# run line, or a second env var built from it.
LEG_ENV_USE = re.compile(r"\bIN_TURN_SYNC\b")


def job_lines(workflow, job):
    """The job's lines (its header included), or None."""
    lines = workflow.splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(r"^  " + re.escape(job) + r":\s*$", line)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[i])), len(lines))
    return lines[start:end]


def job_steps(lines):
    """The job's steps, each a list of its lines (a step starts at `    - `)."""
    steps, current = [], None
    for line in lines:
        if re.match(r"^    - ", line):
            current = [line]
            steps.append(current)
        elif current is not None and (line.startswith("      ") or not line.strip()):
            current.append(line)
        elif not line.lstrip().startswith("#"):
            current = None
    return steps


def leg_errors(workflow, read_script):
    """S6: the build job's matrix has one axis, in_turn_sync, used only as IN_TURN_SYNC (and in the
    job's name and the one-leg `if:`), so the legs differ in that one runtime variable. S4: a step
    that runs in one leg only runs scripts, and neither they nor the scripts they name read it.
    Returns the errors and the one-leg steps' names."""
    lines = job_lines(workflow, BUILD_JOB)
    if lines is None:
        return [f"{WORKFLOW}: no {BUILD_JOB} job"], []
    errors, where = [], f"{WORKFLOW}: the {BUILD_JOB} job"
    code = [line for line in lines if not line.lstrip().startswith("#")]
    m = next((i for i, line in enumerate(code) if re.match(r"^      matrix:\s*$", line)), None)
    axes = []
    if m is not None:
        for line in code[m + 1:]:
            if not line.startswith("        "):
                break
            key = re.match(r"^        ([\w-]+):", line)
            if key:
                axes.append(key.group(1))
    if axes != [LEG_AXIS]:
        errors.append(f"{where}'s matrix has the axes {axes}, not only {LEG_AXIS}: a new axis must be examined before its legs skip steps (S6)")
    allowed = (
        re.compile(r"^    name: .*\$\{\{ matrix\.in_turn_sync \}\}.*$"),
        re.compile(r"^      " + LEG_ENV + r": \$\{\{ matrix\.in_turn_sync \}\}\s*$"),
        re.compile(r"^      " + re.escape(ONE_LEG_IF) + r"\s*$"),
    )
    for line in code:
        if MATRIX_USE.search(line) and not any(a.match(line) for a in allowed):
            errors.append(f"{where} uses the matrix outside {LEG_ENV}, its name and the one-leg if: {line.strip()!r} (S6)")
        elif LEG_ENV_USE.search(line) and not allowed[1].match(line):
            errors.append(f"{where} uses {LEG_ENV} outside its env line: {line.strip()!r}; a step that reads it must run in both legs (S6)")
    one_leg, seen = [], set()  # a script named twice is read once
    for step in job_steps(lines):
        conditioned = [line for line in step if re.match(r"^\s*-?\s*if:", line)]
        if not any(MATRIX_USE.search(line) for line in conditioned):
            continue
        name = next((re.sub(r"^\s*-?\s*name:\s*", "", line).strip() for line in step if re.match(r"^\s*-?\s*name:", line)), "?")
        one_leg.append(name)
        run = [line for line in step if not line.lstrip().startswith("#")]
        start = next((i for i, line in enumerate(run) if re.match(r"^\s*-?\s*run:", line)), None)
        if start is None:
            errors.append(f"{where}'s one-leg step {name!r} has no run: (S4)")
            continue
        head = re.sub(r"^\s*-?\s*run:\s*", "", run[start]).strip()
        if head == "|":
            body = []
            for line in run[start + 1:]:
                if line.strip() and not line.startswith("        "):
                    break  # the step's next key (`timeout-minutes:`)
                body.append(line.strip())
            commands = [c for c in body if c]
        else:
            commands = [head]
        for command in commands:
            if not re.fullmatch(r"scripts/[\w./-]+\.sh(\s+--self-test)?", command):
                errors.append(f"{where}'s one-leg step {name!r} runs {command!r}: only scripts that don't read {LEG_ENV} may skip a leg (S4)")
                continue
            todo = [command.split()[0]]
            while todo:
                script = todo.pop()
                if script in seen:
                    continue
                seen.add(script)
                text = read_script(script)
                if text is None:
                    errors.append(f"{where}'s one-leg step {name!r}: {script} doesn't exist (S4)")
                    continue
                hit = FLAG_NAMES.search(text)
                if hit:
                    errors.append(f"{script}:{line_of(text, hit.start())}: names {hit.group(0)}, so its step can't run in one leg only (S4)")
                todo += SCRIPT_REF.findall(text)
    return errors, one_leg


def read_repo_script(path):
    p = pathlib.Path(path)
    return p.read_text(encoding="utf-8") if p.is_file() else None


def package_from(args):
    if "--package-json" in args:
        return json.loads(pathlib.Path(args[args.index("--package-json") + 1]).read_text(encoding="utf-8"))
    return json.loads(subprocess.run(["swift", "package", "dump-package"], check=True, stdout=subprocess.PIPE, text=True).stdout)


PINNED = """func config() -> TransportEnvConfig {
    var config = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)
    config.useSyncTables = true
    config.typedLeafValues = true
    return config
}
"""
ADAPTER_OK = """let adapter = TransportAdapter<S>(
    keeper: keeper,
    transport: transport,
    landID: "x",
    transportEnvConfig: config()
)
"""


def self_test():
    deps = lambda *names: [{"byName": [n, None]} for n in names]
    package = lambda *extra: {"targets": [
        {"name": "SwiftStateTree", "type": "regular", "dependencies": []},
        {"name": TRANSPORT, "type": "regular", "dependencies": deps("SwiftStateTree")},
        {"name": "SwiftStateTreeNIO", "type": "regular", "dependencies": deps(TRANSPORT)},
        {"name": "SwiftStateTreeTests", "type": "test", "dependencies": deps(TRANSPORT)},
        {"name": "SwiftStateTreeTransportTests", "type": "test", "dependencies": deps(TRANSPORT)},
        {"name": "SwiftStateTreeNIOTests", "type": "test", "dependencies": deps("SwiftStateTreeNIO")},
        {"name": "SwiftStateTreeMacrosTests", "type": "test", "dependencies": deps("SwiftStateTree")},
        *extra,
    ]}
    job = lambda regex: (
        "jobs:\n  build:\n    steps:\n    - run: swift test\n"
        f"  {JOB}:\n    steps:\n    - name: Run\n      env:\n"
        f"        FILTER: ${{{{ !inputs.full_matrix && '{regex}' || '' }}}}\n"
        "      run: |\n        set -o pipefail\n        swift test ${FILTER:+--filter \"$FILTER\"} 2>&1 | tee out.log\n"
        "  per-player:\n    steps:\n    - run: swift test --filter 'X\\.'\n"
    )
    both = job(r"SwiftStateTreeTransportTests\.|SwiftStateTreeNIOTests\.")
    filtered, filter_errors = filtered_targets(both)
    sources = [
        ("an adapter without transportEnvConfig:", "let a = TransportAdapter<S>(keeper: k, transport: t, landID: \"x\")\n", "R1"),
        ("an adapter with it, spread over lines, the argument last", PINNED + ADAPTER_OK, None),
        ("a config that pins only the tables",
         PINNED.replace("    config.typedLeafValues = true\n", ""), "R2 a TransportEnvConfig whose block doesn't set typedLeafValues"),
        ("a config pinned through the Diagnostics names",
         PINNED.replace(".useSyncTables =", ".syncTablesEnabled =").replace(".typedLeafValues =", ".typedLeafValuesEnabled ="), None),
        ("a config from fromEnvironment", "let c = TransportEnvConfig.fromEnvironment(enableDirtyTrackingDefault: true)\n", "R2 TransportEnvConfig.fromEnvironment"),
        ("a config built with .init and a type annotation",
         "func f() { let c: TransportEnvConfig = .init(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil) }\n",
         "R2 a TransportEnvConfig"),
        ("TransportAdapter( only in a comment and a string",
         "// TransportAdapter<S>(keeper: k)\nlet s = \"TransportAdapter(x) TransportEnvConfig(\"\n/* LandManager<S>( */\n", None),
        ("a type annotation and a metatype are not constructions",
         "var a: TransportAdapter<S>? = nil\nlet t = TransportAdapter<S>.self\n", None),
        ("a LandManager in a scanned target", "let m = LandManager<S>(landFactory: f)\n", "R3 LandManager"),
        ("a comparison is not a pin",
         PINNED.replace("    config.typedLeafValues = true\n", "    if config.typedLeafValues == true {}\n"), "R2 a TransportEnvConfig whose block doesn't set typedLeafValues"),
        # A nil config falls back to the environment (TransportAdapter's `transportEnvConfig ?? fromEnvironment`).
        ("transportEnvConfig: nil", ADAPTER_OK.replace("transportEnvConfig: config()", "transportEnvConfig: nil"), "R1 transportEnvConfig: nil may be nil"),
        ("a forwarded optional parameter",
         "func run(env: TransportEnvConfig? = nil) {\n" + ADAPTER_OK.replace("config()", "env") + "}\n", "R1 transportEnvConfig: env may be nil"),
        ("a forwarded non-optional parameter",
         "func run(env: TransportEnvConfig) {\n" + ADAPTER_OK.replace("config()", "env") + "}\n", None),
        ("a typealias for the adapter", "typealias A = TransportAdapter<S>\nlet a = A(keeper: k, transport: t, landID: \"x\")\n", "typealias for TransportAdapter"),
        ("a typealias for the config", "typealias E = TransportEnvConfig\n", "typealias for TransportEnvConfig"),
        ("an adapter built with .init and a type annotation",
         "let a: TransportAdapter<S> = .init(keeper: k, transport: t, landID: \"x\")\n", "R1 a TransportAdapter built without"),
        ("the same with transportEnvConfig:",
         PINNED + "let a: TransportAdapter<S> = .init(keeper: k, transport: t, landID: \"x\", transportEnvConfig: config())\n", None),
        ("a config in a global",
         "let shared = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)\n"
         "func f() { var c = shared; c.useSyncTables = true; c.typedLeafValues = true }\n", "R2 a TransportEnvConfig built outside a function body"),
        ("a config in a static let",
         "struct T {\n    static let c = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)\n"
         "    func f() { var c = Self.c; c.useSyncTables = true; c.typedLeafValues = true }\n}\n", "R2 a TransportEnvConfig built outside a function body"),
        ("a config as a stored property's default",
         "final class T {\n    var c = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)\n}\n",
         "R2 a TransportEnvConfig built outside a function body"),
        ("a transportEnvConfig: label in a nested call is not the adapter's",
         PINNED + "let a = TransportAdapter<S>(keeper: k, transport: make(transportEnvConfig: config()), landID: \"x\")\n",
         "R1 a TransportAdapter built without"),
        ("a config in a computed property that pins both",
         "struct T {\n    var c: TransportEnvConfig {\n        var c = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)\n"
         "        c.useSyncTables = false\n        c.typedLeafValues = false\n        return c\n    }\n}\n", None),
    ]
    failed = 0
    # The filter is the job's own FILTER line.
    for name, workflow, want_names, want_error in [
        ("the job's filter names Transport and NIO", both, {"SwiftStateTreeTransportTests", "SwiftStateTreeNIOTests"}, None),
        ("a filter without NIO names only Transport", job(r"SwiftStateTreeTransportTests\."), {"SwiftStateTreeTransportTests"}, None),
        ("no FILTER line in the job fails", both.replace("FILTER:", "FILTERS:"), set(), "FILTER lines"),
        ("a FILTER line in another job only fails", both.replace(f"  {JOB}:", "  other:"), set(), f"no {JOB} job"),
        ("an alternative that isn't a whole target fails", job(r"SwiftStateTreeTransportTests\.|NIO"), None, "isn't a whole target"),
        ("a swift test that ignores FILTER fails", both.replace(' ${FILTER:+--filter "$FILTER"}', ""), None, "ignores FILTER"),
        ("a second swift test in the job fails", both.replace("2>&1 | tee out.log\n", "2>&1 | tee out.log\n        swift test\n"), None, "2 swift test line(s)"),
        ("a swift test only in a comment doesn't count", both.replace("      run: |\n", "      # swift test\n      run: |\n"), {"SwiftStateTreeTransportTests", "SwiftStateTreeNIOTests"}, None),
    ]:
        names, errors = filtered_targets(workflow)
        ok = (not errors and names == want_names) if want_error is None else any(want_error in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {names} {errors}"))
        failed += not ok
    for name, source, want in sources:
        errors = check_source("t.swift", source)
        ok = (not errors) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    bad = "let a = TransportAdapter<S>(keeper: k, transport: t, landID: \"x\")\n"
    graphs = [
        ("the core tests are scanned", package(), "SwiftStateTreeTests", "R1"),
        ("the filtered Transport tests are not", package(), "SwiftStateTreeTransportTests", None),
        ("a target that can't reach Transport is not", package(), "SwiftStateTreeMacrosTests", None),
        ("a new test target reaching Transport through NIO is",
         package({"name": "NewTests", "type": "test", "dependencies": deps("SwiftStateTreeNIO")}), "NewTests", "R1"),
        ("a new test target depending on Transport by target name is",
         package({"name": "NewTests", "type": "test", "dependencies": [{"target": [TRANSPORT, None]}]}), "NewTests", "R1"),
        ("a test-support library under Tests/ that a core test depends on is",
         {"targets": [*package()["targets"][:3],
                      {"name": "TestSupport", "type": "regular", "path": "Tests/TestSupport", "dependencies": deps(TRANSPORT)},
                      {"name": "SwiftStateTreeTests", "type": "test", "dependencies": deps("TestSupport")}]},
         "TestSupport", "R1"),
        ("the NIO tests are not scanned while the filter names them", package(), "SwiftStateTreeNIOTests", None),
        ("a library under Sources/ is not (its adapters are Sources' own)",
         {"targets": [*package()["targets"][:3],
                      {"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": deps(TRANSPORT)},
                      {"name": "SwiftStateTreeTests", "type": "test", "dependencies": deps("Lib")}]},
         "Lib", None),
    ]
    # A dump this check can't read fails it (fail closed), whatever the sources hold.
    for name, pkg, want in [
        ("a dump with no test targets", {"targets": package()["targets"][:3]}, "no test targets"),
        ("a test target with no dependencies field",
         package({"name": "NewTests", "type": "test"}), "no dependencies field"),
        ("a dependency of an unknown kind",
         package({"name": "NewTests", "type": "test", "dependencies": [{"macro": ["X", None]}]}), "of a kind this check doesn't know"),
    ]:
        with tempfile.TemporaryDirectory() as tmp:
            errors, _ = check(pathlib.Path(tmp), pkg, filtered)
        ok = any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    for name, pkg, target, want in graphs:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            where = {t["name"]: t.get("path") or f"Tests/{t['name']}" for t in pkg["targets"]}
            for p in where.values():
                (root / p).mkdir(parents=True, exist_ok=True)
            (root / where[target] / "A.swift").write_text(bad, encoding="utf-8")
            errors, _ = check(root, pkg, filtered)
        ok = (not errors) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    # End to end: NIO dropped from the job's filter, its tests are scanned, and one that reads the
    # flags fails the check (the job would run them with the flags on no more).
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "Tests" / "SwiftStateTreeNIOTests").mkdir(parents=True)
        (root / "Tests" / "SwiftStateTreeTests").mkdir(parents=True)
        (root / "Tests" / "SwiftStateTreeNIOTests" / "A.swift").write_text(bad, encoding="utf-8")
        errors, _ = check(root, package(), filtered_targets(job(r"SwiftStateTreeTransportTests\."))[0])
    ok = any("SwiftStateTreeNIOTests/A.swift" in e and "R1" in e for e in errors)
    print(f"{'ok  ' if ok else 'FAIL'} self-test: NIO dropped from the filter, a NIO test reading the flags fails" + ("" if ok else f": {errors}"))
    failed += not ok
    if filter_errors:
        print(f"FAIL self-test: the sample job's filter doesn't parse: {filter_errors}")
        failed += 1
    failed += leg_self_test()
    return failed


def leg_self_test():
    """Section 2's cells: the build job's matrix (S6) and its one-leg steps' scripts (S4)."""
    def build(matrix="        in_turn_sync: [\"true\", \"false\"]\n", env="      IN_TURN_SYNC: ${{ matrix.in_turn_sync }}\n",
              lint_if="      " + ONE_LEG_IF + "\n", lint_run="      run: |\n        scripts/lint.sh --self-test\n        scripts/lint.sh\n",
              extra=""):
        return ("jobs:\n  build:\n    name: build (in-turn sync ${{ matrix.in_turn_sync }})\n    strategy:\n      matrix:\n"
                "        # a comment\n" + matrix + "    env:\n" + env + "\n    steps:\n    - uses: actions/checkout@v4\n"
                "    - name: Lint\n" + lint_if + lint_run + "\n    - name: Snippets\n" + lint_if + "      run: scripts/snippets.sh\n"
                "      timeout-minutes: 5\n" + extra + "    - name: Run tests\n      run: swift test\n  other:\n    steps:\n    - run: x\n")
    scripts = {"scripts/lint.sh": "echo lint\n", "scripts/snippets.sh": "swift build --target \"$t\"\nscripts/helper.py\n",
               "scripts/helper.py": "print(1)\n"}
    cells = [
        ("today's shape: two one-leg steps, scripts only", build(), scripts, None),
        ("a second matrix axis fails", build(matrix="        in_turn_sync: [\"true\", \"false\"]\n        rows: [on, off]\n"), scripts, "not only in_turn_sync"),
        ("a renamed axis fails", build(matrix="        sync: [\"true\", \"false\"]\n", env="      IN_TURN_SYNC: ${{ matrix.sync }}\n"), scripts, "not only in_turn_sync"),
        ("the axis as another env var fails", build(env="      IN_TURN_SYNC: ${{ matrix.in_turn_sync }}\n      ROWS: ${{ matrix.in_turn_sync }}\n"), scripts, "outside IN_TURN_SYNC"),
        ("the axis in a compiler flag fails",
         build(extra="    - name: Build\n      run: swift build -Xswiftc -DSYNC_${{ matrix.in_turn_sync }}\n"), scripts, "outside IN_TURN_SYNC"),
        ("a one-leg if of another form fails", build(lint_if="      if: matrix.in_turn_sync == 'true'\n"), scripts, "outside IN_TURN_SYNC"),
        ("the axis in the bracket form fails", build(lint_if="      if: ${{ matrix['in_turn_sync'] == 'true' || inputs.full_matrix }}\n"), scripts, "outside IN_TURN_SYNC"),
        ("the env var in an if: fails", build(lint_if="      if: ${{ env.IN_TURN_SYNC == 'true' || inputs.full_matrix }}\n"), scripts, "IN_TURN_SYNC outside its env line"),
        ("the env var in a run line fails",
         build(extra="    - name: Echo\n      run: echo \"$IN_TURN_SYNC\"\n"), scripts, "IN_TURN_SYNC outside its env line"),
        ("the env var under another name fails",
         build(env="      IN_TURN_SYNC: ${{ matrix.in_turn_sync }}\n      SYNC: ${{ env.IN_TURN_SYNC }}\n"), scripts, "IN_TURN_SYNC outside its env line"),
        ("a one-leg step running swift test fails",
         build(lint_run="      run: swift test --filter X\n"), scripts, "only scripts that don't read"),
        ("a one-leg script naming IN_TURN_SYNC fails", build(), {**scripts, "scripts/lint.sh": "[ \"$IN_TURN_SYNC\" = true ]\n"}, "names IN_TURN_SYNC"),
        ("a one-leg script naming InTurnSync fails", build(), {**scripts, "scripts/lint.sh": "grep InTurnSync x\n"}, "names InTurnSync"),
        ("a script it calls naming the key fails", build(), {**scripts, "scripts/helper.py": "k = 'inTurnSync'\n"}, "helper.py:1: names inTurnSync"),
        ("a one-leg script that doesn't exist fails", build(), {k: v for k, v in scripts.items() if k != "scripts/lint.sh"}, "doesn't exist"),
        ("a step with no if runs in both legs, whatever it runs", build(extra="    - name: Free\n      run: scripts/free.sh\n"),
         {**scripts, "scripts/free.sh": "echo $IN_TURN_SYNC\n"}, None),
        ("the axis only in a comment doesn't count", build(extra="    # ${{ matrix.rows }}\n"), scripts, None),
    ]
    failed = 0
    for name, workflow, files, want in cells:
        errors, one_leg = leg_errors(workflow, files.get)
        ok = (not errors and one_leg == ["Lint", "Snippets"]) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {one_leg} {errors}"))
        failed += not ok
    return failed


args = sys.argv[1:]
if args[:1] == ["--self-test"]:
    sys.exit(1 if self_test() else 0)
workflow = pathlib.Path(WORKFLOW).read_text(encoding="utf-8")
filtered, errors = filtered_targets(workflow)
files = 0
if not errors:
    package = package_from(args)
    errors, files = check(pathlib.Path("."), package, filtered)
leg, one_leg = leg_errors(workflow, read_repo_script)
for e in errors + leg:
    print(f"::error::{e}")
if not errors:
    names = ", ".join(n for n, _ in scanned_targets(package, filtered)) or "none"
    print(f"variant test selection: {JOB} runs {', '.join(sorted(filtered))} on a push; {files} files in the other targets that reach {TRANSPORT} ({names}) pin both flags")
if not leg:
    print(f"variant test selection: the {BUILD_JOB} job's legs differ only in {LEG_ENV}; {len(one_leg)} steps run in one leg ({', '.join(one_leg) or 'none'}), and their scripts don't read it")
sys.exit(1 if errors or leg else 0)
PY
