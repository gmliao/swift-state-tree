#!/usr/bin/env bash
# Network impairment driver for ws-loadtest (Linux; needs root, iproute2 and ethtool).
#
# The topology: the load client in network namespace lt-client (and, for mixed populations,
# lt-good), a forwarding namespace lt-router, and the server in the caller's namespace:
#
#   [lt-client] veth-c0 -- veth-c1 [lt-router] veth-s1 -- veth-s0 [server ns, 10.200.0.1]
#   [lt-good]   veth-g0 -- veth-g1 [lt-router]
#
# Downstream (server -> client) is shaped on veth-c1's egress: netem (handle 1:) with a pfifo
# child. Upstream (client -> server) is shaped on veth-s1's egress: a 2-band prio whose
# unclassified traffic (ARP included) goes to the unshaped band 1:1, and a u32 filter that sends
# lt-client's source addresses to band 1:2, a netem (handle 20:) with a pfifo child. lt-good is
# never shaped. Neither TCP endpoint's own egress carries a netem.
#
# Usage:
#   impair.sh setup --limit-down N --limit-up N [--fifo-limit N] [--with-good]
#   impair.sh apply <profile> [--rate <tc rate>] --timeline <file>
#   impair.sh lift --timeline <file>
#   impair.sh schedule <profile> --at <epoch ms> --for <seconds> [--rate <tc rate>] --timeline <file>
#   impair.sh sample-backlog --out <file.jsonl> [--interval <s>]   (until SIGINT/SIGTERM)
#   impair.sh show
#   impair.sh teardown
#   impair.sh profiles
#
# Profiles change the qdiscs in place (`tc qdisc change`), never del or replace, so queued
# packets and counters survive the boundary. Lifting changes back to P0. Every change states every
# netem parameter (delay, jitter, loss, rate, limit): `tc qdisc change ... netem` resets the base
# ones it isn't given (limit to 1000) but keeps an optional one like `rate`, so a lift that omitted
# it kept the rate limit. After each change, the after-snapshot is checked against the profile
# (scripts/netem-check.mjs); a mismatch fails the run once its timeline entry is written.
#
# The timeline file is a JSON array; each apply and lift appends one entry: the profile, every
# command, the wall-clock time (ms since epoch) and the monotonic time (/proc/uptime, 10 ms
# resolution) before and after, and `tc -s qdisc` and `ethtool -k` output before and after.
#
# A lift also captures, after the before-snapshot and immediately before the change, `ss -tin` of every TCP socket in lt-client and of
# the server namespace's sockets to lt-client (10.201.0.0/24), with each socket's RTO and backoff,
# so a reconnect's downtime can be split into detection and backoff. At load that is megabytes, so
# it goes to a side file next to the timeline, `<timeline>-sockets-at-lift-<n>.txt` (n is the
# lowest number whose file doesn't exist yet, so no capture is overwritten); the entry names it (`socketsAtLiftFile`) with its size and the capture's
# own start and end (`socketsAtLiftWallMsStart`, `socketsAtLiftWallMsEnd`).
#
# A failure is loud: the script names the failing command and exits non-zero. In particular a
# change whose timeline entry can't be written fails after the change, saying when it ran.
#
# IMPAIR_DRY_RUN=1 prints the commands instead of running them (and fakes their output); with
# IMPAIR_TRACE=<file> it also appends each step's name to that file, in order (tests).
# IMPAIR_STATE (default /tmp/ws-loadtest-impair.state) keeps the setup's limits for later changes.
set -Eeuo pipefail
trap 'echo "impair.sh: failed (exit $?) at line $LINENO: $BASH_COMMAND" >&2' ERR

STATE_FILE="${IMPAIR_STATE:-/tmp/ws-loadtest-impair.state}"
DRY_RUN="${IMPAIR_DRY_RUN:-0}"

trace() {
  if [ -n "${IMPAIR_TRACE:-}" ]; then echo "$1" >> "$IMPAIR_TRACE"; fi
}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    trace "$*"
    echo "+ $*"
  else
    "$@"
  fi
}
R() { run ip netns exec lt-router "$@"; }

