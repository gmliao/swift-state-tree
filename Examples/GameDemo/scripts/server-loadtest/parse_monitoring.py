#!/usr/bin/env python3
"""
Parse vmstat/pidstat monitoring output and convert to JSON format.
"""

import csv
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, List, Any, Optional


def parse_vmstat_log(vmstat_path: Path) -> List[Dict[str, Any]]:
    """Parse vmstat output (Linux) or top output (macOS) and return list of samples."""
    if not vmstat_path.exists():
        return []

    samples = []

    # Try to detect format by reading first few lines
    with open(vmstat_path, 'r') as f:
        first_lines = [f.readline().strip() for _ in range(5)]
        f.seek(0)

        # Check if it's macOS top output (contains "CPU usage:" or "PhysMem:")
        is_macos_top = any(
            "CPU usage:" in line or "PhysMem:" in line for line in first_lines)
        # Check if it's macOS iostat output (contains "cpu" and "load average" in header, or "us sy id" in column header)
        is_macos_iostat = any(
            ("cpu" in line.lower() and "load average" in line.lower()) or
            ("KB/t" in line and ("us" in line or "sy" in line))
            for line in first_lines
        )

        if is_macos_top:
            return parse_macos_top_log(vmstat_path)
        elif is_macos_iostat:
            return parse_macos_iostat_log(vmstat_path)

    # Linux vmstat format
    header_found = False
    header_line = None

    with open(vmstat_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('procs') or line.startswith('r'):
                # Header line - extract column names
                if 'procs' in line or line.startswith('r'):
                    header_line = line
                    header_found = True
                continue

            if not header_found:
                continue

            # Parse data line
            parts = line.split()
            if len(parts) < 17:  # vmstat has many columns
                continue

            try:
                # vmstat format: r b swpd free buff cache si so bi bo in cs us sy id wa st gu
                sample = {
                    "procs_r": int(parts[0]) if parts[0].isdigit() else 0,
                    "procs_b": int(parts[1]) if parts[1].isdigit() else 0,
                    "memory_swpd_kb": int(parts[2]) if parts[2].isdigit() else 0,
                    "memory_free_kb": int(parts[3]) if parts[3].isdigit() else 0,
                    "memory_buff_kb": int(parts[4]) if parts[4].isdigit() else 0,
                    "memory_cache_kb": int(parts[5]) if parts[5].isdigit() else 0,
                    "swap_si_kb": int(parts[6]) if parts[6].isdigit() else 0,
                    "swap_so_kb": int(parts[7]) if parts[7].isdigit() else 0,
                    "io_bi_kb": int(parts[8]) if parts[8].isdigit() else 0,
                    "io_bo_kb": int(parts[9]) if parts[9].isdigit() else 0,
                    "system_in": int(parts[10]) if parts[10].isdigit() else 0,
                    "system_cs": int(parts[11]) if parts[11].isdigit() else 0,
                    "cpu_us_pct": float(parts[12]) if parts[12].replace('.', '').isdigit() else 0.0,
                    "cpu_sy_pct": float(parts[13]) if parts[13].replace('.', '').isdigit() else 0.0,
                    "cpu_id_pct": float(parts[14]) if parts[14].replace('.', '').isdigit() else 0.0,
                    "cpu_wa_pct": float(parts[15]) if len(parts) > 15 and parts[15].replace('.', '').isdigit() else 0.0,
                    "cpu_st_pct": float(parts[16]) if len(parts) > 16 and parts[16].replace('.', '').isdigit() else 0.0,
                }
                if len(parts) > 17:
                    sample["cpu_gu_pct"] = float(parts[17]) if parts[17].replace(
                        '.', '').isdigit() else 0.0
                samples.append(sample)
            except (ValueError, IndexError):
                continue

    return samples


def parse_macos_top_log(top_path: Path) -> List[Dict[str, Any]]:
    """Parse macOS top output and return list of samples in vmstat-compatible format."""
    samples = []
    current_sample = {}

    with open(top_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                # Empty line might indicate end of a sample block
                if current_sample and "cpu_us_pct" in current_sample:
                    samples.append(current_sample)
                    current_sample = {}
                continue

            # Parse CPU usage line: "CPU usage: 12.34% user, 5.67% sys, 82.00% idle"
            if "CPU usage:" in line:
                try:
                    # Extract percentages
                    import re
                    cpu_match = re.search(
                        r'(\d+\.?\d*)%\s+user.*?(\d+\.?\d*)%\s+sys.*?(\d+\.?\d*)%\s+idle', line)
                    if cpu_match:
                        cpu_us = float(cpu_match.group(1))
                        cpu_sy = float(cpu_match.group(2))
                        cpu_id = float(cpu_match.group(3))
                        current_sample["cpu_us_pct"] = cpu_us
                        current_sample["cpu_sy_pct"] = cpu_sy
                        current_sample["cpu_id_pct"] = cpu_id
                        # macOS top doesn't show wait
                        current_sample["cpu_wa_pct"] = 0.0
                        # macOS top doesn't show steal
                        current_sample["cpu_st_pct"] = 0.0
                except (ValueError, AttributeError):
                    continue

            # Parse memory line: "PhysMem: 8192M used, 8192M free, 16384M wired, 0M compressed"
            elif "PhysMem:" in line:
                try:
                    import re
                    # Extract free memory (in MB, convert to KB)
                    mem_match = re.search(r'(\d+)M\s+free', line)
                    if mem_match:
                        free_mb = int(mem_match.group(1))
                        current_sample["memory_free_kb"] = free_mb * 1024
                        # Also set other memory fields to 0 for compatibility
                        current_sample["memory_swpd_kb"] = 0
                        current_sample["memory_buff_kb"] = 0
                        current_sample["memory_cache_kb"] = 0
                except (ValueError, AttributeError):
                    continue

            # When we see "Processes:" line, it might be start of new sample
            # But we'll use empty lines as delimiters instead

    # Add last sample if exists
    if current_sample and "cpu_us_pct" in current_sample:
        samples.append(current_sample)

    return samples


def parse_macos_iostat_log(iostat_path: Path) -> List[Dict[str, Any]]:
    """Parse macOS iostat output and return list of samples in vmstat-compatible format.

    macOS iostat format:
        disk0       cpu    load average
    KB/t  tps  MB/s  us sy id   1m   5m   15m
    4.49 4596 20.15  14 11 74  4.34 3.85 3.82
    """
    samples = []
    header_found = False
    column_header_found = False

    with open(iostat_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            # Look for main header: "disk0       cpu    load average"
            if "cpu" in line.lower() and "load average" in line.lower():
                header_found = True
                continue

            if not header_found:
                continue

            # Look for column header: "KB/t  tps  MB/s  us sy id   1m   5m   15m"
            if header_found and ("KB/t" in line or "tps" in line) and ("us" in line or "sy" in line):
                column_header_found = True
                continue

            if not column_header_found:
                continue

            # Parse data line: "4.49 4596 20.15  14 11 74  4.34 3.85 3.82"
            parts = line.split()
            if len(parts) < 6:
                continue

            try:
                # iostat format: [KB/t] [tps] [MB/s] [us] [sy] [id] [1m] [5m] [15m]
                # CPU columns are at positions 3, 4, 5 (0-indexed)
                cpu_us = float(parts[3])
                cpu_sy = float(parts[4])
                cpu_id = float(parts[5])

                sample = {
                    "cpu_us_pct": cpu_us,
                    "cpu_sy_pct": cpu_sy,
                    "cpu_id_pct": cpu_id,
                    "cpu_wa_pct": 0.0,  # macOS iostat doesn't show wait
                    "cpu_st_pct": 0.0,  # macOS iostat doesn't show steal
                    # Set memory fields to 0 (iostat doesn't provide memory info)
                    "memory_free_kb": 0,
                    "memory_swpd_kb": 0,
                    "memory_buff_kb": 0,
                    "memory_cache_kb": 0,
                }
                samples.append(sample)
            except (ValueError, IndexError):
                continue

    return samples


def parse_macos_ps_csv(ps_path: Path) -> List[Dict[str, Any]]:
    """Parse macOS ps CSV output and return list of samples in pidstat-compatible format."""
    if not ps_path.exists():
        return []

    samples = []
    with open(ps_path, 'r') as f:
        reader = csv.reader(f)
        rows = list(reader)

    if not rows:
        return []

    header = [c.strip().lower() for c in rows[0]]
    has_header = any("cpu" in c for c in header) or any(
        "timestamp" in c for c in header)
    start_idx = 1 if has_header else 0

    # Default column order for non-header CSV: timestamp_epoch_s,cpu_pct,pid
    if has_header:
        header_map = {name: idx for idx, name in enumerate(header)}
        ts_idx = header_map.get("timestamp_epoch_s",
                                header_map.get("timestamp", 0))
        cpu_idx = header_map.get("cpu_pct", header_map.get(
            "%cpu", header_map.get("cpu", 1)))
        pid_idx = header_map.get("pid", 2)
    else:
        ts_idx = 0
        cpu_idx = 1
        pid_idx = 2

    for row in rows[start_idx:]:
        if len(row) <= max(ts_idx, cpu_idx, pid_idx):
            continue
        try:
            ts_raw = row[ts_idx].strip()
            cpu_raw = row[cpu_idx].strip()
            pid_raw = row[pid_idx].strip()

            cpu_val = float(cpu_raw.replace(",", ".")) if cpu_raw else 0.0
            pid_val = int(pid_raw) if pid_raw.isdigit() else 0
            ts_val = int(float(ts_raw)) if ts_raw else 0

            samples.append({
                "pid": pid_val,
                "cpu_total_pct": cpu_val,
                "timestamp_epoch_s": ts_val,
            })
        except (ValueError, IndexError):
            continue

    return samples


def parse_pidstat_log(pidstat_path: Path, process_name: str = "ServerLoadTest") -> List[Dict[str, Any]]:
    """Parse pidstat output and return list of samples for the target process."""
    if not pidstat_path.exists():
        return []

    # macOS ps CSV format detection
    try:
        with open(pidstat_path, 'r') as f:
            first_line = f.readline().strip()
        if "," in first_line and "PID" not in first_line and "Average" not in first_line:
            return parse_macos_ps_csv(pidstat_path)
    except Exception:
        pass

    samples = []
    header_found = False

    with open(pidstat_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            # Look for header
            if 'PID' in line and 'CPU' in line:
                header_found = True
                continue

            if not header_found:
                continue

            # Parse data line - pidstat format varies, try to match process name
            if process_name.lower() not in line.lower():
                continue

            parts = line.split()
            if len(parts) < 8:
                continue

            try:
                # pidstat format: Time PID %usr %system %guest %CPU CPU Command
                # Or: Time UID PID %usr %system %guest %wait %CPU CPU Command
                sample = {
                    "pid": int(parts[1]) if parts[1].isdigit() else 0,
                    "cpu_usr_pct": float(parts[2]) if parts[2].replace('.', '').isdigit() else 0.0,
                    "cpu_system_pct": float(parts[3]) if parts[3].replace('.', '').isdigit() else 0.0,
                    "cpu_guest_pct": float(parts[4]) if len(parts) > 4 and parts[4].replace('.', '').isdigit() else 0.0,
                    "cpu_total_pct": float(parts[5]) if len(parts) > 5 and parts[5].replace('.', '').isdigit() else 0.0,
                }
                # Try to extract memory if available (pidstat -r adds RSS column)
                if len(parts) > 6:
                    # Check if next field looks like memory (large number)
                    if parts[6].isdigit() and int(parts[6]) > 1000:
                        sample["memory_rss_kb"] = int(parts[6])
                samples.append(sample)
            except (ValueError, IndexError):
                continue

    return samples


def calculate_steady_stats(test_samples: list) -> Optional[Dict[str, Any]]:
    """計算穩定狀態的統計數據"""
    if not test_samples:
        return None

    steady_samples = [s for s in test_samples if s.get('phase') == 'steady']
    if not steady_samples:
        return None

    count = len(steady_samples)

    avg_sent_bps = sum(s.get('sentBytesPerSecond', 0)
                       for s in steady_samples) / count
    avg_recv_bps = sum(s.get('recvBytesPerSecond', 0)
                       for s in steady_samples) / count
    avg_sent_mps = sum(s.get('sentMessagesPerSecond', 0)
                       for s in steady_samples) / count
    avg_recv_mps = sum(s.get('recvMessagesPerSecond', 0)
                       for s in steady_samples) / count
    avg_actions = sum(s.get('actionsSentThisSecond', 0)
                      for s in steady_samples) / count

    avg_ticks_per_sec = sum(s.get('estimatedTicksPerSecond', 0)
                            for s in steady_samples) / count
    avg_syncs_per_sec = sum(s.get('estimatedSyncsPerSecond', 0)
                            for s in steady_samples) / count
    avg_updates_per_sec = sum(s.get('estimatedUpdatesPerSecond', 0)
                              for s in steady_samples) / count
    avg_msg_size = sum(s.get('avgMessageSize', 0)
                       for s in steady_samples) / count

    avg_update_time_ms = (
        1000.0 / avg_updates_per_sec) if avg_updates_per_sec > 0 else 0
    avg_tick_time_ms = (
        1000.0 / avg_ticks_per_sec) if avg_ticks_per_sec > 0 else 0
    avg_sync_time_ms = (
        1000.0 / avg_syncs_per_sec) if avg_syncs_per_sec > 0 else 0

    return {
        "sample_count": count,
        "avg_sent_bps": avg_sent_bps,
        "avg_recv_bps": avg_recv_bps,
        "avg_sent_mps": avg_sent_mps,
        "avg_recv_mps": avg_recv_mps,
        "avg_actions": avg_actions,
        "avg_ticks_per_sec": avg_ticks_per_sec,
        "avg_syncs_per_sec": avg_syncs_per_sec,
        "avg_updates_per_sec": avg_updates_per_sec,
        "avg_msg_size": avg_msg_size,
        "avg_update_time_ms": avg_update_time_ms,
        "avg_tick_time_ms": avg_tick_time_ms,
        "avg_sync_time_ms": avg_sync_time_ms
    }


def prepare_vmstat_chart_data(vmstat_samples: list) -> Dict[str, list]:
    """準備 vmstat 圖表數據"""
    if not vmstat_samples:
        return {}

    return {
        "times": list(range(len(vmstat_samples))),
        "cpu_us": [s.get("cpu_us_pct", 0) for s in vmstat_samples],
        "cpu_sy": [s.get("cpu_sy_pct", 0) for s in vmstat_samples],
        "cpu_id": [s.get("cpu_id_pct", 0) for s in vmstat_samples],
        "memory_free": [s.get("memory_free_kb", 0) / 1024.0 for s in vmstat_samples]
    }


def prepare_pidstat_chart_data(pidstat_samples: list) -> Dict[str, list]:
    """準備 pidstat 圖表數據"""
    if not pidstat_samples:
        return {}

    return {
        "times": list(range(len(pidstat_samples))),
        "cpu": [s.get("cpu_total_pct", 0) for s in pidstat_samples]
    }


def prepare_game_chart_data(test_samples: list) -> Dict[str, list]:
    """準備遊戲數據圖表"""
    if not test_samples:
        return {}

    tick_interval_ms = 50
    ticks_per_second = 1000.0 / tick_interval_ms

    ticks = [int(s.get("t", 0) * ticks_per_second) for s in test_samples]

    return {
        "ticks": ticks,
        "bytes_sent_kb": [s.get("sentBytesPerSecond", 0) / 1024.0 for s in test_samples],
        "bytes_recv_kb": [s.get("recvBytesPerSecond", 0) / 1024.0 for s in test_samples],
        "messages_sent": [s.get("sentMessagesPerSecond", 0) for s in test_samples],
        "messages_recv": [s.get("recvMessagesPerSecond", 0) for s in test_samples],
        "actions": [s.get("actionsSentThisSecond", 0) for s in test_samples],
        "active_players": [s.get("playersActiveExpected", 0) for s in test_samples],
        "active_rooms": [s.get("roomsActiveExpected", 0) for s in test_samples],
        "ticks_per_second": [s.get("estimatedTicksPerSecond", 0) for s in test_samples],
        "syncs_per_second": [s.get("estimatedSyncsPerSecond", 0) for s in test_samples],
        "updates_per_second": [s.get("estimatedUpdatesPerSecond", 0) for s in test_samples],
        "update_times_ms": [
            (1000.0 / s.get("estimatedUpdatesPerSecond", 1)
             ) if s.get("estimatedUpdatesPerSecond", 0) > 0 else 0
            for s in test_samples
        ],
        "avg_message_size_kb": [s.get("avgMessageSize", 0) / 1024.0 for s in test_samples]
    }


def prepare_template_data(
    data: Dict[str, Any],
    test_result_json: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """準備模板所需的數據"""
    vmstat_samples = data.get("vmstat", [])
    pidstat_samples = data.get("pidstat", [])
    vmstat_summary = data.get("vmstat_summary", {})
    pidstat_summary = data.get("pidstat_summary", {})
    cpu_cores = data.get("cpu_cores", 1)

    # Prepare data for charts
    vmstat_times = list(range(len(vmstat_samples)))
    vmstat_cpu_us = [s.get("cpu_us_pct", 0) for s in vmstat_samples]
    vmstat_cpu_sy = [s.get("cpu_sy_pct", 0) for s in vmstat_samples]
    vmstat_cpu_id = [s.get("cpu_id_pct", 0) for s in vmstat_samples]
    vmstat_memory_free = [
        # Convert to MB
        s.get("memory_free_kb", 0) / 1024.0 for s in vmstat_samples]

    pidstat_times = list(range(len(pidstat_samples)))
    pidstat_cpu = [s.get("cpu_total_pct", 0) for s in pidstat_samples]

    # 提取測試配置和結果
    test_config = {}
    test_metadata = {}
    test_samples = []
    steady_stats = None

    if test_result_json:
        test_metadata = test_result_json.get("metadata", {})
        test_config = test_metadata.get("loadTestConfig", {})
        results = test_result_json.get("results", {})
        test_samples = results.get("seconds", [])

        # 計算穩定狀態統計
        steady_stats = calculate_steady_stats(test_samples)

    # 準備圖表數據
    chart_data = {
        "vmstat": prepare_vmstat_chart_data(vmstat_samples),
        "pidstat": prepare_pidstat_chart_data(pidstat_samples),
        "game": prepare_game_chart_data(test_samples)
    }

    return {
        "test_config": test_config,
        "test_metadata": test_metadata,
        "vmstat_summary": vmstat_summary,
        "pidstat_summary": pidstat_summary,
        "cpu_cores": cpu_cores,
        "steady_stats": steady_stats,
        "chart_data": chart_data
    }


def build_report_payload(
    data: Dict[str, Any], test_result_json: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """Build the single JSON payload for the report template.
    Template reads this and renders all sections/charts; Python only injects this JSON.
    """
    tpl = prepare_template_data(data, test_result_json)
    vmstat_summary = tpl["vmstat_summary"]
    pidstat_summary = tpl["pidstat_summary"]
    test_config = tpl["test_config"]
    test_metadata = tpl["test_metadata"]
    steady_stats = tpl["steady_stats"]
    chart_data = tpl["chart_data"]

    results = (test_result_json or {}).get("results", {})
    test_samples = results.get("seconds", [])
    run_summary = results.get("summary", {}) if isinstance(results.get("summary"), dict) else {}

    phase_breakdown = {}
    if test_samples:
        phase_breakdown = dict(Counter(s.get("phase", "unknown") for s in test_samples))

    game_summary = None
    tick_interval_ms = 50
    ticks_per_second = 1000.0 / tick_interval_ms
    if chart_data.get("game"):
        g = chart_data["game"]
        ticks = g.get("ticks", [])
        bytes_sent_kb = g.get("bytes_sent_kb", [])
        messages_sent = g.get("messages_sent", [])
        actions = g.get("actions", [])
        game_summary = {
            "total_ticks": ticks[-1] if ticks else 0,
            "tick_interval_ms": tick_interval_ms,
            "ticks_per_second": ticks_per_second,
            "peak_ingress_kb": (max(bytes_sent_kb) if bytes_sent_kb else 0),
            "peak_msgs": (max(messages_sent) if messages_sent else 0),
            "peak_actions": (max(actions) if actions else 0),
        }
        # Add series used by "All Game Metrics" chart
        rooms_created = [s.get("roomsCreated", 0) for s in test_samples]
        rooms_target = [s.get("roomsTarget", 0) for s in test_samples]
        chart_data = dict(chart_data)
        chart_data["game"] = dict(g, rooms_created=rooms_created, rooms_target=rooms_target)

    return {
        "metadata": test_metadata,
        "run_summary": run_summary,
        "phase_breakdown": phase_breakdown,
        "config": test_config,
        "env": test_metadata.get("environment", {}),
        "steady_stats": steady_stats,
        "vmstat_summary": vmstat_summary,
        "pidstat_summary": pidstat_summary or {},
        "charts": chart_data,
        "game_summary": game_summary,
        "test_result": test_result_json,
        "monitoring": data,
    }


def generate_html_report(data: Dict[str, Any], output_path: Path, test_result_json: Optional[Dict[str, Any]] = None) -> None:
    """Generate HTML report by injecting the report payload into the template.
    Only replaces {{REPORT_DATA}} in the template; template renders from that JSON.
    Open the template file directly in a browser to see default/sample data.
    """
    payload = build_report_payload(data, test_result_json)
    json_str = json.dumps(payload, ensure_ascii=False, indent=2)
    # Avoid </script> in JSON breaking the HTML script tag
    json_str = json_str.replace("</script>", "<\\/script>")

    script_dir = Path(__file__).parent
    template_path = script_dir / "monitoring_report_template.html"
    html = template_path.read_text(encoding="utf-8").replace("{{REPORT_DATA}}", json_str)
    output_path.write_text(html, encoding="utf-8")



def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(
        description="Parse vmstat/pidstat logs and convert to JSON/HTML")
    ap.add_argument("--vmstat", type=Path,
                    help="vmstat log file path (raw text or JSON)")
    ap.add_argument("--pidstat", type=Path,
                    help="pidstat log file path (raw text or JSON)")
    ap.add_argument("--monitoring-json", type=Path,
                    help="Pre-parsed monitoring JSON file (contains vmstat/pidstat)")
    ap.add_argument("--output", type=Path, help="Output JSON file path")
    ap.add_argument("--html", type=Path, help="Output HTML report file path")
    ap.add_argument("--test-result-json", type=Path,
                    help="Test result JSON file to embed in HTML report")
    ap.add_argument("--process-name", default="ServerLoadTest",
                    help="Process name to filter in pidstat")
    ap.add_argument("--cpu-cores", type=int, default=1,
                    help="Number of CPU cores for normalization")

    args = ap.parse_args()

    result: Dict[str, Any] = {
        "vmstat": [],
        "pidstat": [],
        "cpu_cores": args.cpu_cores,
    }

    # If monitoring-json is provided, load it directly
    if args.monitoring_json:
        try:
            with open(args.monitoring_json, 'r') as f:
                monitoring_data = json.load(f)
            result["vmstat"] = monitoring_data.get("vmstat", [])
            result["pidstat"] = monitoring_data.get("pidstat", [])
            print(f"Loaded monitoring data from JSON: {args.monitoring_json}")
        except Exception as e:
            print(
                f"Warning: Failed to load monitoring JSON: {e}", file=sys.stderr)
    else:
        # Otherwise, parse from raw log files
        if args.vmstat:
            # Try to detect if it's JSON or raw text
            try:
                with open(args.vmstat, 'r') as f:
                    first_char = f.read(1)
                    f.seek(0)
                    if first_char == '{':
                        # JSON format
                        data = json.load(f)
                        result["vmstat"] = data.get("vmstat", [])
                        print(f"Loaded vmstat from JSON: {args.vmstat}")
                    else:
                        # Raw text format
                        result["vmstat"] = parse_vmstat_log(args.vmstat)
            except Exception as e:
                print(f"Warning: Failed to parse vmstat: {e}", file=sys.stderr)

        if args.pidstat:
            # Try to detect if it's JSON or raw text
            try:
                with open(args.pidstat, 'r') as f:
                    first_char = f.read(1)
                    f.seek(0)
                    if first_char == '{':
                        # JSON format
                        data = json.load(f)
                        result["pidstat"] = data.get("pidstat", [])
                        print(f"Loaded pidstat from JSON: {args.pidstat}")
                    else:
                        # Raw text format
                        result["pidstat"] = parse_pidstat_log(
                            args.pidstat, args.process_name)
            except Exception as e:
                print(
                    f"Warning: Failed to parse pidstat: {e}", file=sys.stderr)

    # Calculate summary statistics
    if result["vmstat"]:
        vmstat_samples = result["vmstat"]
        result["vmstat_summary"] = {
            "sample_count": len(vmstat_samples),
            "avg_cpu_us_pct": sum(s["cpu_us_pct"] for s in vmstat_samples) / len(vmstat_samples) if vmstat_samples else 0.0,
            "avg_cpu_sy_pct": sum(s["cpu_sy_pct"] for s in vmstat_samples) / len(vmstat_samples) if vmstat_samples else 0.0,
            "avg_cpu_id_pct": sum(s["cpu_id_pct"] for s in vmstat_samples) / len(vmstat_samples) if vmstat_samples else 0.0,
            "peak_memory_free_kb": min(s["memory_free_kb"] for s in vmstat_samples) if vmstat_samples else 0,
        }

    if result["pidstat"]:
        pidstat_samples = result["pidstat"]
        result["pidstat_summary"] = {
            "sample_count": len(pidstat_samples),
            "avg_cpu_total_pct": sum(s["cpu_total_pct"] for s in pidstat_samples) / len(pidstat_samples) if pidstat_samples else 0.0,
            "peak_cpu_total_pct": max(s["cpu_total_pct"] for s in pidstat_samples) if pidstat_samples else 0.0,
        }

    output_json = json.dumps(result, indent=2)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output_json)
        print(f"Monitoring data saved to: {args.output}")

    if args.html:
        args.html.parent.mkdir(parents=True, exist_ok=True)

        # Load test result JSON if provided
        test_result_data = None
        if args.test_result_json and args.test_result_json.exists():
            try:
                with open(args.test_result_json, 'r') as f:
                    test_result_data = json.load(f)
                print(f"Loaded test result JSON from: {args.test_result_json}")
            except Exception as e:
                print(
                    f"Warning: Failed to load test result JSON: {e}", file=sys.stderr)

        generate_html_report(result, args.html, test_result_data)
        print(f"HTML report saved to: {args.html}")

    if not args.output and not args.html:
        print(output_json)

    return 0


if __name__ == "__main__":
    sys.exit(main())
