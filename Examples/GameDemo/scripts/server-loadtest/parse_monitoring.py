#!/usr/bin/env python3
"""
Parse vmstat/pidstat monitoring output and convert to JSON format.
"""

import csv
import json
import re
import sys
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
        is_macos_top = any("CPU usage:" in line or "PhysMem:" in line for line in first_lines)
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
                    sample["cpu_gu_pct"] = float(parts[17]) if parts[17].replace('.', '').isdigit() else 0.0
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
                    cpu_match = re.search(r'(\d+\.?\d*)%\s+user.*?(\d+\.?\d*)%\s+sys.*?(\d+\.?\d*)%\s+idle', line)
                    if cpu_match:
                        cpu_us = float(cpu_match.group(1))
                        cpu_sy = float(cpu_match.group(2))
                        cpu_id = float(cpu_match.group(3))
                        current_sample["cpu_us_pct"] = cpu_us
                        current_sample["cpu_sy_pct"] = cpu_sy
                        current_sample["cpu_id_pct"] = cpu_id
                        current_sample["cpu_wa_pct"] = 0.0  # macOS top doesn't show wait
                        current_sample["cpu_st_pct"] = 0.0  # macOS top doesn't show steal
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
    has_header = any("cpu" in c for c in header) or any("timestamp" in c for c in header)
    start_idx = 1 if has_header else 0

    # Default column order for non-header CSV: timestamp_epoch_s,cpu_pct,pid
    if has_header:
        header_map = {name: idx for idx, name in enumerate(header)}
        ts_idx = header_map.get("timestamp_epoch_s", header_map.get("timestamp", 0))
        cpu_idx = header_map.get("cpu_pct", header_map.get("%cpu", header_map.get("cpu", 1)))
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


