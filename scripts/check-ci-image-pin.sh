#!/usr/bin/env bash
# Every Swift container image in the workflows is pinned to one digest, and every SwiftPM cache
# step keys on that digest, so a cache never outlives the image it was filled with and the jobs
# can't drift onto different images when the tag is pushed again.
#
# Images: `image:`, `container:` and `uses: docker://` values naming a `swift:` image, quoted or
# not, with or without a registry prefix, in .github/workflows/*.yml and *.yaml. They must all be
# the same `swift:<tag>@sha256:<64 hex>`.
# Cache steps: the steps whose `path:` is SwiftPM's shared cache (~/.cache/org.swift.swiftpm).
# There must be at least one; its `key` and every `restore-keys` entry must hold the digest as a
# key segment (`-<digest>-`), outside a comment.
#
# Usage: scripts/check-ci-image-pin.sh [--self-test] [workflows dir]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import pathlib
import re
import sys
import tempfile

# A Swift image as the value of an `image:` or `container:` key, or a `uses: docker://` step,
# quoted or not, with or without a registry (a `host:port/` one included). Only in key position, so
# a string value that merely contains "image: swift:" (an env value, a run line) is not read.
IMAGE = re.compile(r"""^\s*(?:-\s+)?(?:(?:image|container):\s*["']?|uses:\s*["']?docker://)((?:[\w.-]+(?::\d+)?/)*swift:[^\s"'#,}]+)""")
# The flow form, `container: { image: swift:…, … }`: the image key inside the braces.
FLOW_IMAGE = re.compile(r"""^\s*(?:-\s+)?container:\s*\{.*?\bimage:\s*["']?((?:[\w.-]+(?::\d+)?/)*swift:[^\s"'#,}]+)""")
# An image given as a block scalar (`image: >-` and the value on the next lines) isn't read:
# it is refused, so an image can't hide from the check in a form it doesn't parse.
BLOCK_IMAGE = re.compile(r"^\s*(?:-\s+)?(?:image|container):\s*[|>]")
PINNED = re.compile(r"^swift:[\w.-]+@sha256:([0-9a-f]{64})$")
CACHE_DIR = "~/.cache/org.swift.swiftpm"
STEP = re.compile(r"^(\s*)- ")


def uncommented(line):
    """The line without a trailing comment (a `#` at the start or after whitespace)."""
    return re.split(r"(?:^|\s)#", line, maxsplit=1)[0]


def steps(lines):
    """Each step's lines: from a `- ` item to the next item at the same indent or less."""
    out, cur, indent = [], None, None
    for line in lines:
        m = STEP.match(line)
        if m and (indent is None or len(m.group(1)) <= indent):
            if cur:
                out.append(cur)
            cur, indent = [line], len(m.group(1))
        elif cur is not None:
            if line.strip() and not line.startswith(" " * (indent + 1)) and not line.startswith(" " * indent + "-"):
                out.append(cur)
                cur, indent = None, None
            else:
                cur.append(line)
    if cur:
        out.append(cur)
    return out


def block_values(step, names):
    """(name, value) for each `name:` in the step. A plain or quoted scalar is one value. A block
    scalar gives one value per line for `|` (a restore-keys list, a path list), and its lines joined
    by spaces for `>` (a folded key)."""
    values, i = [], 0
    while i < len(step):
        m = re.match(r"^(\s*)(" + "|".join(names) + r"):\s*(.*)$", step[i])
        if not m:
            i += 1
            continue
        indent, name, rest = len(m.group(1)), m.group(2), uncommented(m.group(3)).strip()
        i += 1
        if rest[:1] in ("|", ">"):
            body = []
            while i < len(step) and (not step[i].strip() or len(step[i]) - len(step[i].lstrip()) > indent):
                if step[i].strip():
                    body.append(uncommented(step[i]).strip())
                i += 1
            if rest[0] == ">":
                values.append((name, " ".join(body)))
            else:
                values.extend((name, b) for b in body)
        else:
            values.append((name, rest.strip("\"'")))
    return values


def check(workflows):
    errors = []
    files = sorted(list(workflows.glob("*.yml")) + list(workflows.glob("*.yaml")))
    images = {}
    cache_steps = []
    for f in files:
        lines = f.read_text(encoding="utf-8").splitlines()
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                continue
            text = uncommented(line)
            if BLOCK_IMAGE.match(text):
                errors.append(f"{f.name}:{n}: a container image must be a plain or quoted value, not a block scalar")
            for m in [*IMAGE.finditer(text), *FLOW_IMAGE.finditer(text)]:
                images.setdefault(m.group(1), []).append(f"{f.name}:{n}")
        for step in steps(lines):
            if any(v == CACHE_DIR for _, v in block_values(step, ["path"])):
                cache_steps.append((f.name, step))
    if errors:
        return errors
    if not images:
        return [f"no Swift container image found in {workflows}"]
    if len(images) > 1:
        errors.append("the workflows use more than one Swift container image: "
                      + "; ".join(f"{i} ({', '.join(w)})" for i, w in sorted(images.items())))
    digest = None
    for image, where in sorted(images.items()):
        m = PINNED.match(image)
        if not m:
            errors.append(f"not pinned by a full digest (swift:<tag>@sha256:<64 hex>): {image} ({', '.join(where)})")
        else:
            digest = m.group(1)
    if errors:
        return errors
    if not cache_steps:
        return [f"no SwiftPM cache step found (a step with path: {CACHE_DIR})"]
    for name, step in cache_steps:
        values = block_values(step, ["key", "restore-keys"])
        if not any(k == "key" for k, _ in values):
            errors.append(f"{name}: a SwiftPM cache step has no key")
        for k, v in values:
            if f"-{digest}-" not in v:
                errors.append(f"{name}: {k} doesn't hold the image digest as a key segment: {v}")
    if errors:
        return errors
    print(f"ci image pin: {next(iter(images))}; {len(cache_steps)} SwiftPM cache steps key on its digest")
    return []


