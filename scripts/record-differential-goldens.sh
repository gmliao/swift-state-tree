#!/usr/bin/env bash
# Records the differential harness's goldens (#555): builds once in the pinned CI image, runs the
# harness in five separate processes, checks each candidate set, compares the five byte for byte,
# and publishes into Tests/SwiftStateTreeNIOTests/Differential/Golden only when all five agree.
# Otherwise it writes nothing there.
#
# Five processes, not one: Swift seeds hashing per process, so an order over a dictionary or a
# set agrees within one process and can differ between two. Five miss a two-key dependency one
# time in sixteen; every later CI run is one more fresh process compared with the goldens.
#
# The goldens are recorded at a commit: the tree must be clean, and the commit is stored in
# each file. Commit the code first, run this, then commit only the golden folder, naming the
# code commit.
#
# Usage: scripts/record-differential-goldens.sh            # runs itself in the pinned image
#        scripts/record-differential-goldens.sh --inside   # already in it (CI, the devcontainer)
set -euo pipefail
cd "$(dirname "$0")/.."

GOLDEN=Tests/SwiftStateTreeNIOTests/Differential/Golden
RUNS=5
FILTER='SwiftStateTreeNIOTests\.DifferentialHarnessTests'

# The pinned image, read from the CI workflow, so the two can't name different images.
image() {
    sed -n '/^ *image: *swift:[^ ]*@sha256:[0-9a-f]\{64\}/{s/^ *image: *\(swift:[^ ]*@sha256:[0-9a-f]\{64\}\).*/\1/p;q;}' .github/workflows/build-and-test.yml
}

if [[ "${1:-}" != "--inside" ]]; then
    IMAGE=$(image)
    [[ -n "$IMAGE" ]] || { echo "record-differential-goldens: no pinned image in build-and-test.yml" >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "record-differential-goldens: the tree isn't clean; commit the code first" >&2; exit 1; }
    echo "record-differential-goldens: running in $IMAGE (linux/amd64)"
    exec docker run --rm --platform linux/amd64 \
        -v "$PWD":/work -w /work \
        -v sst-differential-golden-build:/build \
        -e SST_RECORD_IMAGE="$IMAGE" \
        "$IMAGE" scripts/record-differential-goldens.sh --inside
fi

if [[ -n "${SWIFT_DETERMINISTIC_HASHING:-}" ]]; then
    echo "record-differential-goldens: SWIFT_DETERMINISTIC_HASHING is set; it would hide a hash-order dependency" >&2
    exit 1
fi
if [[ "${SST_DIFFERENTIAL_VERIFY:-}" == "1" ]]; then
    echo "record-differential-goldens: refused under SST_DIFFERENTIAL_VERIFY=1" >&2
    exit 1
fi

command -v python3 >/dev/null || scripts/ci-apt-install.sh python3
git config --global --add safe.directory "$PWD" 2>/dev/null || true
[[ -z "$(git status --porcelain)" ]] || { echo "record-differential-goldens: the tree isn't clean; commit the code first" >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)
SWIFT_VERSION=$(swift --version 2>&1)
TOOLCHAIN="$(uname -sm) ${SWIFT_VERSION%%$'\n'*}"
SCRATCH=${SST_RECORD_SCRATCH:-/build}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "record-differential-goldens: commit $COMMIT"
echo "record-differential-goldens: toolchain $TOOLCHAIN"
swift build --build-tests --scratch-path "$SCRATCH"

for i in $(seq 1 "$RUNS"); do
    out="$WORK/run$i"
    rm -rf "$out" && mkdir -p "$out"
    echo "record-differential-goldens: run $i of $RUNS"
    if ! SST_UPDATE_GOLDEN=1 SST_GOLDEN_OUT="$out" SST_TOOLCHAIN="$TOOLCHAIN" SST_GOLDEN_COMMIT="$COMMIT" \
        swift test --skip-build --scratch-path "$SCRATCH" --filter "$FILTER" > "$WORK/run$i.log" 2>&1; then
        tail -40 "$WORK/run$i.log"
        echo "record-differential-goldens: run $i failed; nothing published" >&2
        exit 1
    fi
done

# Each set: exactly the index's files (the harness checked each decoded view against its bytes
# and the oracle before writing).
python3 - "$WORK" "$RUNS" <<'PY'
import json, pathlib, sys
work, runs = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for i in range(1, runs + 1):
    folder = work / f"run{i}"
    index = json.loads((folder / "index.json").read_text())["files"]
    present = sorted(p.name for p in folder.glob("*.json") if p.name != "index.json")
    if present != sorted(index):
        missing = sorted(set(index) - set(present))
        extra = sorted(set(present) - set(index))
        sys.exit(f"record-differential-goldens: run {i}: missing {missing}, extra {extra}; nothing published")
PY

# The five sets, byte for byte; a difference names the file and its first differing field.
for i in $(seq 2 "$RUNS"); do
    if ! diff -rq "$WORK/run1" "$WORK/run$i" > "$WORK/diff$i.txt"; then
        python3 - "$WORK/run1" "$WORK/run$i" "$i" <<'PY'
import json, pathlib, sys
a, b, run = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
def first(x, y, path=""):
    if type(x) != type(y):
        return path or "<root>"
    if isinstance(x, dict):
        for k in sorted(set(x) | set(y)):
            if k not in x or k not in y:
                return f"{path}.{k}"
            found = first(x[k], y[k], f"{path}.{k}")
            if found:
                return found
        return None
    if isinstance(x, list):
        if len(x) != len(y):
            return f"{path} (length {len(x)} vs {len(y)})"
        for n, (l, r) in enumerate(zip(x, y)):
            found = first(l, r, f"{path}[{n}]")
            if found:
                return found
        return None
    return None if x == y else path
for f in sorted(a.glob("*.json")):
    g = b / f.name
    if not g.exists() or f.read_bytes() != g.read_bytes():
        where = first(json.loads(f.read_text()), json.loads(g.read_text())) if g.exists() else "<missing>"
        print(f"record-differential-goldens: run 1 and run {run} differ in {f.name} at {where}")
PY
        echo "record-differential-goldens: the runs differ; nothing published" >&2
        exit 1
    fi
done

rm -f "$GOLDEN"/*.json
mkdir -p "$GOLDEN"
cp "$WORK"/run1/*.json "$GOLDEN"/
COUNT=$(find "$GOLDEN" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
SIZE=$(du -sk "$GOLDEN" | cut -f1)
echo "record-differential-goldens: published $COUNT files (${SIZE} KB) recorded at $COMMIT; commit only $GOLDEN"
