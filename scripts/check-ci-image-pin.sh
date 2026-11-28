#!/usr/bin/env bash
# Every Swift container image in the workflows is pinned to one digest, and every SwiftPM cache
# step keys on that digest, so a cache never outlives the image it was filled with and the jobs
# can't drift onto different images when the tag is pushed again. The same holds for every Swift
# `FROM` line of the repo's Dockerfiles (#780).
#
# Images: `image:`, `container:` and `uses: docker://` values naming a `swift:` image, quoted or
# not, with or without a registry prefix, in .github/workflows/*.yml and *.yaml. They must all be
# the same `swift:<tag>@sha256:<64 hex>`.
# Cache steps: the steps whose `path:` is SwiftPM's shared cache (~/.cache/org.swift.swiftpm).
# There must be at least one; its `key` and every `restore-keys` entry must hold the digest as a
# key segment (`-<digest>-`), outside a comment.
# Dockerfiles: every tracked file named exactly `Dockerfile` or `Dockerfile.<suffix>`, at any depth
# (`git ls-files`). Not read: `*.dockerfile` and `Containerfile` (none exist today); a file that
# should be checked has to be named one of the two. Each `FROM` line naming a `swift` image, with
# or without `--platform=…` and `AS <stage>`, must be `swift:<tag>@sha256:<64 hex>` with the digest
# of the workflows' pin. A `FROM ubuntu` line (the run images' runtime stage) must name the Swift
# pin's distro, by its release or its codename (`swift:6.4.3-noble` → `ubuntu:24.04` or
# `ubuntu:noble`): the runtime stage loads the Swift runtime libraries the builder copied over, and
# its libicu and glibc must be the ones they were built against (#780). The ubuntu base stays
# pinned by tag, not by digest: the stage installs its packages with `apt-get` at build time, so
# they float whatever the base pins, and a tag keeps the base's security fixes. A `FROM` of another
# image or of an earlier stage isn't read. A `FROM` image holding a `$` (`FROM ${IMAGE}`, from an
# `ARG`) can't be resolved here, so it is refused: pin the image inline.
# Errors name the file and line.
#
# Usage: scripts/check-ci-image-pin.sh [--self-test] [workflows dir]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

# A Swift image as the value of an `image:` or `container:` key, or a `uses: docker://` step,
# quoted or not, with or without a registry (a `host:port/` one included). Only in key position, so
# a string value that merely contains "image: swift:" (an env value, a run line) is not read.
IMAGE = re.compile(r"""^\s*(?:-\s+)?(?:(?:image|container):\s*["']?|uses:\s*["']?docker://)((?:[\w.-]+(?::\d+)?/)*swift:[^\s"'#,}]+)""")
# The flow form, `container: { image: swift:…, … }`: the image key inside the braces.
FLOW_IMAGE = re.compile(r"""^\s*(?:-\s+)?container:\s*\{.*?\bimage:\s*["']?((?:[\w.-]+(?::\d+)?/)*swift:[^\s"'#,}]+)""")
# Not read, as no workflow uses them: a quoted key (`"image": …`) and a flow map spread over
# several lines. A workflow that starts using either needs this check extended first.
# An image given as a block scalar (`image: >-` and the value on the next lines) isn't read:
# it is refused, so an image can't hide from the check in a form it doesn't parse.
BLOCK_IMAGE = re.compile(r"^\s*(?:-\s+)?(?:image|container):\s*[|>]")
PINNED = re.compile(r"^swift:[\w.-]+@sha256:([0-9a-f]{64})$")
# A Dockerfile `FROM` line: its options (`--platform=…`), the image, and an optional `AS <stage>`.
FROM_LINE = re.compile(r"^\s*FROM\s+((?:--\S+\s+)*)(\S+)(?:\s+AS\s+(\S+))?\s*$", re.IGNORECASE)
# A Swift image in a `FROM` line: `swift`, with a registry prefix, a tag or a digest or none of them.
SWIFT_FROM = re.compile(r"^(?:[\w.-]+(?::\d+)?/)*swift(?:[:@]\S*)?$")
# An ubuntu image in a `FROM` line, with its tag (none for a bare `ubuntu`).
UBUNTU_FROM = re.compile(r"^(?:[\w.-]+(?::\d+)?/)*ubuntu(?::([^@\s]+))?(?:@\S*)?$")
# The Swift images' distro codenames and their Ubuntu releases.
UBUNTU_RELEASES = {"focal": "20.04", "jammy": "22.04", "noble": "24.04"}
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