die() {
  echo "impair.sh: $*" >&2
  exit 1
}

# Upstream and downstream netem arguments of a profile (§ 3 of the impairment design), without
# the limit. RATE and COMBO need --rate (their fraction of P0's measured downstream, as a tc rate).
profile_args() {
  local profile="$1" rate="${2:-}"
  # netem SPEC: delay, jitter (or ""), loss %, rate ("0bit": none).
  spec() { local d="delay $1${2:+ $2} loss $3% rate $4"; echo "$d"; }
  case "$profile" in
    P0) UP="$(spec 0ms "" 0 0bit)"; DOWN="$(spec 0ms "" 0 0bit)" ;;
    # The slow-reader population: its namespace stays at P0 (the clients pause their reads), but
    # the timeline names SR, so the analysis applies SR's criteria to the pause.
    SR) UP="$(spec 0ms "" 0 0bit)"; DOWN="$(spec 0ms "" 0 0bit)" ;;
    D50) UP="$(spec 50ms "" 0 0bit)"; DOWN="$(spec 50ms "" 0 0bit)" ;;
    D50J10) UP="$(spec 50ms 10ms 0 0bit)"; DOWN="$(spec 50ms 10ms 0 0bit)" ;;
    L1) UP="$(spec 25ms "" 1 0bit)"; DOWN="$(spec 25ms "" 1 0bit)" ;;
    L5) UP="$(spec 25ms "" 5 0bit)"; DOWN="$(spec 25ms "" 5 0bit)" ;;
    ASYM) UP="$(spec 10ms "" 0 0bit)"; DOWN="$(spec 80ms "" 1 0bit)" ;;
    COMBO)
      [ -n "$rate" ] || die "COMBO needs --rate (0.8 x P0 downstream)"
      UP="$(spec 40ms 10ms 1 0bit)"; DOWN="$(spec 40ms 10ms 1 "$rate")" ;;
    # COMBO's delay, jitter and loss without its rate: calibrates COMBO's delay (design § 1).
    COMBO_NORATE) UP="$(spec 40ms 10ms 1 0bit)"; DOWN="$(spec 40ms 10ms 1 0bit)" ;;
    RATE)
      [ -n "$rate" ] || die "RATE needs --rate (0.5 x P0 downstream)"
      UP="$(spec 0ms "" 0 0bit)"; DOWN="$(spec 0ms "" 0 "$rate")" ;;
    BO10 | BO45 | BO75) UP="$(spec 0ms "" 100 0bit)"; DOWN="$(spec 0ms "" 100 0bit)" ;;
    *) die "unknown profile '$profile' (see: impair.sh profiles)" ;;
  esac
}

load_state() {
  [ -f "$STATE_FILE" ] || die "no state in $STATE_FILE: run setup first"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [ -n "${LIMIT_DOWN:-}" ] && [ -n "${LIMIT_UP:-}" ] || die "$STATE_FILE has no limits"
}

now_ms() {
  if [ "$DRY_RUN" = "1" ]; then echo "${IMPAIR_FAKE_NOW_MS:-0}"; else date +%s%3N; fi
}
mono_s() {
  if [ "$DRY_RUN" = "1" ]; then echo "0.00"; else cut -d' ' -f1 /proc/uptime; fi
}

sockets_at_lift() {
  if [ "$DRY_RUN" = "1" ]; then
    trace "sockets"
    echo "+ ip netns exec lt-client ss -tin"
    echo "+ ss -tin dst 10.201.0.0/24"
    # Tests size the capture like a loaded run's (IMPAIR_FAKE_SOCKETS_BYTES).
    if [ -n "${IMPAIR_FAKE_SOCKETS_BYTES:-}" ]; then
      head -c "$IMPAIR_FAKE_SOCKETS_BYTES" /dev/zero | tr '\0' 's'
      echo
    fi
    return
  fi
  echo "== lt-client: ss -tin"
  ip netns exec lt-client ss -tin
  echo "== server namespace: ss -tin dst 10.201.0.0/24"
  ss -tin dst 10.201.0.0/24
}