def generate_html_report(data: Dict[str, Any], output_path: Path, test_result_json: Optional[Dict[str, Any]] = None) -> None:
    """Generate an interactive HTML report with charts for monitoring data.
    
    Args:
        data: Monitoring data (vmstat, pidstat)
        output_path: Path to save HTML report
        test_result_json: Optional test result JSON data to embed in report
    """
    vmstat_samples = data.get("vmstat", [])
    pidstat_samples = data.get("pidstat", [])
    vmstat_summary = data.get("vmstat_summary", {})
    pidstat_summary = data.get("pidstat_summary", {})
    
    # Prepare data for charts
    vmstat_times = list(range(len(vmstat_samples)))
    vmstat_cpu_us = [s.get("cpu_us_pct", 0) for s in vmstat_samples]
    vmstat_cpu_sy = [s.get("cpu_sy_pct", 0) for s in vmstat_samples]
    vmstat_cpu_id = [s.get("cpu_id_pct", 0) for s in vmstat_samples]
    vmstat_memory_free = [s.get("memory_free_kb", 0) / 1024.0 for s in vmstat_samples]  # Convert to MB
    
    pidstat_times = list(range(len(pidstat_samples)))
    pidstat_cpu = [s.get("cpu_total_pct", 0) for s in pidstat_samples]
    
    # Extract test config and results if available
    test_config = {}
    test_samples = []
    test_metadata = {}
    if test_result_json:
        test_metadata = test_result_json.get("metadata", {})
        test_config = test_metadata.get("loadTestConfig", {})
        # Samples are in results.seconds (not top-level samples)
        results = test_result_json.get("results", {})
        test_samples = results.get("seconds", [])
    
    # Prepare game data (tick-based) if available
    # Hero-defense runs at 20Hz (50ms per tick), so tick = time_seconds * 20
    # For other games, this can be adjusted via config
    tick_interval_ms = 50  # Default for hero-defense (can be extracted from config if available)
    ticks_per_second = 1000.0 / tick_interval_ms
    
    game_ticks = []
    game_bytes_sent = []
    game_bytes_recv = []
    game_messages_sent = []
    game_messages_recv = []
    game_actions = []
    game_active_players = []
    game_active_rooms = []
    game_rooms_created = []
    game_rooms_target = []
    # Performance metrics
    game_estimated_ticks_per_second = []
    game_estimated_syncs_per_second = []
    game_estimated_updates_per_second = []
    game_avg_message_size = []
    game_phases = []
    
    if test_samples:
        for sample in test_samples:
            time_sec = sample.get("t", 0)
            tick = int(time_sec * ticks_per_second)
            game_ticks.append(tick)
            game_bytes_sent.append(sample.get("sentBytesPerSecond", 0))
            game_bytes_recv.append(sample.get("recvBytesPerSecond", 0))
            game_messages_sent.append(sample.get("sentMessagesPerSecond", 0))
            game_messages_recv.append(sample.get("recvMessagesPerSecond", 0))
            game_actions.append(sample.get("actionsSentThisSecond", 0))
            game_active_players.append(sample.get("playersActiveExpected", 0))
            game_active_rooms.append(sample.get("roomsActiveExpected", 0))
            game_rooms_created.append(sample.get("roomsCreated", 0))
            game_rooms_target.append(sample.get("roomsTarget", 0))
            # Performance metrics
            game_estimated_ticks_per_second.append(sample.get("estimatedTicksPerSecond", 0))
            game_estimated_syncs_per_second.append(sample.get("estimatedSyncsPerSecond", 0))
            game_estimated_updates_per_second.append(sample.get("estimatedUpdatesPerSecond", 0))
            game_avg_message_size.append(sample.get("avgMessageSize", 0))
            game_phases.append(sample.get("phase", "unknown"))
    
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Load Test - System Monitoring Report</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 20px;
            background: #f5f5f5;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        h1 {{
            color: #333;
            border-bottom: 2px solid #4CAF50;
            padding-bottom: 10px;
        }}
        h2 {{
            color: #555;
            margin-top: 30px;
            font-size: 20px;
            border-bottom: 1px solid #ddd;
            padding-bottom: 8px;
        }}
        .summary {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }}
        .summary-card {{
            background: #f9f9f9;
            padding: 15px;
            border-radius: 6px;
            border-left: 4px solid #4CAF50;
        }}
        .summary-card h3 {{
            margin: 0 0 10px 0;
            color: #666;
            font-size: 14px;
            text-transform: uppercase;
        }}
        .summary-card .value {{
            font-size: 24px;
            font-weight: bold;
            color: #333;
        }}
        .summary-card .subvalue {{
            font-size: 14px;
            color: #777;
            margin-top: 5px;
        }}
        .chart-container {{
            margin: 30px 0;
            position: relative;
            height: 300px;
        }}
        .chart-title {{
            font-size: 18px;
            font-weight: bold;
            margin-bottom: 10px;
            color: #333;
        }}
        .json-viewer {{
            background: #f8f8f8;
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 15px;
            margin: 15px 0;
            max-height: 400px;
            overflow-y: auto;
        }}
        .json-viewer pre {{
            margin: 0;
            font-family: 'Courier New', monospace;
            font-size: 12px;
            line-height: 1.5;
        }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Load Test - System Monitoring Report</h1>
"""
    
    # Add test configuration section if available
    if test_config:
        html_content += f"""
        <h2>📋 Test Configuration</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>Rooms</h3>
                <div class="value">{test_config.get('rooms', 'N/A')}</div>
            </div>
            <div class="summary-card">
                <h3>Players/Room</h3>
                <div class="value">{test_config.get('playersPerRoom', 'N/A')}</div>
            </div>
            <div class="summary-card">
                <h3>Total Players</h3>
                <div class="value">{test_config.get('rooms', 0) * test_config.get('playersPerRoom', 0)}</div>
            </div>
            <div class="summary-card">
                <h3>Test Duration</h3>
                <div class="value">{test_config.get('steadySeconds', 'N/A')}s</div>
                <div class="subvalue">+{test_config.get('rampUpSeconds', 0)}s ramp-up, +{test_config.get('rampDownSeconds', 0)}s ramp-down</div>
            </div>
            <div class="summary-card">
                <h3>Actions/Player/Sec</h3>
                <div class="value">{test_config.get('actionsPerPlayerPerSecond', 'N/A')}</div>
            </div>
            <div class="summary-card">
                <h3>Land Type</h3>
                <div class="value">{test_config.get('landType', 'N/A')}</div>
            </div>
        </div>
"""
    
    # Add system environment section if available
    if test_metadata:
        env = test_metadata.get("environment", {})
        if env:
            html_content += f"""
        <h2>💻 System Environment</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>OS</h3>
                <div class="value">{env.get('osName', 'N/A')}</div>
                <div class="subvalue">{env.get('kernelVersion', '')}</div>
            </div>
            <div class="summary-card">
                <h3>CPU Cores</h3>
                <div class="value">{env.get('cpuActiveLogicalCores', 'N/A')}</div>
                <div class="subvalue">{env.get('arch', '')} architecture</div>
            </div>
            <div class="summary-card">
                <h3>Total Memory</h3>
                <div class="value">{env.get('memoryTotalMB', 'N/A')} MB</div>
            </div>
        </div>
"""
    
    # Add test results section if available
    if test_samples:
        steady_samples = [s for s in test_samples if s.get('phase') == 'steady']
        if steady_samples:
            avg_sent_bps = sum(s.get('sentBytesPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_recv_bps = sum(s.get('recvBytesPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_sent_mps = sum(s.get('sentMessagesPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_recv_mps = sum(s.get('recvMessagesPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_actions = sum(s.get('actionsSentThisSecond', 0) for s in steady_samples) / len(steady_samples)
            
            # Performance metrics
            avg_ticks_per_sec = sum(s.get('estimatedTicksPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_syncs_per_sec = sum(s.get('estimatedSyncsPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_updates_per_sec = sum(s.get('estimatedUpdatesPerSecond', 0) for s in steady_samples) / len(steady_samples)
            avg_msg_size = sum(s.get('avgMessageSize', 0) for s in steady_samples) / len(steady_samples)
            
            # Calculate average update time (ms per update)
            # If we have N updates per second, each update takes 1000/N ms
            avg_update_time_ms = (1000.0 / avg_updates_per_sec) if avg_updates_per_sec > 0 else 0
            avg_tick_time_ms = (1000.0 / avg_ticks_per_sec) if avg_ticks_per_sec > 0 else 0
            avg_sync_time_ms = (1000.0 / avg_syncs_per_sec) if avg_syncs_per_sec > 0 else 0
            
            html_content += f"""
        <h2>📊 Test Results (Steady State)</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>Avg Send Rate</h3>
                <div class="value">{avg_sent_bps / 1024:.1f} KB/s</div>
                <div class="subvalue">{avg_sent_mps:.1f} msgs/s</div>
            </div>
            <div class="summary-card">
                <h3>Avg Recv Rate</h3>
                <div class="value">{avg_recv_bps / 1024:.1f} KB/s</div>
                <div class="subvalue">{avg_recv_mps:.1f} msgs/s</div>
            </div>
            <div class="summary-card">
                <h3>Avg Actions/Sec</h3>
                <div class="value">{avg_actions:.1f}</div>
            </div>
            <div class="summary-card">
                <h3>Steady Samples</h3>
                <div class="value">{len(steady_samples)}</div>
            </div>
        </div>
        
        <h2>⚡ Performance Metrics (Steady State)</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>Avg Ticks/Sec</h3>
                <div class="value">{avg_ticks_per_sec:,.0f}</div>
                <div class="subvalue">~{avg_tick_time_ms:.2f} ms/tick</div>
            </div>
            <div class="summary-card">
                <h3>Avg Syncs/Sec</h3>
                <div class="value">{avg_syncs_per_sec:,.0f}</div>
                <div class="subvalue">~{avg_sync_time_ms:.2f} ms/sync</div>
            </div>
            <div class="summary-card">
                <h3>Total Updates/Sec</h3>
                <div class="value">{avg_updates_per_sec:,.0f}</div>
                <div class="subvalue">~{avg_update_time_ms:.3f} ms/update</div>
            </div>
            <div class="summary-card">
                <h3>Avg Message Size</h3>
                <div class="value">{avg_msg_size:.0f} B</div>
                <div class="subvalue">{avg_msg_size/1024:.2f} KB</div>
            </div>
            <div class="summary-card">
                <h3>Update Rate</h3>
                <div class="value">{avg_update_time_ms:.2f} ms</div>
                <div class="subvalue">{"🟢 正常" if avg_update_time_ms < 10 else "🟡 稍慢" if avg_update_time_ms < 50 else "🟠 可能 lag"}</div>
            </div>
        </div>
"""
    
    html_content += f"""
        <h2>🖥️ System Monitoring</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>VMStat Samples</h3>
                <div class="value">{vmstat_summary.get('sample_count', 0)}</div>
            </div>
            <div class="summary-card">
                <h3>Avg CPU User %</h3>
                <div class="value">{vmstat_summary.get('avg_cpu_us_pct', 0):.1f}%</div>
            </div>
            <div class="summary-card">
                <h3>Avg CPU System %</h3>
                <div class="value">{vmstat_summary.get('avg_cpu_sy_pct', 0):.1f}%</div>
            </div>
            <div class="summary-card">
                <h3>Avg CPU Idle %</h3>
                <div class="value">{vmstat_summary.get('avg_cpu_id_pct', 0):.1f}%</div>
            </div>
"""
    
    if pidstat_summary:
        html_content += f"""
            <div class="summary-card">
                <h3>PidStat Samples</h3>
                <div class="value">{pidstat_summary.get('sample_count', 0)}</div>
            </div>
            <div class="summary-card">
                <h3>Avg Process CPU %</h3>
                <div class="value">{pidstat_summary.get('avg_cpu_total_pct', 0):.1f}%</div>
            </div>
            <div class="summary-card">
                <h3>Peak Process CPU %</h3>
                <div class="value">{pidstat_summary.get('peak_cpu_total_pct', 0):.1f}%</div>
            </div>
"""
    
    html_content += """
        </div>
"""
    
    if vmstat_samples:
        vmstat_times_json = json.dumps(vmstat_times)
        vmstat_cpu_us_json = json.dumps(vmstat_cpu_us)
        vmstat_cpu_sy_json = json.dumps(vmstat_cpu_sy)
        vmstat_cpu_id_json = json.dumps(vmstat_cpu_id)
        vmstat_memory_free_json = json.dumps(vmstat_memory_free)
        
        html_content += f"""
        <div class="chart-container">
            <div class="chart-title">System CPU Usage Over Time</div>
            <canvas id="cpuChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Free Memory Over Time (MB)</div>
            <canvas id="memoryChart"></canvas>
        </div>
        
        <script>
            const cpuCtx = document.getElementById('cpuChart').getContext('2d');
            new Chart(cpuCtx, {{
                type: 'line',
                data: {{
                    labels: {vmstat_times_json},
                    datasets: [
                        {{
                            label: 'User %',
                            data: {vmstat_cpu_us_json},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.2)',
                            tension: 0.1
                        }},
                        {{
                            label: 'System %',
                            data: {vmstat_cpu_sy_json},
                            borderColor: 'rgb(255, 99, 132)',
                            backgroundColor: 'rgba(255, 99, 132, 0.2)',
                            tension: 0.1
                        }},
                        {{
                            label: 'Idle %',
                            data: {vmstat_cpu_id_json},
                            borderColor: 'rgb(153, 102, 255)',
                            backgroundColor: 'rgba(153, 102, 255, 0.2)',
                            tension: 0.1
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{
                            beginAtZero: true,
                            max: 100
                        }}
                    }}
                }}
            }});
            
            const memoryCtx = document.getElementById('memoryChart').getContext('2d');
            new Chart(memoryCtx, {{
                type: 'line',
                data: {{
                    labels: {vmstat_times_json},
                    datasets: [{{
                        label: 'Free Memory (MB)',
                        data: {vmstat_memory_free_json},
                        borderColor: 'rgb(54, 162, 235)',
                        backgroundColor: 'rgba(54, 162, 235, 0.2)',
                        tension: 0.1
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{
                            beginAtZero: true
                        }}
                    }}
                }}
            }});
        </script>
