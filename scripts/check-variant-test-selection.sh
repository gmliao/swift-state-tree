#!/usr/bin/env bash
# The build job's variants run on one build, and its sync-tables-off variant leaves tests out on a
# push. Both are safe only while what they assume holds; this check fails when it doesn't. The
# nightly runs everything (full_matrix), as the backstop. Two sections:
#
# 1. The sync-tables-off variant's test selection, safe in the sense of Rothermel and Harrold
# (TOSEM 1997): a test is left out only if it can't reach the variables the variant varies. The
# build job's `Tests, sync tables off` step runs only the Transport and NIO tests, with
# USE_SYNC_TABLES=false and TYPED_LEAF_VALUES=false. That is safe only while no other test can read
# those two flags, so this check fails if one could.
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
# The filtered targets are read from the step itself: its one FILTER env entry (a second key
# would override the first; FILTER set anywhere else in the workflow, a script's `FILTER=`
# included, fails), whose alternatives
# must each be a whole target (`Name\.`), and its one `swift test`, which must pass
# `${FILTER:+--filter "$FILTER"}`; the step sets both flags to "false". So the step and this check
# can't name different targets, and the step can't run without the filter it declares.
#
# What it can't see (the nightly runs the whole suite in that step, as the backstop): R1 reads the
# argument labels, not their types, so a non-optional expression that is nil at run time isn't
# caught; R2 is textual, so it doesn't check that the pins set the same variable as the
# construction, and it counts a pin under an inactive `#if` or in a closure that never runs. The
# lexer is simple: a string interpolation holding a nested string literal can end a literal early,
# and a comma in a generic argument (`make<A, B>(…)`) ends the extracted expression there. A dump of
# the package this check can't read fails it rather than scanning nothing.
#
# 2. One build for every variant. The variants (USE_SYNC_TABLES, TYPED_LEAF_VALUES,
# PER_PLAYER_SYNC_TABLES) are test steps of the build job that run `swift test --skip-build` on the
# products of its one `swift build --build-tests`. That is valid only while nothing reads the
# variables when the package is built, and the steps every variant shares read none:
#   E1 each variable appears only in a test step (a build-job step that runs `swift test`): as an
#      env entry with a literal true or false, or as plain text in its script (a pin test's name),
#      never as a shell expansion (`$VAR`, `${VAR}`). Never in an expression (`${{ … }}`, `if:`,
#      `env.VAR` or `env['VAR']` included), the workflow's or a job's env, another step or another
#      job. Outside the test steps, whole lines count, so the name in display text fails too (a
#      false alarm, fixed by rewording). A `#` line is skipped, except inside a block scalar
#      (`run: |`), where it is script text that Actions still interpolates. A test step's script
#      doesn't assign one (`VAR=x swift test`, `export VAR=x`), and no step of the job writes
#      `$GITHUB_ENV`, which sets variables for the steps after it under names built at run time.
#      A test step is one whose own `run:` runs `swift test` (a `uses:` step's `with:` isn't
#      script). A plain `if:` value that goes on over more lines is read as one expression.
#      The workflow writes its keys plain and brings in no entries by an anchor, an alias or a
#      merge key (`&a`, `*a`, `<<:`): the rules read each step's own lines, so those fail.
#   E2 the build job has no `strategy` (a matrix would bring back the variant runs this reasons
#      about), and no expression in it uses the matrix or strategy context.
#   E3 Package.swift reads no environment (`ProcessInfo`, `getenv`, `Context.environment`,
#      `environment[`), comments and strings stripped.
#   E4 one build: one step runs `swift build`, as exactly `swift build --build-tests` with
#      `id: build`; every `swift test` in the job passes `--skip-build` and no flag but `--filter`
#      and `--no-parallel` (another flag may need a build of its own), its arguments read as shell
#      words, so `--skip-build` as `--filter`'s value doesn't count, and each line cut at its list
#      operators outside quotes, so every `swift test` on it is read; every test step's `if:` is
#      `${{ !cancelled() && steps.build.outcome == 'success' }}`, so no variant runs on missing or
#      partial products; the four variant steps (VARIANT_STEPS) are each one test step, so
#      dropping or renaming a variant fails; and each variant step sets its own flags to false
#      (VARIANT_FLAGS_OFF), so a variant can't keep its name and run the defaults.
#   E5 the shared steps' scripts (`scripts/*.sh` or `.py`, and every script they name, followed)
#      don't name a variable or its key (useSyncTables, typedLeafValues, perPlayerSyncTables). Textual: a script that builds a name from parts isn't seen.
#
# The rules read text, not commands, and catch the plain ways a change can break the reasoning
# above. An edit that hides what it does on purpose passes them, for example `: swift test ...`
# (runs no tests), `printf -v FILTER ...` or `FILTER+=...` in a test step, or a flow mapping
# (`env: {...}`). Review catches those.
#
# Usage: scripts/check-variant-test-selection.sh [--self-test] [--package-json <file>]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

WORKFLOW = ".github/workflows/build-and-test.yml"
BUILD_JOB = "build"
TABLES_STEP = "Tests, sync tables off"
TRANSPORT = "SwiftStateTreeTransport"
# The step's filter on a push: `FILTER: ${{ !inputs.full_matrix && '<regex>' || '' }}`, and the
# one `swift test` that must use it.
FILTERED_RUN = '${FILTER:+--filter "$FILTER"}'
FILTER_LINE = re.compile(r"""^\s*FILTER:\s*\$\{\{\s*!inputs\.full_matrix\s*&&\s*'([^']*)'\s*\|\|\s*''\s*\}\}\s*$""")