snapshot() {
  if [ "$DRY_RUN" = "1" ]; then
    trace "snapshot"
    echo "(dry run)"
    return
  fi
  for dev in veth-c1 veth-s1 veth-g1; do
    if ip netns exec lt-router ip link show "$dev" >/dev/null 2>&1; then
      echo "== tc -s qdisc show dev $dev"
      ip netns exec lt-router tc -s qdisc show dev "$dev"
      echo "== ethtool -k $dev"
      ip netns exec lt-router ethtool -k "$dev" | grep -E 'tcp-segmentation-offload|generic-(segmentation|receive)-offload'
    fi
  done
  echo "== tc -s filter show dev veth-s1"
  ip netns exec lt-router tc -s filter show dev veth-s1
}

# Appends one entry to the timeline's JSON array (node writes the JSON, so quoting is safe). Each
# value goes through a file, never argv: a snapshot at load can exceed the kernel's argument limit.
append_timeline() {
  local file="$1" values
  shift
  values="$(mktemp -d)"
  local i=0
  while [ $# -gt 0 ]; do
    i=$((i + 1))
    printf '%s' "$1" > "$values/$i.key"
    printf '%s' "$2" > "$values/$i.value"
    shift 2
  done
  # shellcheck disable=SC2016  # the single-quoted program is JavaScript, not shell
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [file, dir, count] = process.argv.slice(1);
    const NUMERIC = new Set(["wallMsBefore", "wallMsAfter", "monoSBefore", "monoSAfter",
      "socketsAtLiftBytes", "socketsAtLiftWallMsStart", "socketsAtLiftWallMsEnd"]);
    const entry = {};
    for (let i = 1; i <= Number(count); i++) {
      const key = fs.readFileSync(path.join(dir, `${i}.key`), "utf8");
      const value = fs.readFileSync(path.join(dir, `${i}.value`), "utf8");
      entry[key] = NUMERIC.has(key) ? Number(value) : value;
    }
    entry.commands = entry.commands ? entry.commands.split("\n").filter(Boolean) : [];
    const list = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : [];
    list.push(entry);
    fs.writeFileSync(file, JSON.stringify(list, null, 2) + "\n");
  ' "$file" "$values" "$i"
  local status=$?
  rm -rf "$values"
  return "$status"
}

# A side file for the lift's socket capture that doesn't exist yet. Numbered by the files, not by
# the timeline's entries: a lift whose entry failed still keeps its capture.
sockets_file_for() {
  local timeline="$1" n=1
  while [ -e "${timeline%.json}-sockets-at-lift-$n.txt" ]; do n=$((n + 1)); done
  echo "${timeline%.json}-sockets-at-lift-$n.txt"
}

change_to() {
  local profile="$1" rate="$2" timeline="$3" action="$4"
  [ -n "$timeline" ] || die "$action needs --timeline <file>"
  load_state
  profile_args "$profile" "$rate"
  local down_cmd="tc qdisc change dev veth-c1 root handle 1: netem $DOWN limit $LIMIT_DOWN"
  local up_cmd="tc qdisc change dev veth-s1 parent 1:2 handle 20: netem $UP limit $LIMIT_UP"
  local before_snapshot after_snapshot wall_before mono_before wall_after mono_after
  local sockets_file="" sockets_start="" sockets_end="" sockets_bytes=""
  before_snapshot="$(snapshot)"
  # The sockets last before the change: their RTO and backoff drift fastest.
  if [ "$action" = "lift" ]; then
    sockets_file="$(sockets_file_for "$timeline")"
    sockets_start="$(now_ms)"
    sockets_at_lift > "$sockets_file" || die "lift: the socket capture to $sockets_file failed; nothing was changed"
    sockets_end="$(now_ms)"
    sockets_bytes="$(wc -c < "$sockets_file" | tr -d ' ')"
    [ "$DRY_RUN" = "1" ] && grep '^+ ' "$sockets_file"
  fi
  wall_before="$(now_ms)"; mono_before="$(mono_s)"
  # shellcheck disable=SC2086
  R $down_cmd
  # shellcheck disable=SC2086
  R $up_cmd
  wall_after="$(now_ms)"; mono_after="$(mono_s)"
  after_snapshot="$(snapshot)"
  # Dry runs check a dump from the tests (IMPAIR_FAKE_AFTER_DUMP), when given.
  if [ "$DRY_RUN" = "1" ] && [ -n "${IMPAIR_FAKE_AFTER_DUMP:-}" ]; then after_snapshot="$(cat "$IMPAIR_FAKE_AFTER_DUMP")"; fi
  local check_file check_status=0 check_out=""
  if [ "$DRY_RUN" != "1" ] || [ -n "${IMPAIR_FAKE_AFTER_DUMP:-}" ]; then
    check_file="$(mktemp)"
    printf '%s\n' "$after_snapshot" > "$check_file"
    check_out="$(node "$(dirname "$0")/netem-check.mjs" --dump "$check_file" --down "$DOWN" --up "$UP" \
      --limit-down "$LIMIT_DOWN" --limit-up "$LIMIT_UP" 2>&1)" || check_status=$?
    rm -f "$check_file"
  fi
  local extra=()
  if [ -n "$sockets_file" ]; then
    extra=(socketsAtLiftFile "$(basename "$sockets_file")" socketsAtLiftBytes "$sockets_bytes"
      socketsAtLiftWallMsStart "$sockets_start" socketsAtLiftWallMsEnd "$sockets_end")
  fi
  append_timeline "$timeline" \
    action "$action" profile "$profile" \
    commands "ip netns exec lt-router $down_cmd
ip netns exec lt-router $up_cmd" \
    wallMsBefore "$wall_before" monoSBefore "$mono_before" \
    wallMsAfter "$wall_after" monoSAfter "$mono_after" \
    before "$before_snapshot" after "$after_snapshot" ${extra[@]+"${extra[@]}"} \
    || die "$action $profile ran at $wall_after (ms since epoch), but its entry could not be written to $timeline"
  [ "$check_status" = 0 ] || die "$action $profile at $wall_after: the qdiscs don't show the profile:
$check_out"
  echo "impair.sh: $action $profile at $wall_after"
}

cmd_setup() {
  local limit_down="" limit_up="" fifo_limit="" with_good=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit-down) limit_down="$2"; shift 2 ;;
      --limit-up) limit_up="$2"; shift 2 ;;
      --fifo-limit) fifo_limit="$2"; shift 2 ;;
      --with-good) with_good=true; shift ;;
      *) die "setup: unknown option $1" ;;
    esac
  done
  [[ "$limit_down" =~ ^[0-9]+$ ]] && [[ "$limit_up" =~ ^[0-9]+$ ]] || die "setup needs --limit-down N and --limit-up N (netem packets; design § 1)"
  fifo_limit="${fifo_limit:-$(( limit_down > limit_up ? limit_down : limit_up ))}"

  for pair in sch_netem:NET_SCH_NETEM sch_prio:NET_SCH_PRIO cls_u32:NET_CLS_U32; do
    local m=${pair%%:*} opt=${pair#*:}
    # awk reads to the end: grep -q would exit at the match, zcat would get SIGPIPE, and pipefail
    # would turn the match into a failure, skipping this check.
    if [ "$DRY_RUN" != "1" ] && [ -r /proc/config.gz ] && zcat /proc/config.gz | awk -v re="^CONFIG_$opt=m" '$0 ~ re {found = 1} END {exit !found}' && ! grep -q "^$m " /proc/modules; then
      die "module $m is not loaded (modprobe -a sch_netem sch_prio cls_u32; it doesn't survive a WSL restart)"
    fi
  done

  run ip netns add lt-client
  run ip netns add lt-router
  run ip link add veth-s0 type veth peer name veth-s1
  run ip link set veth-s1 netns lt-router
  run ip link add veth-c0 type veth peer name veth-c1
  run ip link set veth-c0 netns lt-client
  run ip link set veth-c1 netns lt-router
  run ip addr add 10.200.0.1/24 dev veth-s0
  run ip link set veth-s0 up
  R ip addr add 10.200.0.2/24 dev veth-s1
  R ip addr add 10.201.0.1/24 dev veth-c1
  R ip link set veth-s1 up
  R ip link set veth-c1 up
  R ip link set lo up
  R sysctl -qw net.ipv4.ip_forward=1
  run ip netns exec lt-client ip addr add 10.201.0.2/24 dev veth-c0
  run ip netns exec lt-client ip link set veth-c0 up
  run ip netns exec lt-client ip link set lo up
  run ip netns exec lt-client ip route add default via 10.201.0.1
  run ip route add 10.201.0.0/24 via 10.200.0.2
  run ethtool -K veth-s0 tso off gso off gro off
  R ethtool -K veth-s1 tso off gso off gro off
  R ethtool -K veth-c1 tso off gso off gro off
  run ip netns exec lt-client ethtool -K veth-c0 tso off gso off gro off
  if [ "$with_good" = true ]; then
    run ip netns add lt-good
    run ip link add veth-g0 type veth peer name veth-g1
    run ip link set veth-g0 netns lt-good
    run ip link set veth-g1 netns lt-router
    R ip addr add 10.202.0.1/24 dev veth-g1
    R ip link set veth-g1 up
    run ip netns exec lt-good ip addr add 10.202.0.2/24 dev veth-g0
    run ip netns exec lt-good ip link set veth-g0 up
    run ip netns exec lt-good ip link set lo up
    run ip netns exec lt-good ip route add default via 10.202.0.1
    run ip route add 10.202.0.0/24 via 10.200.0.2
    R ethtool -K veth-g1 tso off gso off gro off
    run ip netns exec lt-good ethtool -K veth-g0 tso off gso off gro off
  fi

  # Downstream: netem + pfifo child on lt-client's veth; a pfifo only on lt-good's.
  R tc qdisc add dev veth-c1 root handle 1: netem delay 0ms limit "$limit_down"
  R tc qdisc add dev veth-c1 parent 1:1 pfifo limit "$fifo_limit"
  if [ "$with_good" = true ]; then
    R tc qdisc add dev veth-g1 root pfifo limit "$fifo_limit"
  fi
  # Upstream: unclassified traffic to the unshaped band 1:1; lt-client's sources to netem 1:2.
  R tc qdisc add dev veth-s1 root handle 1: prio bands 2 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  R tc qdisc add dev veth-s1 parent 1:1 handle 10: pfifo limit "$fifo_limit"
  R tc qdisc add dev veth-s1 parent 1:2 handle 20: netem delay 0ms limit "$limit_up"
  R tc qdisc add dev veth-s1 parent 20:1 pfifo limit "$fifo_limit"
  R tc filter add dev veth-s1 parent 1: protocol ip prio 1 u32 match ip src 10.201.0.0/24 flowid 1:2
  R tc filter add dev veth-s1 parent 1: protocol ip prio 1 u32 match ip src 10.202.0.0/24 flowid 1:1

  printf 'LIMIT_DOWN=%s\nLIMIT_UP=%s\nFIFO_LIMIT=%s\nWITH_GOOD=%s\n' "$limit_down" "$limit_up" "$fifo_limit" "$with_good" > "$STATE_FILE"
  echo "impair.sh: set up (limits: down $limit_down, up $limit_up, fifo $fifo_limit; lt-good: $with_good)"
}