D = "3459518b2e723a7c363d0f8cfa44fc796c77ecd8c18e92fd10e6f92dd78c0b12"
GOOD = f"""jobs:
  a:
    container:
      image: swift:6.2.4-noble@sha256:{D}
    steps:
    - uses: actions/checkout@v4

    - name: SwiftPM shared cache
      uses: actions/cache@v4
      with:
        path: ~/.cache/org.swift.swiftpm
        key: swiftpm-${{{{ github.job }}}}-{D}-${{{{ hashFiles('Package.resolved') }}}}
        restore-keys: |
          swiftpm-${{{{ github.job }}}}-{D}-
"""


def self_test():
    other = "0" * 64
    cases = [
        ("good", GOOD, None),
        ("quoted unpinned", GOOD + '  b:\n    container:\n      image: "swift:6.2.4-noble"\n', "more than one"),
        ("short container form", GOOD + "  b:\n    container: swift:6.2.4-noble\n", "more than one"),
        ("docker uses", GOOD + "  b:\n    steps:\n    - uses: docker://swift:6.2.4-noble\n", "more than one"),
        ("registry-qualified", GOOD.replace("image: swift:", "image: docker.io/library/swift:"), "not pinned"),
        ("truncated digest", GOOD.replace(f"@sha256:{D}", f"@sha256:{D[:12]}"), "not pinned"),
        ("no cache step", GOOD.split("    - name: SwiftPM")[0], "no SwiftPM cache step"),
        ("digest only in a comment", GOOD.replace(f"key: swiftpm-${{{{ github.job }}}}-{D}-", f"key: swiftpm-${{{{ github.job }}}}-x- # {D}"), "key doesn't hold"),
        ("stale restore key", GOOD.replace(f"          swiftpm-${{{{ github.job }}}}-{D}-", f"          swiftpm-${{{{ github.job }}}}-{other}-"), "restore-keys doesn't hold"),
        ("host:port registry", GOOD + "  b:\n    container:\n      image: localhost:5000/swift:6.2.4-noble\n", "more than one"),
        ("an env value naming an image is not an image",
         GOOD + '  b:\n    env:\n      NOTE: "image: swift:6.2.4-noble"\n    steps:\n    - run: echo "container: swift:x"\n', None),
        ("quoted cache path with a stale key",
         GOOD.replace("path: ~/.cache/org.swift.swiftpm", 'path: "~/.cache/org.swift.swiftpm"').replace(f"-{D}-$", f"-{other}-$"),
         "key doesn't hold"),
        ("cache path in a list block with a stale key",
         GOOD.replace("path: ~/.cache/org.swift.swiftpm", "path: |\n          ~/.cache/org.swift.swiftpm\n          ~/.npm").replace(f"-{D}-$", f"-{other}-$"),
         "key doesn't hold"),
        ("flow container, unpinned", GOOD + "  b:\n    container: { image: swift:6.2.4-noble, options: --privileged }\n", "more than one"),
        ("flow container, pinned", GOOD + f"  b:\n    container: {{ image: swift:6.2.4-noble@sha256:{D} }}\n", None),
        ("block-scalar image", GOOD + "  b:\n    container:\n      image: >-\n        swift:6.2.4-noble\n", "not a block scalar"),
        ("a folded key holding the digest",
         GOOD.replace(f"key: swiftpm-${{{{ github.job }}}}-{D}-${{{{ hashFiles('Package.resolved') }}}}",
                      f"key: >-\n          swiftpm-${{{{ github.job }}}}-{D}-\n          ${{{{ hashFiles('Package.resolved') }}}}"),
         None),
    ]
    failed = 0
    for name, text, want in cases:
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            (d / "w.yml").write_text(text, encoding="utf-8")
            errors = check(d)
        ok = (not errors) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    # A *.yaml file is read too.
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        (d / "a.yml").write_text(GOOD, encoding="utf-8")
        (d / "b.yaml").write_text("jobs:\n  b:\n    container:\n      image: swift:6.2.4-noble\n", encoding="utf-8")
        errors = check(d)
    ok = any("more than one" in e for e in errors)
    print(f"{'ok  ' if ok else 'FAIL'} self-test: a .yaml workflow")
    failed += not ok
    return failed


args = sys.argv[1:]
if args[:1] == ["--self-test"]:
    sys.exit(1 if self_test() else 0)
errors = check(pathlib.Path(args[0] if args else ".github/workflows"))
for e in errors:
    print(f"::error::{e}")
sys.exit(1 if errors else 0)
PY