ADAPTER = re.compile(r"\bTransportAdapter(?:BenchmarkHandle)?\s*(?:<)?")
# `let a: TransportAdapter<S> = .init(…)`: the `.init(` is the construction.
ADAPTER_INIT = re.compile(r":\s*TransportAdapter(?:BenchmarkHandle)?\s*<[^=]*>\s*=\s*\.init\s*(?=\()")
CONFIG = re.compile(r"\bTransportEnvConfig\s*(?:\.init\s*)?\(|:\s*TransportEnvConfig\s*=\s*\.init\s*\(")
# Another name for either type would hide its constructions from R1 and R2.
ALIAS = re.compile(r"\btypealias\s+\w+\s*(?:<[^=]*>)?\s*=\s*(TransportAdapter(?:BenchmarkHandle)?|TransportEnvConfig)\b")
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
    """The test targets the sync-tables-off step runs on a push, from its FILTER line, and any
    error reading it."""
    lines = job_lines(workflow, BUILD_JOB)
    if lines is None:
        return set(), [f"{WORKFLOW}: no {BUILD_JOB} job"]
    where = f"{WORKFLOW}: the {BUILD_JOB} job's {TABLES_STEP!r} step"
    steps = [s for s in job_steps(lines) if step_name(s) == TABLES_STEP]
    if len(steps) != 1:
        return set(), [f"{WORKFLOW}: the {BUILD_JOB} job has {len(steps)} steps named {TABLES_STEP!r}, not one"]
    step = yaml_code(steps[0])
    # The step's env as YAML reads it: FILTER once (a second key would override the first), of the
    # form this check reads. Anywhere else (the workflow's or the job's env, another step, a shell
    # assignment in a script), it could differ from what the step runs.
    filters = [value for key, value in step_env_entries(steps[0]) if key == "FILTER"]
    keys = sum(1 for _, line in yaml_structure(workflow.splitlines()) if re.match(r"^\s*(?:-\s+)?FILTER\s*:", line))
    assigned = sum(1 for s in job_steps(lines) for line in run_lines(s) if re.search(r"(?<![\w-])FILTER=", line))
    elsewhere = keys - len(filters) + assigned
    found = [m for m in (FILTER_LINE.match(f"        FILTER: {value}") for value in filters) if m]
    if len(filters) != 1 or len(found) != 1 or elsewhere:
        return set(), [f"{where} has {len(filters)} FILTER entries in its env ({len(found)} of the form this check reads), not one"
                       + (f", and the workflow sets FILTER {elsewhere} more time(s)" if elsewhere else "")]
    env = step_env(steps[0])
    unset = [v for v in ("USE_SYNC_TABLES", "TYPED_LEAF_VALUES") if env.get(v) not in ('"false"', "'false'", "false")]
    if unset:
        return set(), [f"{where} doesn't set {' and '.join(unset)} to false in its env"]
    runs = [line for line in step if re.search(r"\bswift test\b", line)]
    if len(runs) != 1 or FILTERED_RUN not in runs[0]:
        return set(), [f"{where} must run one `swift test --skip-build {FILTERED_RUN}`; it has {len(runs)} swift test line(s)"
                       + ("" if len(runs) != 1 else " and that one ignores FILTER")]
    names, errors = set(), []
    for alternative in found[0].group(1).split("|"):
        m = re.fullmatch(r"(\w+)\\\.", alternative)
        if m:
            names.add(m.group(1))
        else:
            errors.append(f"{where}'s filter alternative {alternative!r} isn't a whole target (Name\\.)")
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


# Section 2: one build for every variant.
VARIABLES = ("USE_SYNC_TABLES", "TYPED_LEAF_VALUES", "PER_PLAYER_SYNC_TABLES")
# No left boundary: `-DUSE_SYNC_TABLES` names it too.
VARIABLE_USE = re.compile(r"(" + "|".join(VARIABLES) + r")\b")
EXPANSION = re.compile(r"\$\{?(" + "|".join(VARIABLES) + r")\b")
ENV_ENTRY = re.compile(r"^        (" + "|".join(VARIABLES) + r"):\s*(\"(?:true|false)\"|'(?:true|false)'|true|false)\s*$")
# What the shared steps' scripts must not name: a variable, its key constant or its reader.
FLAG_NAMES = re.compile(r"\b(?:" + "|".join(VARIABLES) + r"|useSyncTables|typedLeafValues|perPlayerSyncTables)\b")
SCRIPT_REF = re.compile(r"(?<![\w/.-])(scripts/[\w./-]+\.(?:sh|py))\b")
# The matrix context in any form (`matrix.x`, `matrix['x']`, `toJSON(matrix)`), not the YAML key.
MATRIX_USE = re.compile(r"\bmatrix\b(?!\s*:)")
# The strategy context (`strategy.job-index`, `toJSON(strategy)`), not the YAML key.
STRATEGY_USE = re.compile(r"\bstrategy\b(?!\s*:)")
PACKAGE_ENV = re.compile(r"\bProcessInfo\b|\bgetenv\b|\bContext\s*\.\s*environment\b|\benvironment\s*\[")
BUILD_RUN = "      run: swift build --build-tests"
TEST_IF = "      if: ${{ !cancelled() && steps.build.outcome == 'success' }}"
# The `swift test` options that run the products as built (`--filter` takes a value).
TEST_OPTIONS = ("--skip-build", "--no-parallel", "--filter")
# The variant steps (E4): each runs once, as a test step, so dropping or renaming one fails.
VARIANT_STEPS = ("Tests", "Tests, sync tables off", "Tests, per-player sync tables off", "Run wall-clock tests")
# The flags each variant step turns off (E4). Section 1 also checks the tables step's two.
VARIANT_FLAGS_OFF = {
    "Tests, sync tables off": ("USE_SYNC_TABLES", "TYPED_LEAF_VALUES"),
    "Tests, per-player sync tables off": ("PER_PLAYER_SYNC_TABLES",),
}
# A shell assignment of a variable (`VAR=x swift test`, `export VAR=x`, `echo "VAR=x"` into a
# file): it sets the variable where the step's env doesn't show it (E1).
ASSIGNMENT = re.compile(r"(?<![\w-])(" + "|".join(VARIABLES) + r")=")
# `$GITHUB_ENV` sets variables for every later step, under names a script may build at run time.
GITHUB_ENV = re.compile(r"\bGITHUB_ENV\b")
# A key written in quotes (`"if": …`, `'run': |`): the rules read plain keys only.
QUOTED_KEY = re.compile(r"""^\s*(?:-\s+)?("[^"]*"|'[^']*')\s*:(?:\s|$)""")
# An anchor (`&a`), an alias (`*a`) or a merge key (`<<:`): entries brought in from elsewhere,
# which a step's own lines don't show.
ANCHOR = re.compile(r"^\s*(?:-\s+)?(?:[\w-]+\s*:\s+)?[&*][\w-]+(?:\s|$)|^\s*(?:-\s+)?<<\s*:")
# A step's own `run:` key (`    - run:` or `      run:`), not one nested under `with:`.
RUN_KEY = re.compile(r"^(    - |      )run:\s*(.*?)\s*$")


