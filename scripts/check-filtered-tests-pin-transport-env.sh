#!/usr/bin/env bash
# The sync-tables-off job runs only the Transport and NIO tests, with USE_SYNC_TABLES=false and
# TYPED_LEAF_VALUES=false. That is safe only while no other test can read those two flags, so this
# check fails if one could. It is a safe regression test selection in the sense of Rothermel and
# Harrold (TOSEM 1997): a test is left out only if it can't reach the env reads.
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
# .github/workflows/build-and-test.yml, whose alternatives must each be a whole target (`Name\.`).
# So the job and this check can't name different targets.
#
# What it can't see (the nightly runs the whole suite in that job, as the backstop): R1 reads the
# argument labels, not their types, so a non-optional expression that is nil at run time isn't
# caught; R2 is textual, so it doesn't check that the pins set the same variable as the
# construction, and it counts a pin under an inactive `#if` or in a closure that never runs. A
# dump of the package this check can't read fails it rather than scanning nothing.
#
# Usage: scripts/check-filtered-tests-pin-transport-env.sh [--self-test] [--package-json <file>]
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
# The job's filter on a push: `FILTER: ${{ !inputs.full_matrix && '<regex>' || '' }}`.
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
    errors = []
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
        "      run: swift test\n  per-player:\n    steps: []\n"
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
    return failed


args = sys.argv[1:]
if args[:1] == ["--self-test"]:
    sys.exit(1 if self_test() else 0)
filtered, errors = filtered_targets(pathlib.Path(WORKFLOW).read_text(encoding="utf-8"))
files = 0
if not errors:
    package = package_from(args)
    errors, files = check(pathlib.Path("."), package, filtered)
for e in errors:
    print(f"::error::{e}")
if not errors:
    names = ", ".join(n for n, _ in scanned_targets(package, filtered)) or "none"
    print(f"filtered-tests transport env: {JOB} runs {', '.join(sorted(filtered))} on a push; {files} files in the other targets that reach {TRANSPORT} ({names}) pin both flags")
sys.exit(1 if errors else 0)
PY