def dockerfile_errors(dockerfiles, digest, codename):
    """Errors for the Swift and ubuntu `FROM` lines of `dockerfiles` ({name: text}) against the
    workflows' `digest` and distro `codename`, and how many Swift lines were read."""
    errors, count = [], 0
    for name, text in sorted(dockerfiles.items()):
        stages = set()
        for n, line in enumerate(text.splitlines(), 1):
            m = None if line.lstrip().startswith("#") else FROM_LINE.match(line)
            if not m:
                continue
            image, stage = m.group(2), m.group(3)
            if stage:
                stages.add(stage.lower())
            if "$" in image:
                errors.append(f"{name}:{n}: a FROM image from a build argument can't be checked; pin the Swift image inline: {image}")
                continue
            if image.lower() in stages:
                continue
            ubuntu = UBUNTU_FROM.match(image)
            if ubuntu:
                release = UBUNTU_RELEASES.get(codename)
                if release is None:
                    errors.append(f"{name}:{n}: the check doesn't know the distro of the Swift pin's tag ({codename}); add it to UBUNTU_RELEASES: {image}")
                elif ubuntu.group(1) not in (release, codename):
                    errors.append(f"{name}:{n}: the ubuntu base must be the Swift pin's distro, ubuntu:{release} ({codename}): {image}")
                continue
            if not SWIFT_FROM.match(image):
                continue
            count += 1
            pinned = PINNED.match(image)
            if not pinned:
                errors.append(f"{name}:{n}: a Swift FROM must be swift:<tag>@sha256:<64 hex>, not {image}")
            elif pinned.group(1) != digest:
                errors.append(f"{name}:{n}: the digest differs from the workflows' pin ({digest}): {image}")
    return errors, count


def tracked_dockerfiles():
    """{path: text} for each tracked file named Dockerfile or Dockerfile.*, from the repo root."""
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, encoding="utf-8", check=True).stdout
    paths = [p for p in out.splitlines() if re.match(r"(?i)^(?:.*/)?Dockerfile(?:\.[^/]*)?$", p)]
    return {p: pathlib.Path(p).read_text(encoding="utf-8") for p in paths}