"""
    
    if pidstat_samples:
        pidstat_times_json = json.dumps(pidstat_times)
        pidstat_cpu_json = json.dumps(pidstat_cpu)
        
        html_content += f"""
        <div class="chart-container">
            <div class="chart-title">Process CPU Usage Over Time</div>
            <canvas id="pidstatChart"></canvas>
        </div>
        
        <script>
            const pidstatCtx = document.getElementById('pidstatChart').getContext('2d');
            new Chart(pidstatCtx, {{
                type: 'line',
                data: {{
                    labels: {pidstat_times_json},
                    datasets: [{{
                        label: 'Process CPU %',
                        data: {pidstat_cpu_json},
                        borderColor: 'rgb(255, 159, 64)',
                        backgroundColor: 'rgba(255, 159, 64, 0.2)',
                        tension: 0.1
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        y: {{
                            beginAtZero: true
                        }}
                    }}
                }}
            }});
        </script>
"""
    
    # Add game data charts (tick-based) if available
    if game_ticks and len(game_ticks) > 0:
        game_ticks_json = json.dumps(game_ticks)
        game_bytes_sent_kb = [b / 1024.0 for b in game_bytes_sent]
        game_bytes_sent_json = json.dumps(game_bytes_sent_kb)
        game_bytes_recv_kb = [b / 1024.0 for b in game_bytes_recv]
        game_bytes_recv_json = json.dumps(game_bytes_recv_kb)
        game_messages_sent_json = json.dumps(game_messages_sent)
        game_messages_recv_json = json.dumps(game_messages_recv)
        game_actions_json = json.dumps(game_actions)
        game_active_players_json = json.dumps(game_active_players)
        game_active_rooms_json = json.dumps(game_active_rooms)
        game_rooms_created_json = json.dumps(game_rooms_created)
        game_rooms_target_json = json.dumps(game_rooms_target)
        
        # Performance metrics JSON
        game_estimated_ticks_per_second_json = json.dumps(game_estimated_ticks_per_second)
        game_estimated_syncs_per_second_json = json.dumps(game_estimated_syncs_per_second)
        game_estimated_updates_per_second_json = json.dumps(game_estimated_updates_per_second)
        game_avg_message_size_json = json.dumps([s / 1024.0 for s in game_avg_message_size])  # Convert to KB
        
        # Calculate update times (ms)
        game_update_times_ms = []
        for updates_per_sec in game_estimated_updates_per_second:
            if updates_per_sec > 0:
                game_update_times_ms.append(1000.0 / updates_per_sec)
            else:
                game_update_times_ms.append(0)
        game_update_times_ms_json = json.dumps(game_update_times_ms)
        
        peak_bytes = max(game_bytes_sent) if game_bytes_sent else 0
        peak_messages = max(game_messages_sent) if game_messages_sent else 0
        peak_actions = max(game_actions) if game_actions else 0
        
        html_content += f"""
        <h2>🎮 Game Data (Tick-based)</h2>
        <div class="summary">
            <div class="summary-card">
                <h3>Total Ticks</h3>
                <div class="value">{game_ticks[-1] if game_ticks else 0}</div>
                <div class="subvalue">{tick_interval_ms}ms per tick ({ticks_per_second:.1f} Hz)</div>
            </div>
            <div class="summary-card">
                <h3>Peak Bytes/Sec</h3>
                <div class="value">{peak_bytes / 1024:.1f} KB/s</div>
            </div>
            <div class="summary-card">
                <h3>Peak Messages/Sec</h3>
                <div class="value">{peak_messages:.1f}</div>
            </div>
            <div class="summary-card">
                <h3>Peak Actions/Sec</h3>
                <div class="value">{peak_actions:.0f}</div>
            </div>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Network Traffic Over Ticks (Bytes/Second)</div>
            <canvas id="gameBytesChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Message Rate Over Ticks (Messages/Second)</div>
            <canvas id="gameMessagesChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Actions & Active Entities Over Ticks</div>
            <canvas id="gameActionsChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">All Game Metrics Over Ticks (Click legend to toggle)</div>
            <canvas id="gameAllMetricsChart"></canvas>
        </div>
        
        <script>
            const gameBytesCtx = document.getElementById('gameBytesChart').getContext('2d');
            new Chart(gameBytesCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [
                        {{
                            label: 'Bytes Sent/sec',
                            data: {game_bytes_sent_json},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y'
                        }},
                        {{
                            label: 'Bytes Recv/sec',
                            data: {game_bytes_recv_json},
                            borderColor: 'rgb(255, 99, 132)',
                            backgroundColor: 'rgba(255, 99, 132, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y'
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: {{
                        mode: 'index',
                        intersect: false
                    }},
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Tick'
                            }}
                        }},
                        y: {{
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'KB/s'
                            }}
                        }}
                    }}
                }}
            }});
            
            const gameMessagesCtx = document.getElementById('gameMessagesChart').getContext('2d');
            new Chart(gameMessagesCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [
                        {{
                            label: 'Messages Sent/sec',
                            data: {game_messages_sent_json},
                            borderColor: 'rgb(54, 162, 235)',
                            backgroundColor: 'rgba(54, 162, 235, 0.2)',
                            tension: 0.1
                        }},
                        {{
                            label: 'Messages Recv/sec',
                            data: {game_messages_recv_json},
                            borderColor: 'rgb(255, 206, 86)',
                            backgroundColor: 'rgba(255, 206, 86, 0.2)',
                            tension: 0.1
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: {{
                        mode: 'index',
                        intersect: false
                    }},
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Tick'
                            }}
                        }},
                        y: {{
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Messages/sec'
                            }}
                        }}
                    }}
                }}
            }});
            
            const gameActionsCtx = document.getElementById('gameActionsChart').getContext('2d');
            new Chart(gameActionsCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [
                        {{
                            label: 'Actions/sec',
                            data: {game_actions_json},
                            borderColor: 'rgb(153, 102, 255)',
                            backgroundColor: 'rgba(153, 102, 255, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y'
                        }},
                        {{
                            label: 'Active Players',
                            data: {game_active_players_json},
                            borderColor: 'rgb(255, 159, 64)',
                            backgroundColor: 'rgba(255, 159, 64, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y1'
                        }},
                        {{
                            label: 'Active Rooms',
                            data: {game_active_rooms_json},
                            borderColor: 'rgb(201, 203, 207)',
                            backgroundColor: 'rgba(201, 203, 207, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y1'
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: {{
                        mode: 'index',
                        intersect: false
                    }},
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Tick'
                            }}
                        }},
                        y: {{
                            type: 'linear',
                            display: true,
                            position: 'left',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Actions/sec'
                            }}
                        }},
                        y1: {{
                            type: 'linear',
                            display: true,
                            position: 'right',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Count'
                            }},
                            grid: {{
                                drawOnChartArea: false
                            }}
                        }}
                    }}
                }}
            }});
            
            // Comprehensive game metrics chart with toggle support
            const gameAllMetricsCtx = document.getElementById('gameAllMetricsChart').getContext('2d');
            const gameAllMetricsChart = new Chart(gameAllMetricsCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [
                        {{
                            label: 'Bytes Sent/sec (KB)',
                            data: {game_bytes_sent_json},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_bytes',
                            hidden: false
                        }},
                        {{
                            label: 'Bytes Recv/sec (KB)',
                            data: {game_bytes_recv_json},
                            borderColor: 'rgb(255, 99, 132)',
                            backgroundColor: 'rgba(255, 99, 132, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_bytes',
                            hidden: false
                        }},
                        {{
                            label: 'Messages Sent/sec',
                            data: {game_messages_sent_json},
                            borderColor: 'rgb(54, 162, 235)',
                            backgroundColor: 'rgba(54, 162, 235, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_messages',
                            hidden: false
                        }},
                        {{
                            label: 'Messages Recv/sec',
                            data: {game_messages_recv_json},
                            borderColor: 'rgb(255, 206, 86)',
                            backgroundColor: 'rgba(255, 206, 86, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_messages',
                            hidden: false
                        }},
                        {{
                            label: 'Actions/sec',
                            data: {game_actions_json},
                            borderColor: 'rgb(153, 102, 255)',
                            backgroundColor: 'rgba(153, 102, 255, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_actions',
                            hidden: false
                        }},
                        {{
                            label: 'Active Players',
                            data: {game_active_players_json},
                            borderColor: 'rgb(255, 159, 64)',
                            backgroundColor: 'rgba(255, 159, 64, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_count',
                            hidden: false
                        }},
                        {{
                            label: 'Active Rooms',
                            data: {game_active_rooms_json},
                            borderColor: 'rgb(201, 203, 207)',
                            backgroundColor: 'rgba(201, 203, 207, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_count',
                            hidden: false
                        }},
                        {{
                            label: 'Rooms Created',
                            data: {game_rooms_created_json},
                            borderColor: 'rgb(255, 99, 71)',
                            backgroundColor: 'rgba(255, 99, 71, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_count',
                            hidden: true
                        }},
                        {{
                            label: 'Rooms Target',
                            data: {game_rooms_target_json},
                            borderColor: 'rgb(144, 238, 144)',
                            backgroundColor: 'rgba(144, 238, 144, 0.1)',
                            tension: 0.1,
                            yAxisID: 'y_count',
                            hidden: true
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: {{
                        mode: 'index',
                        intersect: false
                    }},
                    plugins: {{
                        legend: {{
                            display: true,
                            position: 'top',
                            onClick: function(e, legendItem) {{
                                const index = legendItem.datasetIndex;
                                const chart = this.chart;
                                const meta = chart.getDatasetMeta(index);
                                meta.hidden = meta.hidden === null ? !chart.data.datasets[index].hidden : null;
                                chart.update();
                            }}
                        }},
                        tooltip: {{
                            callbacks: {{
                                label: function(context) {{
                                    let label = context.dataset.label || '';
                                    if (label) {{
                                        label += ': ';
                                    }}
                                    if (context.parsed.y !== null) {{
                                        label += new Intl.NumberFormat('en-US', {{
                                            maximumFractionDigits: 2
                                        }}).format(context.parsed.y);
                                    }}
                                    return label;
                                }}
                            }}
                        }}
                    }},
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Tick'
                            }}
                        }},
                        y_bytes: {{
                            type: 'linear',
                            display: 'auto',
                            position: 'left',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'KB/s'
                            }},
                            grid: {{
                                drawOnChartArea: true
                            }}
                        }},
                        y_messages: {{
                            type: 'linear',
                            display: 'auto',
                            position: 'right',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Messages/sec'
                            }},
                            grid: {{
                                drawOnChartArea: false
                            }}
                        }},
                        y_actions: {{
                            type: 'linear',
                            display: 'auto',
                            position: 'left',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Actions/sec'
                            }},
                            grid: {{
                                drawOnChartArea: false
                            }}
                        }},
                        y_count: {{
                            type: 'linear',
                            display: 'auto',
                            position: 'right',
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Count'
                            }},
                            grid: {{
                                drawOnChartArea: false
                            }}
                        }}
                    }}
                }}
            }});
        </script>