def job_lines(workflow, job):
    """The job's lines (its header included), or None."""
    lines = workflow.splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(r"^  " + re.escape(job) + r":\s*$", line)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[i])), len(lines))
    return lines[start:end]


def job_steps(lines, indexed=False):
    """The job's steps, each a list of its lines (a step starts at `    - `), or of (index, line)."""
    steps, current = [], None
    for i, line in enumerate(lines):
        if re.match(r"^    - ", line):
            current = [(i, line)]
            steps.append(current)
        elif current is not None and (line.startswith("      ") or not line.strip()):
            current.append((i, line))
        elif not line.lstrip().startswith("#"):
            current = None
    return steps if indexed else [[line for _, line in step] for step in steps]


def step_name(step):
    return next((re.sub(r"^\s*-?\s*name:\s*", "", line).strip() for line in step if re.match(r"^\s*-?\s*name:", line)), "?")


def step_env_entries(step):
    """The step's own env entries in order, [(key, raw value)], a repeated key listed each time
    (YAML keeps the last)."""
    entries, inside = [], False
    for line in yaml_code(step):
        if re.match(r"^      env:\s*$", line):
            inside = True
        elif inside and (not line.strip() or line.startswith("        ")):
            m = re.match(r"^        ([\w-]+):\s*(.*?)\s*$", line)
            if m:
                entries.append((m.group(1), m.group(2)))
        else:
            inside = False
    return entries


def step_env(step):
    """The step's own env entries, {key: raw value}, as YAML reads them (the last of a repeated key)."""
    return dict(step_env_entries(step))


def run_lines(step):
    """The step's `run:` script: its inline value, or its block scalar's lines; [] without one."""
    code = yaml_code(step)
    for i, line in enumerate(code):
        m = RUN_KEY.match(line)
        if not m:
            continue
        if not re.fullmatch(r"[|>][-+0-9]*(?:\s+#.*)?", m.group(2)):
            return [m.group(2)]
        indent = len(m.group(1))
        rest = []
        for j in range(i + 1, len(code)):
            if code[j].strip() and len(code[j]) - len(code[j].lstrip()) <= indent:
                break
            rest.append(code[j])
        return rest
    return []


BLOCK_SCALAR = re.compile(r"^(\s*)(-\s+)?[\w-]+:\s*[|>][-+0-9]*\s*(?:#.*)?$")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
IF_KEY = re.compile(r"^\s*(?:-\s+)?if:\s*(.*?)\s*$")


def yaml_code(lines, indexed=False):
    """`lines` without YAML comment lines, or their (index, line). A line inside a block scalar
    (`run: |`) is content, kept whatever it starts with, since Actions interpolates its
    expressions."""
    out, block = [], None  # block: the indent the block's content must exceed
    for i, line in enumerate(lines):
        indent = len(line) - len(line.lstrip())
        if block is not None:
            if not line.strip() or indent > block:
                out.append((i, line))
                continue
            block = None
        if line.lstrip().startswith("#"):
            continue
        m = BLOCK_SCALAR.match(line)
        if m:
            block = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
        out.append((i, line))
    return out if indexed else [line for _, line in out]


def yaml_structure(lines):
    """(index, line) of `lines` that are YAML structure: not a comment and not a block scalar's
    content (shell text, where `*` and `&` are the shell's)."""
    out, block = [], None
    for i, line in enumerate(lines):
        indent = len(line) - len(line.lstrip())
        if block is not None:
            if not line.strip() or indent > block:
                continue
            block = None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = BLOCK_SCALAR.match(line)
        if m:
            block = len(m.group(1)) + (len(m.group(2)) if m.group(2) else 0)
        out.append((i, line))
    return out


def expressions(code):
    """(index in `code`, expression) for each `${{ … }}` and each bare `if:` value."""
    text = "\n".join(code)
    found = [(text.count("\n", 0, m.start()), m.group(1)) for m in EXPRESSION.finditer(text)]
    for i, line in enumerate(code):
        m = IF_KEY.match(line)
        if not m or "${{" in m.group(1):
            continue
        value = m.group(1)
        if re.fullmatch(r"[|>][-+0-9]*", value):
            # A folded `if:`: its value is the block's content.
            indent = len(line) - len(line.lstrip())
            rest = []
            for j in range(i + 1, len(code)):
                if code[j].strip() and len(code[j]) - len(code[j].lstrip()) <= indent:
                    break
                rest.append((j, code[j]))
            if rest and "${{" not in " ".join(r for _, r in rest):
                found.append((rest[0][0], " ".join(r.strip() for _, r in rest)))
        elif value:
            # A plain value may go on over more-indented lines (`if: !cancelled() &&` and then
            # `  env.X == 'y'`): one value, so the whole of it is the expression.
            indent = len(line) - len(line.lstrip())
            for j in range(i + 1, len(code)):
                if not code[j].strip() or len(code[j]) - len(code[j].lstrip()) <= indent:
                    break
                value += " " + code[j].strip()
            found.append((i, value))
    return sorted(found)


SHELL_LIST_OPERATORS = {"|", "|&", "||", "&&", ";", "&"}