cmd_teardown() {
  run ip route del 10.201.0.0/24 via 10.200.0.2 2>/dev/null || true
  run ip route del 10.202.0.0/24 via 10.200.0.2 2>/dev/null || true
  for ns in lt-client lt-good lt-router; do run ip netns del "$ns" 2>/dev/null || true; done
  run ip link del veth-s0 2>/dev/null || true
  rm -f "$STATE_FILE"
  echo "impair.sh: torn down"
}

parse_change_opts() {
  RATE_OPT=""; TIMELINE=""; AT=""; FOR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rate) RATE_OPT="$2"; shift 2 ;;
      --timeline) TIMELINE="$2"; shift 2 ;;
      --at) AT="$2"; shift 2 ;;
      --for) FOR="$2"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
}

sleep_until_ms() {
  local target="$1" now
  now="$(now_ms)"
  if [ "$target" -le "$now" ]; then
    die "--at $target is already past ($now)"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "+ sleep until $target"
    return
  fi
  sleep "$(awk -v d="$(( target - now ))" 'BEGIN { printf "%.3f", d / 1000 }')"
}

cmd_sample_backlog() {
  local out="" interval=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      *) die "sample-backlog: unknown option $1" ;;
    esac
  done
  [ -n "$out" ] || die "sample-backlog needs --out <file.jsonl>"
  local stop=false
  trap 'stop=true' INT TERM
  while [ "$stop" = false ]; do
    # One line per sample: the time, and each shaped netem's backlog and counters.
    local t lines
    t="$(now_ms)"
    lines="$(ip netns exec lt-router tc -s qdisc show dev veth-c1; ip netns exec lt-router tc -s qdisc show dev veth-s1)"
    node -e '
      const [t, text] = process.argv.slice(1);
      const qdiscs = [];
      let current;
      for (const line of text.split("\n")) {
        const head = /^qdisc (\S+) (\S+) (?:root|parent (\S+))/.exec(line);
        if (head) { current = { kind: head[1], handle: head[2], parent: head[3] ?? "root" }; qdiscs.push(current); continue; }
        if (!current) continue;
        const sent = /Sent (\d+) bytes (\d+) pkt \(dropped (\d+), overlimits (\d+) requeues (\d+)\)/.exec(line);
        if (sent) Object.assign(current, { sentBytes: +sent[1], sentPackets: +sent[2], dropped: +sent[3], overlimits: +sent[4] });
        const backlog = /backlog (\d+)b (\d+)p/.exec(line);
        if (backlog) Object.assign(current, { backlogBytes: +backlog[1], backlogPackets: +backlog[2] });
      }
      console.log(JSON.stringify({ t: Number(t), qdiscs }));
    ' "$t" "$lines" >> "$out"
    sleep "$interval" & wait $! || true
  done
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  setup) cmd_setup "$@" ;;
  teardown) cmd_teardown ;;
  apply)
    profile="${1:-}"; [ -n "$profile" ] || die "apply needs a profile"; shift
    parse_change_opts "$@"
    change_to "$profile" "$RATE_OPT" "$TIMELINE" apply ;;
  lift)
    parse_change_opts "$@"
    change_to P0 "" "$TIMELINE" lift ;;
  schedule)
    profile="${1:-}"; [ -n "$profile" ] || die "schedule needs a profile"; shift
    parse_change_opts "$@"
    [[ "$AT" =~ ^[0-9]+$ ]] && [[ "$FOR" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "schedule needs --at <epoch ms> and --for <seconds>"
    profile_args "$profile" "$RATE_OPT"   # fail before waiting
    sleep_until_ms "$AT"
    change_to "$profile" "$RATE_OPT" "$TIMELINE" apply
    sleep_until_ms "$(awk -v a="$AT" -v f="$FOR" 'BEGIN { printf "%d", a + f * 1000 }')"
    change_to P0 "" "$TIMELINE" lift ;;
  sample-backlog) cmd_sample_backlog "$@" ;;
  show) snapshot ;;
  profiles) echo "P0 D50 D50J10 L1 L5 ASYM COMBO(--rate) COMBO_NORATE RATE(--rate) BO10 BO45 BO75 SR" ;;
  *) sed -n '2,32p' "$0"; [ -z "$command" ] || die "unknown command '$command'" ;;
esac