"""
        
        # Add performance metrics charts
        if game_estimated_ticks_per_second and len(game_estimated_ticks_per_second) > 0:
            html_content += f"""
        <h2>⚡ Performance Metrics (Update Speed & Latency)</h2>
        
        <div class="chart-container">
            <div class="chart-title">Update Rate Over Time (Ticks & Syncs per Second)</div>
            <canvas id="updateRateChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Average Update Time (ms) - Lower is Better (Indicates Lag if > 50ms)</div>
            <canvas id="updateTimeChart"></canvas>
        </div>
        
        <div class="chart-container">
            <div class="chart-title">Message Size Distribution Over Time (KB)</div>
            <canvas id="messageSizeChart"></canvas>
        </div>
        
        <script>
            // Update Rate Chart
            const updateRateCtx = document.getElementById('updateRateChart').getContext('2d');
            new Chart(updateRateCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [
                        {{
                            label: 'Ticks/sec',
                            data: {game_estimated_ticks_per_second_json},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y'
                        }},
                        {{
                            label: 'Syncs/sec',
                            data: {game_estimated_syncs_per_second_json},
                            borderColor: 'rgb(255, 99, 132)',
                            backgroundColor: 'rgba(255, 99, 132, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y'
                        }},
                        {{
                            label: 'Total Updates/sec',
                            data: {game_estimated_updates_per_second_json},
                            borderColor: 'rgb(153, 102, 255)',
                            backgroundColor: 'rgba(153, 102, 255, 0.2)',
                            tension: 0.1,
                            yAxisID: 'y',
                            borderWidth: 2
                        }}
                    ]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Time (seconds)'
                            }}
                        }},
                        y: {{
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Updates per Second'
                            }}
                        }}
                    }},
                    plugins: {{
                        tooltip: {{
                            callbacks: {{
                                label: function(context) {{
                                    let label = context.dataset.label || '';
                                    if (label) {{
                                        label += ': ';
                                    }}
                                    if (context.parsed.y !== null) {{
                                        label += new Intl.NumberFormat('en-US', {{
                                            maximumFractionDigits: 0
                                        }}).format(context.parsed.y);
                                    }}
                                    return label;
                                }}
                            }}
                        }}
                    }}
                }}
            }});
            
            // Update Time Chart (Latency indicator)
            const updateTimeCtx = document.getElementById('updateTimeChart').getContext('2d');
            new Chart(updateTimeCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [{{
                        label: 'Avg Update Time (ms)',
                        data: {game_update_times_ms_json},
                        borderColor: 'rgb(54, 162, 235)',
                        backgroundColor: 'rgba(54, 162, 235, 0.2)',
                        tension: 0.1,
                        fill: true
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Time (seconds)'
                            }}
                        }},
                        y: {{
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Update Time (ms)'
                            }},
                            ticks: {{
                                callback: function(value) {{
                                    return value.toFixed(2) + ' ms';
                                }}
                            }}
                        }}
                    }},
                    plugins: {{
                        annotation: {{
                            annotations: {{
                                line1: {{
                                    type: 'line',
                                    yMin: 10,
                                    yMax: 10,
                                    borderColor: 'rgb(255, 99, 132)',
                                    borderWidth: 2,
                                    borderDash: [5, 5],
                                    label: {{
                                        content: 'Warning: > 10ms may indicate lag',
                                        enabled: true,
                                        position: 'end'
                                    }}
                                }},
                                line2: {{
                                    type: 'line',
                                    yMin: 50,
                                    yMax: 50,
                                    borderColor: 'rgb(255, 165, 0)',
                                    borderWidth: 2,
                                    borderDash: [5, 5],
                                    label: {{
                                        content: 'Critical: > 50ms indicates significant lag',
                                        enabled: true,
                                        position: 'end'
                                    }}
                                }}
                            }}
                        }},
                        tooltip: {{
                            callbacks: {{
                                label: function(context) {{
                                    let label = context.dataset.label || '';
                                    if (label) {{
                                        label += ': ';
                                    }}
                                    if (context.parsed.y !== null) {{
                                        const ms = context.parsed.y;
                                        label += ms.toFixed(3) + ' ms';
                                        if (ms > 50) {{
                                            label += ' (🔴 Lag detected)';
                                        }} else if (ms > 10) {{
                                            label += ' (🟡 Possible lag)';
                                        }} else {{
                                            label += ' (🟢 Normal)';
                                        }}
                                    }}
                                    return label;
                                }}
                            }}
                        }}
                    }}
                }}
            }});
            
            // Message Size Chart
            const messageSizeCtx = document.getElementById('messageSizeChart').getContext('2d');
            new Chart(messageSizeCtx, {{
                type: 'line',
                data: {{
                    labels: {game_ticks_json},
                    datasets: [{{
                        label: 'Avg Message Size (KB)',
                        data: {game_avg_message_size_json},
                        borderColor: 'rgb(255, 159, 64)',
                        backgroundColor: 'rgba(255, 159, 64, 0.2)',
                        tension: 0.1,
                        fill: true
                    }}]
                }},
                options: {{
                    responsive: true,
                    maintainAspectRatio: false,
                    scales: {{
                        x: {{
                            title: {{
                                display: true,
                                text: 'Time (seconds)'
                            }}
                        }},
                        y: {{
                            beginAtZero: true,
                            title: {{
                                display: true,
                                text: 'Message Size (KB)'
                            }}
                        }}
                    }}
                }}
            }});
        </script>
