#!/usr/bin/env bash
# Typechecks each snippet in scripts/must-not-compile/ against the built debug modules and
# checks the outcome its first line names:
#   // expect: compiles               the snippet must typecheck (a control for the setup)
#   // expect-error: <text>           typechecking must fail with a diagnostic containing <text>
# Prelude.swift is compiled with every snippet. Run after `swift build` (debug) from the repo
# root, or pass the build directory: scripts/check-must-not-compile.sh [.build/debug]
set -euo pipefail

cd "$(dirname "$0")/.."
build_dir="${1:-$(swift build --show-bin-path)}"
snippets_dir="scripts/must-not-compile"
prelude="$snippets_dir/Prelude.swift"

if [[ ! -d "$build_dir/SwiftStateTree.swiftmodule" && ! -f "$build_dir/Modules/SwiftStateTree.swiftmodule" ]]; then
    echo "check-must-not-compile: no SwiftStateTree module in $build_dir; run swift build first" >&2
    exit 2
fi
macro_tool="$build_dir/SwiftStateTreeMacros"
if [[ ! -x "$macro_tool" ]]; then
    macro_tool="$build_dir/SwiftStateTreeMacros-tool"
fi
if [[ ! -x "$macro_tool" ]]; then
    echo "check-must-not-compile: no macro executable in $build_dir" >&2
    exit 2
fi

flags=(-typecheck -I "$build_dir" -load-plugin-executable "$macro_tool#SwiftStateTreeMacros")
if [[ -d "$build_dir/Modules" ]]; then
    flags+=(-I "$build_dir/Modules")
fi
# C targets' module maps (dependencies such as swift-nio's), so their modules resolve. Only C
# targets', and only the target builds': on Linux the host builds for the macro tool
# (`*-tool.build`) hold a second copy of each, and a Swift target's build holds a module map for
# its generated header; passing either redefines the module.
while IFS= read -r -d '' modulemap; do
    target="${modulemap#"$build_dir"/}"
    target="${target%%.build/*}"
    if [[ -e "$build_dir/$target.swiftmodule" || -e "$build_dir/Modules/$target.swiftmodule" ]]; then
        continue
    fi
    flags+=(-Xcc "-fmodule-map-file=$modulemap")
done < <(find "$build_dir" -maxdepth 3 -name module.modulemap -not -path '*-tool.build/*' -print0)

failures=0
count=0
for snippet in "$snippets_dir"/*.swift; do
    [[ "$snippet" == "$prelude" ]] && continue
    count=$((count + 1))
    header="$(head -n 1 "$snippet")"
    set +e
    output="$(swiftc "${flags[@]}" "$prelude" "$snippet" 2>&1)"
    status=$?
    set -e
    name="$(basename "$snippet")"
    case "$header" in
        "// expect: compiles")
            if [[ $status -ne 0 ]]; then
                echo "FAIL $name: expected to compile, got:"
                echo "$output" | grep -E "error:" | head -5
                failures=$((failures + 1))
            else
                echo "ok   $name compiles"
            fi
            ;;
        "// expect-error: "*)
            expected="${header#// expect-error: }"
            if [[ $status -eq 0 ]]; then
                echo "FAIL $name: compiled, expected an error containing: $expected"
                failures=$((failures + 1))
            elif ! grep -F -q -- "$expected" <<<"$output"; then
                echo "FAIL $name: failed without the expected error ($expected); got:"
                echo "$output" | grep -E "error:" | head -5
                failures=$((failures + 1))
            else
                echo "ok   $name refused: $expected"
            fi
            ;;
        *)
            echo "FAIL $name: its first line names no expectation"
            failures=$((failures + 1))
            ;;
    esac
done

if [[ $failures -ne 0 ]]; then
    echo "check-must-not-compile: $failures of $count snippets failed"
    exit 1
fi
echo "check-must-not-compile: $count snippets as expected"