def swift_test_invocations(line):
    """Each `swift test` on a script line, as its argument words: the line read as shell words,
    cut at its list operators (`|`, `||`, `&&`, `;`, `&`), so a second invocation after one is
    read too and an operator inside quotes isn't a cut. Redirections (`2>&1`, `> f`) are dropped.
    Returns (invocations, error)."""
    text = line.rstrip()
    if text.endswith("\\"):
        # A line continued on the next: its options go on there, out of this check's view.
        text = text[:-1]
    lexer = shlex.shlex(text.replace(FILTERED_RUN, "--filter FILTER"), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError as error:
        return [], f"has a swift test line this check can't split ({error}): {line.strip()!r}"
    commands, current = [], []
    for token in tokens:
        if token in SHELL_LIST_OPERATORS:
            commands.append(current)
            current = []
        else:
            current.append(token)
    commands.append(current)
    found = []
    for words in commands:
        starts = [k for k in range(len(words) - 1) if words[k] == "swift" and words[k + 1] == "test"]
        if not starts:
            continue
        args, rest = [], words[starts[0] + 2:]
        k = 0
        while k < len(rest):
            if rest[k][:1] in "<>":
                # A redirection and its target; a file descriptor before it was its own word.
                if args and args[-1].isdigit():
                    args.pop()
                k += 2
                continue
            args.append(rest[k])
            k += 1
        found.append(args)
    return found, None


def test_option_errors(words):
    """What's wrong with one `swift test` invocation's argument words: `--skip-build` must be an
    option, not a `--filter` value."""
    problems, options, i = [], [], 0
    while i < len(words):
        word = words[i]
        if word == "--filter":
            i += 2
            options.append(word)
            continue
        if word.startswith("--filter="):
            options.append("--filter")
        elif word in TEST_OPTIONS:
            options.append(word)
        else:
            problems.append(f"passes {word}: only --skip-build, --filter and --no-parallel run the products as built")
        i += 1
    if "--skip-build" not in options:
        problems.insert(0, "runs swift test without --skip-build: it builds again")
    return problems


def variant_errors(workflow, package_swift, read_script):
    """Section 2 (E1–E5). Returns the errors and the test steps' names."""
    lines = workflow.splitlines()
    job = job_lines(workflow, BUILD_JOB)
    if job is None:
        return [f"{WORKFLOW}: no {BUILD_JOB} job"], []
    offset = next(i for i, line in enumerate(lines) if re.match(r"^  " + re.escape(BUILD_JOB) + r":\s*$", line))
    errors, where = [], f"{WORKFLOW}: the {BUILD_JOB} job"
    steps = job_steps(job, indexed=True)
    # A test step runs `swift test` in its own script: a `uses:` step whose `with:` names it isn't one.
    is_test = lambda step: any(re.search(r"\bswift test\b", line) for line in run_lines([l for _, l in step]))
    tests = [s for s in steps if is_test(s)]
    # E1: where a variable may appear. A test step's env entries and its script's plain text.
    allowed_entry, allowed_text = set(), set()
    for step in tests:
        inside = False
        for i, line in yaml_code([l for _, l in step], indexed=True):
            n = step[i][0] + offset
            if re.match(r"^      env:\s*$", line):
                inside = True
                continue
            if inside and (not line.strip() or line.startswith("        ")):
                allowed_entry.add(n)
                continue
            inside = False
            if not re.match(r"^\s*-?\s*(?:if|name):", line):
                allowed_text.add(n)
    code = yaml_code(lines, indexed=True)
    for n, line in code:
        hit = VARIABLE_USE.search(line)
        if not hit:
            continue
        var = hit.group(1)
        if n in allowed_entry:
            if not ENV_ENTRY.match(line):
                errors.append(f"{WORKFLOW}:{n + 1}: E1 {var} in a test step's env with a value that isn't a literal true or false: {line.strip()!r}")
        elif n in allowed_text:
            if EXPANSION.search(line):
                errors.append(f"{WORKFLOW}:{n + 1}: E1 a shell expansion of {var} in a test step's script: {line.strip()!r}; set it in the step's env")
        else:
            errors.append(f"{WORKFLOW}:{n + 1}: E1 {var} outside a test step's env: {line.strip()!r}; read at build time or by a shared step, it would let one build serve variants that differ")
    for k, expression in expressions([l for _, l in code]):
        n, line = code[k]
        # A line outside the test steps already failed above, unless the variable is on a plain
        # value's continuation line (a test step's script text, by position).
        if VARIABLE_USE.search(expression) and (n in allowed_entry | allowed_text or not VARIABLE_USE.search(line)):
            errors.append(f"{WORKFLOW}:{n + 1}: E1 {VARIABLE_USE.search(expression).group(1)} in an expression: {line.strip()!r}")
    # E1: a variable set where no env shows it. In a test step's script, an assignment; in the
    # build job, any write to $GITHUB_ENV (a later step would run with what it set).
    for n in sorted(allowed_text):
        hit = ASSIGNMENT.search(lines[n])
        if hit:
            errors.append(f"{WORKFLOW}:{n + 1}: E1 {hit.group(1)} assigned in a test step's script: {lines[n].strip()!r}; set it in the step's env")
    for i, line in yaml_code(job, indexed=True):
        if GITHUB_ENV.search(line):
            errors.append(f"{WORKFLOW}:{i + offset + 1}: E1 the {BUILD_JOB} job writes $GITHUB_ENV, which sets variables for the steps after it: {line.strip()!r}")
    # The YAML forms the rules don't read: a quoted key, or entries brought in by an anchor.
    for n, line in yaml_structure(lines):
        if QUOTED_KEY.match(line):
            errors.append(f"{WORKFLOW}:{n + 1}: a quoted YAML key: the rules read plain keys, so write it unquoted: {line.strip()!r}")
        if ANCHOR.match(line):
            errors.append(f"{WORKFLOW}:{n + 1}: a YAML anchor, alias or merge key: the rules read each step's own lines, so write the entries out: {line.strip()!r}")
    # E2: no matrix.
    job_code = yaml_code(job, indexed=True)
    for i, line in job_code:
        if re.match(r"^    strategy:", line):
            errors.append(f"{WORKFLOW}:{i + offset + 1}: E2 the {BUILD_JOB} job has a strategy: a matrix would run the variants on builds of their own")
    for k, expression in expressions([l for _, l in job_code]):
        i, line = job_code[k]
        if STRATEGY_USE.search(expression):
            errors.append(f"{WORKFLOW}:{i + offset + 1}: E2 the {BUILD_JOB} job uses the strategy context: {line.strip()!r}")
        elif MATRIX_USE.search(expression):
            errors.append(f"{WORKFLOW}:{i + offset + 1}: E2 the {BUILD_JOB} job uses the matrix context: {line.strip()!r}")
    # E3: the manifest reads no environment.
    if package_swift is None:
        errors.append("Package.swift: not found (E3)")
    else:
        stripped = strip(package_swift)
        for m in PACKAGE_ENV.finditer(stripped):
            errors.append(f"Package.swift:{line_of(stripped, m.start())}: E3 reads the environment ({m.group(0)}), so a variable could change the build")
    # E4: one build, run as built.
    builds = [(i, line) for i, line in job_code if re.search(r"\bswift build\b", line)]
    build_steps = [s for s in steps if any(re.search(r"\bswift build\b", l) for l in yaml_code([l for _, l in s]))]
    if len(builds) != 1 or builds[0][1] != BUILD_RUN:
        errors.append(f"{where} must build once, with `{BUILD_RUN.strip()}`; it has {len(builds)} swift build line(s)"
                      + (f": {builds[0][1].strip()!r}" if len(builds) == 1 else ""))
    elif not any(re.match(r"^      id:\s*build\s*$", l) for _, l in build_steps[0]):
        errors.append(f"{where}'s build step has no `id: build`, which the test steps' if: reads (E4)")
    names = [step_name([l for _, l in s]) for s in tests]
    for variant in VARIANT_STEPS:
        if names.count(variant) != 1:
            errors.append(f"{where} has {names.count(variant)} test steps named {variant!r}, not one: a variant dropped or doubled (E4)")
    for step in tests:
        name = step_name([l for _, l in step])
        if not any(l == TEST_IF for _, l in step):
            errors.append(f"{where}'s test step {name!r} doesn't have `{TEST_IF.strip()}`: it could run on missing or partial products (E4)")
        for line in run_lines([l for _, l in step]):
            if not re.search(r"\bswift test\b", line):
                continue
            invocations, problem = swift_test_invocations(line)
            if problem:
                errors.append(f"{where}'s test step {name!r} {problem} (E4)")
            for words in invocations:
                for problem in test_option_errors(words):
                    errors.append(f"{where}'s test step {name!r} {problem} (E4)")
        # Each variant step sets its own flag off: a step that keeps its name and turns its flag
        # back on would run the defaults again, and its pins read their expectation from the env.
        wanted = VARIANT_FLAGS_OFF.get(name, ())
        env = step_env([l for _, l in step])
        unset = [v for v in wanted if env.get(v) not in ('"false"', "'false'", "false")]
        if unset:
            errors.append(f"{where}'s test step {name!r} doesn't set {' and '.join(unset)} to false in its env: the variant would run the defaults (E4)")
    # E5: the shared steps' scripts.
    seen = set()  # a script named twice is read once
    for step in steps:
        if step in tests:
            continue
        name = step_name([l for _, l in step])
        todo = [s for line in yaml_code([l for _, l in step]) for s in SCRIPT_REF.findall(line)]
        while todo:
            script = todo.pop()
            if script in seen:
                continue
            seen.add(script)
            text = read_script(script)
            if text is None:
                errors.append(f"{where}'s step {name!r}: {script} doesn't exist (E5)")
                continue
            hit = FLAG_NAMES.search(text)
            if hit:
                errors.append(f"{script}:{line_of(text, hit.start())}: names {hit.group(0)}, so the step every variant shares could read it (E5)")
            todo += SCRIPT_REF.findall(text)
    return errors, [step_name([l for _, l in s]) for s in tests]


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
        f"jobs:\n  {BUILD_JOB}:\n    steps:\n    - name: Tests, in-turn sync off\n      run: swift test --skip-build\n"
        f"    - name: {TABLES_STEP}\n      env:\n        USE_SYNC_TABLES: \"false\"\n        TYPED_LEAF_VALUES: \"false\"\n"
        f"        FILTER: ${{{{ !inputs.full_matrix && '{regex}' || '' }}}}\n"
        "      run: |\n        set -o pipefail\n        swift test --skip-build ${FILTER:+--filter \"$FILTER\"} 2>&1 | tee out.log\n"
        "    - name: Tests, per-player sync tables off\n      run: swift test --skip-build --filter 'X\\.'\n"
        "  other:\n    steps:\n    - run: x\n"
    )
    both = job(r"SwiftStateTreeTransportTests\.|SwiftStateTreeNIOTests\.")
    filtered, filter_errors = filtered_targets(both)
    sources = [
        ("an adapter without transportEnvConfig:", "let a = TransportAdapter<S>(keeper: k, transport: t, landID: \"x\")\n", "R1"),
        ("a benchmark handle without transportEnvConfig:",
         "let a = TransportAdapterBenchmarkHandle<S>(keeper: k, transport: t, landID: \"x\")\n", "R1"),
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
    # The filter is the step's own FILTER line.
    names2 = {"SwiftStateTreeTransportTests", "SwiftStateTreeNIOTests"}
    for name, workflow, want_names, want_error in [
        ("the step's filter names Transport and NIO", both, names2, None),
        ("a filter without NIO names only Transport", job(r"SwiftStateTreeTransportTests\."), {"SwiftStateTreeTransportTests"}, None),
        ("no FILTER line in the step fails", both.replace("FILTER:", "FILTERS:"), set(), "0 FILTER entries"),
        ("a FILTER line in another step fails",
         both.replace("        FILTER: ", "        X: y\n    - name: Other\n      env:\n        FILTER: "), set(), "0 FILTER entries"),
        ("a second FILTER line in another step fails",
         both.replace("    - name: Tests, per-player", "    - name: Other\n      env:\n        FILTER: ${{ !inputs.full_matrix && 'A\\.' || '' }}\n      run: x\n    - name: Tests, per-player"),
         set(), "sets FILTER 1 more time"),
        ("a second FILTER key in the step fails (YAML keeps the last)",
         both.replace("        FILTER: ", "        FILTER: ${{ !inputs.full_matrix && 'X\\.' || '' }}\n        FILTER: "), set(), "2 FILTER entries"),
        ("a FILTER in the job's env fails", both.replace("    steps:\n", "    env:\n      FILTER: ''\n    steps:\n", 1), set(), "sets FILTER 1 more time"),
        ("a FILTER in the workflow's env fails", "env:\n  FILTER: ''\n" + both, set(), "sets FILTER 1 more time"),
        ("a FILTER assigned in the step's script fails",
         both.replace("        set -o pipefail\n", "        set -o pipefail\n        FILTER=''\n"), set(), "sets FILTER 1 more time"),
        ("no step of that name fails", both.replace(f"name: {TABLES_STEP}", "name: Tests, tables off"), set(), "0 steps named"),
        ("two steps of that name fail", both.replace("name: Tests, in-turn sync off", f"name: {TABLES_STEP}"), set(), "2 steps named"),
        ("the step in another job only fails", both.replace(f"  {BUILD_JOB}:", "  other2:"), set(), f"no {BUILD_JOB} job"),
        ("a step that leaves USE_SYNC_TABLES on fails", both.replace('USE_SYNC_TABLES: "false"', 'USE_SYNC_TABLES: "true"'), set(), "doesn't set USE_SYNC_TABLES to false"),
        ("a step without TYPED_LEAF_VALUES fails", both.replace('        TYPED_LEAF_VALUES: "false"\n', ""), set(), "doesn't set TYPED_LEAF_VALUES to false"),
        ("an alternative that isn't a whole target fails", job(r"SwiftStateTreeTransportTests\.|NIO"), None, "isn't a whole target"),
        ("a swift test that ignores FILTER fails", both.replace(' ${FILTER:+--filter "$FILTER"}', ""), None, "ignores FILTER"),
        ("a second swift test in the step fails", both.replace("2>&1 | tee out.log\n", "2>&1 | tee out.log\n        swift test --skip-build\n"), None, "2 swift test line(s)"),
        ("a swift test only in a comment doesn't count", both.replace("      run: |\n", "      # swift test\n      run: |\n"), names2, None),
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
    failed += variant_self_test()
    return failed


def variant_self_test():
    """Section 2's cells (E1–E5), against a sample of the build job's shape."""
    IF = TEST_IF + "\n"
    def build(workflow_env="", job_env="", strategy="", lint="      run: |\n        scripts/lint.sh --self-test\n        scripts/lint.sh\n",
              build_step="    - name: Build\n      id: build\n" + BUILD_RUN + "\n",
              on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-build 2>&1 | tee on.log\n',
              tables=('      env:\n        USE_SYNC_TABLES: "false"\n        TYPED_LEAF_VALUES: "false"\n'
                      "      run: |\n        swift test --skip-build --filter 'A\\.' 2>&1 | tee t.log\n"
                      "        grep -q 'takes USE_SYNC_TABLES' t.log\n"),
              per_player=('      env:\n        PER_PLAYER_SYNC_TABLES: "false"\n'
                          "      run: |\n        swift test --skip-build --filter 'A\\.|B\\.' 2>&1 | tee p.log \\\n"
                          "          || exit 1\n"),
              wall_clock="      run: WALL_CLOCK_TESTS=1 swift test --skip-build --no-parallel --filter W\n",
              test_if=IF, extra="", other=""):
        return ("on: push\n" + workflow_env + "jobs:\n  build:\n    name: build (variants)\n" + strategy + job_env +
                "    steps:\n    - uses: actions/checkout@v4\n    - name: Lint\n" + lint + build_step +
                "    - name: Snippets\n      run: scripts/snippets.sh\n"
                "    - name: Tests\n      id: on\n" + test_if + on +
                "    - name: Tests, sync tables off\n      id: tables\n" + test_if + tables +
                "    - name: Tests, per-player sync tables off\n      id: per_player\n" + test_if + per_player +
                "    - name: Run wall-clock tests\n" + test_if + wall_clock +
                extra + "    - name: Summary\n      if: ${{ always() }}\n      env:\n        ON: ${{ steps.on.outcome }}\n      run: echo \"$ON\"\n"
                "  other:\n    steps:\n    - run: x\n" + other)
    scripts = {"scripts/lint.sh": "echo lint\n", "scripts/snippets.sh": "swift build --target \"$t\"\nscripts/helper.py\n",
               "scripts/helper.py": "print(1)\n"}
    manifest = "// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: \"P\")\n"
    tests = list(VARIANT_STEPS)
    cells = [
        ("today's shape", build(), scripts, manifest, None),
        # E1
        ("a variable in the workflow's env fails", build(workflow_env='env:\n  USE_SYNC_TABLES: "false"\n'), scripts, manifest, "E1 USE_SYNC_TABLES outside a test step's env"),
        ("a variable in the job's env fails", build(job_env='    env:\n      USE_SYNC_TABLES: "false"\n'), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a variable on the build step fails",
         build(build_step="    - name: Build\n      id: build\n      env:\n        TYPED_LEAF_VALUES: \"false\"\n" + BUILD_RUN + "\n"), scripts, manifest, "E1 TYPED_LEAF_VALUES outside"),
        ("a variable on a shared script step fails",
         build(lint='      env:\n        PER_PLAYER_SYNC_TABLES: "false"\n      run: scripts/lint.sh\n'), scripts, manifest, "E1 PER_PLAYER_SYNC_TABLES outside"),
        ("a variable in a compiler flag fails",
         build(build_step="    - name: Build\n      id: build\n      run: swift build --build-tests -Xswiftc -DUSE_SYNC_TABLES\n"), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a variable in another job fails", build(other="    - run: USE_SYNC_TABLES=false swift test\n"), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("$VAR in a test step's script fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: echo "$USE_SYNC_TABLES" && swift test --skip-build\n'), scripts, manifest, "E1 a shell expansion of USE_SYNC_TABLES"),
        ("${VAR} in a test step's script fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: |\n        echo "${USE_SYNC_TABLES}"\n        swift test --skip-build\n'), scripts, manifest, "E1 a shell expansion of USE_SYNC_TABLES"),
        ("env.VAR in a test step's if: fails",
         build(test_if="      if: ${{ !cancelled() && steps.build.outcome == 'success' && env.USE_SYNC_TABLES == 'true' }}\n"), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("env['VAR'] in a shared step's if: fails",
         build(lint="      if: ${{ env['USE_SYNC_TABLES'] != 'false' }}\n      run: scripts/lint.sh\n"), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a variable in an expression in a test step's script fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: echo ${{ env.USE_SYNC_TABLES }} && swift test --skip-build\n'), scripts, manifest, "E1 USE_SYNC_TABLES in an expression"),
        ("an env value that isn't a literal fails",
         build(on='      env:\n        USE_SYNC_TABLES: ${{ inputs.sync }}\n      run: swift test --skip-build\n'), scripts, manifest, "isn't a literal true or false"),
        ("another env var built from a variable fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n        SYNC: ${{ env.USE_SYNC_TABLES }}\n      run: swift test --skip-build\n'), scripts, manifest, "isn't a literal true or false"),
        ("a variable in a test step's name fails",
         build(extra="    - name: Tests, USE_SYNC_TABLES off\n" + IF + '      env:\n        USE_SYNC_TABLES: "false"\n      run: swift test --skip-build\n'), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a variable in a run block's # line of a shared step fails",
         build(lint="      run: |\n        # $USE_SYNC_TABLES\n        scripts/lint.sh\n"), scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a YAML comment naming a variable doesn't count", build(extra="    # USE_SYNC_TABLES and TYPED_LEAF_VALUES\n"), scripts, manifest, None),
        # E2
        ("a matrix fails", build(strategy="    strategy:\n      matrix:\n        x: [a, b]\n"), scripts, manifest, "E2"),
        ("the matrix context fails", build(extra="    - name: Dump\n      run: echo '${{ toJSON(matrix) }}'\n"), scripts, manifest, "E2 the build job uses the matrix context"),
        ("strategy.job-index in a run block's # line fails",
         build(extra="    - name: Dump\n      run: |\n        # ${{ strategy.job-index }}\n"), scripts, manifest, "E2 the build job uses the strategy context"),
        ("display text naming matrix or strategy doesn't count",
         build(extra="    - name: Dump strategy and matrix\n      run: echo matrix strategy\n"), scripts, manifest, None),
        # E3
        ("Package.swift reading ProcessInfo fails", build(), scripts, manifest + 'let x = ProcessInfo.processInfo.environment["X"]\n', "E3 reads the environment (ProcessInfo)"),
        ("Package.swift calling getenv fails", build(), scripts, manifest + 'let x = getenv("X")\n', "E3 reads the environment (getenv)"),
        ("Package.swift reading Context.environment fails", build(), scripts, manifest + 'let x = Context.environment["X"]\n', "E3 reads the environment (Context.environment)"),
        ("Package.swift naming them only in comments and strings passes", build(), scripts, manifest + '// ProcessInfo getenv\nlet s = "Context.environment["\n', None),
        # E4
        ("a second swift build fails",
         build(extra="    - name: Again\n      run: swift build\n"), scripts, manifest, "2 swift build line(s)"),
        ("a build without --build-tests fails",
         build(build_step="    - name: Build\n      id: build\n      run: swift build\n"), scripts, manifest, "'run: swift build'"),
        ("a build step without its id fails", build(build_step="    - name: Build\n" + BUILD_RUN + "\n"), scripts, manifest, "no `id: build`"),
        ("a test step without --skip-build fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test\n'), scripts, manifest, "without --skip-build"),
        ("a test step with another flag fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-build -c release\n'), scripts, manifest, "passes -c"),
        ("a test step with -Xswiftc fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-build -Xswiftc -DX\n'), scripts, manifest, "passes -Xswiftc"),
        ("a test step without the build's if: fails", build(test_if="      if: ${{ always() }}\n"), scripts, manifest, "could run on missing or partial products"),
        ("a test step with no if: fails", build(test_if=""), scripts, manifest, "could run on missing or partial products"),
        # E5
        ("a shared script naming USE_SYNC_TABLES fails", build(), {**scripts, "scripts/lint.sh": "[ \"$USE_SYNC_TABLES\" = true ]\n"}, manifest, "names USE_SYNC_TABLES"),
        ("a shared script naming useSyncTables fails", build(), {**scripts, "scripts/lint.sh": "grep useSyncTables x\n"}, manifest, "names useSyncTables"),
        ("a script it calls naming the key fails", build(), {**scripts, "scripts/helper.py": "k = 'perPlayerSyncTables'\n"}, manifest, "helper.py:1: names perPlayerSyncTables"),
        ("a shared script that doesn't exist fails", build(), {k: v for k, v in scripts.items() if k != "scripts/lint.sh"}, manifest, "doesn't exist"),
        # E1: a variable set where no env shows it (#669)
        ("an inline assignment in a test step's script fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: USE_SYNC_TABLES=false swift test --skip-build\n'), scripts, manifest,
         "E1 USE_SYNC_TABLES assigned in a test step's script"),
        ("an export in a test step's run block fails",
         build(on='      run: |\n        export TYPED_LEAF_VALUES=false\n        swift test --skip-build\n'), scripts, manifest, "E1 TYPED_LEAF_VALUES assigned"),
        ("a write to $GITHUB_ENV fails",
         build(extra="    - name: Set\n      run: echo \"X=1\" >> \"$GITHUB_ENV\"\n"), scripts, manifest, "writes $GITHUB_ENV"),
        ("a uses: step whose with: names swift test isn't a test step",
         build(extra='    - name: Action\n' + IF + '      uses: some/action@v1\n      env:\n        USE_SYNC_TABLES: "false"\n      with:\n        args: swift test --skip-build\n'),
         scripts, manifest, "E1 USE_SYNC_TABLES outside"),
        ("a variable on a plain if:'s continuation line fails",
         build(test_if="      if: success() &&\n        env.USE_SYNC_TABLES == 'true'\n"), scripts, manifest,
         "E1 USE_SYNC_TABLES in an expression"),
        ("a variable on a shared step's plain if: continuation fails",
         build(lint="      if: always() &&\n        env.TYPED_LEAF_VALUES != 'false'\n      run: scripts/lint.sh\n"), scripts, manifest, "E1 TYPED_LEAF_VALUES"),
        # The YAML forms the rules don't read (#665, #669)
        ("a quoted strategy key fails", build(strategy='    "strategy":\n      matrix:\n        x: [a, b]\n'), scripts, manifest, "a quoted YAML key"),
        ("a quoted run key fails", build(lint="      'run': |\n        scripts/lint.sh\n"), scripts, manifest, "a quoted YAML key"),
        ("env entries brought in by an alias fail",
         build(workflow_env="x-pins: &pins\n  A: b\n", extra="    - name: Again\n" + IF + "      env: *pins\n      run: swift test --skip-build\n"), scripts, manifest,
         "a YAML anchor, alias or merge key"),
        ("a merge key fails",
         build(extra="    - name: Again\n" + IF + "      env:\n        <<: {A: b}\n      run: swift test --skip-build\n"), scripts, manifest,
         "a YAML anchor, alias or merge key"),
        ("* and & in a run block are the shell's", build(extra="    - name: Glob\n      run: |\n        ls *.swift &\n        wait\n"), scripts, manifest, None),
        # E4: run as built, read as shell words (#669)
        ("--skip-build as --filter's value fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --filter --skip-build\n'), scripts, manifest, "without --skip-build"),
        ("--skip-builds isn't --skip-build",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-builds\n'), scripts, manifest, "without --skip-build"),
        ("a doubled variant step fails",
         build(extra="    - name: Tests\n" + IF + "      run: swift test --skip-build\n"), scripts, manifest, "2 test steps named 'Tests'"),
        # E4: every swift test on a line, cut at list operators outside quotes (#703 review)
        ("a second swift test after && without --skip-build fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-build && swift test\n'), scripts, manifest, "without --skip-build"),
        ("a second swift test after ; without --skip-build fails",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: true; swift test --skip-build; swift test --filter X\n'), scripts, manifest, "without --skip-build"),
        ("a quoted | in --filter's value is one word",
         build(on="      env:\n        USE_SYNC_TABLES: \"true\"\n      run: swift test --skip-build --filter 'A | B' 2>&1 | tee on.log\n"), scripts, manifest, None),
        ("a redirection's target isn't an option",
         build(on='      env:\n        USE_SYNC_TABLES: "true"\n      run: swift test --skip-build > on.log 2> err.log\n'), scripts, manifest, None),
    ]
    # One field of today's shape changed at a time, in each variant step: its name (the variant
    # dropped), its if:, and its --skip-build.
    today = build()
    for variant in VARIANT_STEPS:
        start = today.index(f"    - name: {variant}\n")
        end = today.index("    - name: ", start + 1)
        step = today[start:end]
        for change, changed, want in [
            ("renamed", step.replace(f"name: {variant}\n", f"name: {variant} (renamed)\n", 1), f"0 test steps named {variant!r}"),
            ("without its if:", step.replace(IF, "", 1), "could run on missing or partial products"),
            ("without --skip-build", step.replace(" --skip-build", "", 1), "without --skip-build"),
        ] + [
            # Its flags turned back on, or dropped (#703 review): the variant would run the defaults.
            (f"with {flag} on", step.replace(f'{flag}: "false"', f'{flag}: "true"', 1), f"doesn't set {flag} to false")
            for flag in VARIANT_FLAGS_OFF.get(variant, ())
        ] + [
            (f"without {flag}", step.replace(f'        {flag}: "false"\n', "", 1), f"doesn't set {flag} to false")
            for flag in VARIANT_FLAGS_OFF.get(variant, ())
        ]:
            assert changed != step, (variant, change)
            cells.append((f"today's shape, {variant!r} {change}, fails", today[:start] + changed + today[end:], scripts, manifest, want))
    failed = 0
    for name, workflow, files, package_swift, want in cells:
        errors, names = variant_errors(workflow, package_swift, files.get)
        ok = (not errors and names == tests) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {names} {errors}"))
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
manifest = pathlib.Path("Package.swift")
leg, test_steps = variant_errors(workflow, manifest.read_text(encoding="utf-8") if manifest.is_file() else None, read_repo_script)
for e in errors + leg:
    print(f"::error::{e}")
if not errors:
    names = ", ".join(n for n, _ in scanned_targets(package, filtered)) or "none"
    print(f"variant test selection: {TABLES_STEP!r} runs {', '.join(sorted(filtered))} on a push; {files} files in the other targets that reach {TRANSPORT} ({names}) pin both flags")
if not leg:
    print(f"variant test selection: one build serves {len(test_steps)} test steps ({', '.join(test_steps)}); the variables appear only in their env, and nothing shared reads them")
sys.exit(1 if errors or leg else 0)
PY
