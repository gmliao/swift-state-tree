#!/usr/bin/env bash
# Tests for scripts/ci-apt-install.sh against stub apt-get and dpkg commands on PATH, with the
# bounds and the waits shortened. A stub's behaviour per call comes from a script of lines, one
# per call: `ok`, `fail` (exit 100, a mirror error) or `hang` (sleeps far past the bound, #659).
# Usage: scripts/test-ci-apt-install.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

mkdir -p "$tmp/bin"
cat > "$tmp/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$APT_STUB_DIR/calls") + 1 ))
echo "$n" > "$APT_STUB_DIR/calls"
echo "apt-get $*" >> "$APT_STUB_DIR/log"
case "$(sed -n "${n}p" "$APT_STUB_DIR/plan")" in
  ok) exit 0 ;;
  hang) exec sleep 600 ;;
  *) exit 100 ;;
esac
STUB
cat > "$tmp/bin/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >> "$APT_STUB_DIR/log"
STUB
chmod +x "$tmp/bin/apt-get" "$tmp/bin/dpkg"

case_() {  # name, expected exit, plan (one word per apt-get call), expected dpkg runs, max seconds
  local name=$1 want=$2 plan=$3 dpkgs=$4 limit=$5 dir="$tmp/$1" rc=0 start elapsed runs
  mkdir -p "$dir" && echo 0 > "$dir/calls" && : > "$dir/log"
  tr ' ' '\n' <<<"$plan" > "$dir/plan"
  start=$SECONDS
  APT_STUB_DIR="$dir" PATH="$tmp/bin:$PATH" CI_APT_UPDATE_TIMEOUT=1 CI_APT_INSTALL_TIMEOUT=1 CI_APT_RETRY_DELAY=0 \
    bash "$root/scripts/ci-apt-install.sh" curl > "$dir/out" 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  runs=$(grep -c '^dpkg --configure -a$' "$dir/log")
  if [ "$rc" = "$want" ] && [ "$runs" = "$dpkgs" ] && [ "$elapsed" -le "$limit" ]; then
    echo "ok   $name (exit $rc, ${elapsed} s)"
  else
    echo "FAIL $name: exit $rc (wanted $want), dpkg --configure runs $runs (wanted $dpkgs), ${elapsed} s (limit $limit)"
    sed 's/^/     /' "$dir/log" "$dir/out"; fail=1
  fi
}

case_ first-attempt-ok 0 "ok ok" 0 3
case_ mirror-error-then-ok 0 "fail ok ok" 1 3
case_ update-hangs-then-ok 0 "hang ok ok" 1 15
case_ install-hangs-then-ok 0 "ok hang ok ok" 1 15
case_ every-attempt-hangs 1 "hang hang hang hang hang" 4 60

# No package: usage, and no apt-get call.
dir="$tmp/no-package-args"; mkdir -p "$dir" && echo 0 > "$dir/calls" && : > "$dir/log" && : > "$dir/plan"
rc=0; APT_STUB_DIR="$dir" PATH="$tmp/bin:$PATH" bash "$root/scripts/ci-apt-install.sh" > /dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ] && [ "$(cat "$dir/calls")" = 0 ]; then echo "ok   usage without a package (exit 2, no apt-get)"; else echo "FAIL usage without a package: exit $rc"; fail=1; fi
exit $fail
