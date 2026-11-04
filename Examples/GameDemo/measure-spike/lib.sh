#!/bin/bash
# Shared helpers. MEASURE_ROOT holds the worktrees base/ spike/ variant/ (see setup.sh).
: "${MEASURE_ROOT:?set MEASURE_ROOT to the directory with the base/ spike/ variant/ worktrees}"
M=$MEASURE_ROOT
S=$M/base/Examples/GameDemo/measure-spike      # these scripts
WS=$M/base/Examples/GameDemo/ws-loadtest        # load client (built by setup.sh)
R=${MEASURE_RESULTS:-$M/results}
[ "$(uname)" = Darwin ] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

port_pid() {  # pid listening on :8080
  if command -v lsof >/dev/null; then lsof -tiTCP:8080 -sTCP:LISTEN | head -1
  else ss -ltnpH 'sport = :8080' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2; fi
}
kill_port() { local p; p=$(port_pid); [ -n "$p" ] && kill -9 $p 2>/dev/null; sleep 1; }
cpu_seconds() {  # cumulative user+sys CPU seconds of a pid
  if [ -r /proc/$1/stat ]; then awk -v hz=$(getconf CLK_TCK) '{print ($14+$15)/hz}' /proc/$1/stat
  else ps -p $1 -o time= | tr -d ' ' | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else if (NF==3) print $1*60+$2+$3/100; else print $1 }'; fi
}
tcp_stats() {  # kernel TCP counters (listen overflows, resets, drops)
  if [ "$(uname)" = Darwin ]; then netstat -s -p tcp; else nstat -az 2>/dev/null || cat /proc/net/netstat /proc/net/snmp; fi
}
cpusample() {  # cpusample <out> <server-pid>: every 1 s "epoch serverCpuS nodeWorkersCpuS"
  local out=$1 spid=$2 s n v p
  while kill -0 $spid 2>/dev/null; do
    s=$(cpu_seconds $spid); n=0
    for p in $(pgrep -f "dist/[w]orker-runner.js"); do v=$(cpu_seconds $p 2>/dev/null); n=$(awk "BEGIN{print $n+${v:-0}}"); done
    echo "$(date +%s) $s $n" >> $out; sleep 1
  done
}