def check(workflows, dockerfiles=None):
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
    summary = f"{len(cache_steps)} SwiftPM cache steps key on its digest"
    if dockerfiles is not None:
        codename = next(iter(images)).split("@")[0].rsplit("-", 1)[-1]
        errors, count = dockerfile_errors(dockerfiles, digest, codename)
        if errors:
            return errors
        if not count:
            return ["no Swift FROM line found in the Dockerfiles"]
        summary += f"; {count} Swift FROM lines in {len(dockerfiles)} Dockerfiles use it"
    print(f"ci image pin: {next(iter(images))}; {summary}")
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
    # Dockerfiles, checked against the workflows' pin (GOOD).
    pin = f"swift:6.2.4-noble@sha256:{D}"
    docker_cases = [
        ("dockerfile: a pinned FROM with AS builder", f"FROM {pin} AS builder\n", None),
        ("dockerfile: a non-Swift FROM by tag", f"FROM {pin} AS builder\nFROM ubuntu:24.04 AS runtime\n", None),
        ("dockerfile: a tag-only Swift FROM, with its file and line",
         f"FROM {pin} AS builder\nFROM swift:6.2.4-noble\n", "Dockerfile:2: a Swift FROM must be"),
        ("dockerfile: a digest that differs from the workflows'", f"FROM swift:6.2.4-noble@sha256:{other}\n", "Dockerfile:1: the digest differs"),
        ("dockerfile: a truncated digest", f"FROM swift:6.2.4-noble@sha256:{D[:12]}\n", "a Swift FROM must be"),
        ("dockerfile: a registry-qualified Swift image", f"FROM docker.io/library/{pin}\n", "a Swift FROM must be"),
        ("dockerfile: no tag at all", "FROM swift\n", "a Swift FROM must be"),
        ("dockerfile: lower-case keywords and a platform option", f"from --platform=linux/amd64 {pin} as builder\n", None),
        ("dockerfile: a comment naming an unpinned FROM", f"# FROM swift:6.2.4-noble\nFROM {pin}\n", None),
        ("dockerfile: a stage named swift is not an image", f"FROM {pin} AS swift\nFROM swift AS again\n", None),
        ("dockerfile: no Swift FROM at all", "FROM ubuntu:24.04\n", "no Swift FROM line"),
        ("dockerfile: a FROM image from an ARG, with its file and line",
         "ARG SWIFT_IMAGE=swift:6.2.4-noble\nFROM ${SWIFT_IMAGE} AS builder\n", "Dockerfile:2: a FROM image from a build argument"),
        ("dockerfile: a FROM image from a bare variable", f"FROM {pin} AS builder\nFROM $BASE\n", "Dockerfile:2: a FROM image from a build argument"),
        ("dockerfile: a $ in a platform option is not the image", f"FROM --platform=$BUILDPLATFORM {pin} AS builder\n", None),
        ("dockerfile: an ubuntu runtime by the codename's version", f"FROM {pin} AS builder\nFROM ubuntu:24.04 AS runtime\n", None),
        ("dockerfile: an ubuntu runtime by the codename itself", f"FROM {pin} AS builder\nFROM ubuntu:noble AS runtime\n", None),
        ("dockerfile: an ubuntu runtime of another release, with its file and line",
         f"FROM {pin} AS builder\nFROM ubuntu:22.04 AS runtime\n", "Dockerfile:2: the ubuntu base must be the Swift pin's distro"),
        ("dockerfile: an ubuntu runtime by latest", f"FROM {pin} AS builder\nFROM ubuntu:latest AS runtime\n", "the ubuntu base must be the Swift pin's distro"),
        ("dockerfile: an ubuntu runtime with no tag", f"FROM {pin} AS builder\nFROM ubuntu AS runtime\n", "the ubuntu base must be the Swift pin's distro"),
        ("dockerfile: a registry-qualified ubuntu runtime of another release",
         f"FROM {pin} AS builder\nFROM docker.io/library/ubuntu:22.04 AS runtime\n", "the ubuntu base must be the Swift pin's distro"),
    ]
    for name, text, want in docker_cases:
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            (d / "w.yml").write_text(GOOD, encoding="utf-8")
            errors = check(d, {"Dockerfile": text})
        ok = (not errors) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    # A Swift pin whose distro codename the check doesn't know can't be matched with an ubuntu base.
    with tempfile.TemporaryDirectory() as tmp:
        d = pathlib.Path(tmp)
        (d / "w.yml").write_text(GOOD.replace("6.2.4-noble@", "6.2.4-plucky@"), encoding="utf-8")
        errors = check(d, {"Dockerfile": f"FROM swift:6.2.4-plucky@sha256:{D} AS builder\nFROM ubuntu:25.04 AS runtime\n"})
    ok = any("doesn't know the distro of the Swift pin" in e for e in errors)
    print(f"{'ok  ' if ok else 'FAIL'} self-test: dockerfile: a Swift pin of an unknown distro" + ("" if ok else f": {errors}"))
    failed += not ok
    return failed


args = sys.argv[1:]
if args[:1] == ["--self-test"]:
    sys.exit(1 if self_test() else 0)
errors = check(pathlib.Path(args[0] if args else ".github/workflows"), tracked_dockerfiles())
for e in errors:
    print(f"::error::{e}")
sys.exit(1 if errors else 0)
PY