"""
    
    # Add full JSON data section if test result is available
    if test_result_json:
        json_str = json.dumps(test_result_json, indent=2)
        html_content += f"""
        <h2>📄 Full Test Results (JSON)</h2>
        <div class="json-viewer">
            <pre>{json_str}</pre>
        </div>
"""
    
    # Add full monitoring JSON data
    if data:
        json_str = json.dumps(data, indent=2)
        html_content += f"""
        <h2>📈 Full Monitoring Data (JSON)</h2>
        <div class="json-viewer">
            <pre>{json_str}</pre>
        </div>
"""
    
    html_content += """
    </div>
</body>
</html>
"""
    
    output_path.write_text(html_content, encoding='utf-8')


def main() -> int:
    import argparse
    
    ap = argparse.ArgumentParser(description="Parse vmstat/pidstat logs and convert to JSON/HTML")
    ap.add_argument("--vmstat", type=Path, help="vmstat log file path (raw text or JSON)")
    ap.add_argument("--pidstat", type=Path, help="pidstat log file path (raw text or JSON)")
    ap.add_argument("--monitoring-json", type=Path, help="Pre-parsed monitoring JSON file (contains vmstat/pidstat)")
    ap.add_argument("--output", type=Path, help="Output JSON file path")
    ap.add_argument("--html", type=Path, help="Output HTML report file path")
    ap.add_argument("--test-result-json", type=Path, help="Test result JSON file to embed in HTML report")
    ap.add_argument("--process-name", default="ServerLoadTest", help="Process name to filter in pidstat")
    
    args = ap.parse_args()
    
    result: Dict[str, Any] = {
        "vmstat": [],
        "pidstat": [],
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
            print(f"Warning: Failed to load monitoring JSON: {e}", file=sys.stderr)
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
                        result["pidstat"] = parse_pidstat_log(args.pidstat, args.process_name)
            except Exception as e:
                print(f"Warning: Failed to parse pidstat: {e}", file=sys.stderr)
    
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
                print(f"Warning: Failed to load test result JSON: {e}", file=sys.stderr)
        
        generate_html_report(result, args.html, test_result_data)
        print(f"HTML report saved to: {args.html}")
    
    if not args.output and not args.html:
        print(output_json)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
