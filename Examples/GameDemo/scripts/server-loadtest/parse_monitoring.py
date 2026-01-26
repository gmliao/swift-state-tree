#!/usr/bin/env python3
"""
Parse vmstat/pidstat monitoring output and convert to JSON format.
"""

import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Any, Optional


def parse_vmstat_log(vmstat_path: Path) -> List[Dict[str, Any]]:
    """Parse vmstat output and return list of samples."""
    if not vmstat_path.exists():
        return []
    
    samples = []
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


def parse_pidstat_log(pidstat_path: Path, process_name: str = "ServerLoadTest") -> List[Dict[str, Any]]:
    """Parse pidstat output and return list of samples for the target process."""
    if not pidstat_path.exists():
        return []
    
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


def generate_html_report(data: Dict[str, Any], output_path: Path) -> None:
    """Generate an interactive HTML report with charts for monitoring data."""
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
    </style>
</head>
<body>
    <div class="container">
        <h1>Server Load Test - System Monitoring Report</h1>
        
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
                    labels: {json.dumps(vmstat_times)},
                    datasets: [
                        {{
                            label: 'User %',
                            data: {json.dumps(vmstat_cpu_us)},
                            borderColor: 'rgb(75, 192, 192)',
                            backgroundColor: 'rgba(75, 192, 192, 0.2)',
                            tension: 0.1
                        }},
                        {{
                            label: 'System %',
                            data: {json.dumps(vmstat_cpu_sy)},
                            borderColor: 'rgb(255, 99, 132)',
                            backgroundColor: 'rgba(255, 99, 132, 0.2)',
                            tension: 0.1
                        }},
                        {{
                            label: 'Idle %',
                            data: {json.dumps(vmstat_cpu_id)},
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
                    labels: {json.dumps(vmstat_times)},
                    datasets: [{{
                        label: 'Free Memory (MB)',
                        data: {json.dumps(vmstat_memory_free)},
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
                    labels: {json.dumps(pidstat_times)},
                    datasets: [{{
                        label: 'Process CPU %',
                        data: {json.dumps(pidstat_cpu)},
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
    
    html_content += """
    </div>
</body>
</html>
"""
    
    output_path.write_text(html_content, encoding='utf-8')


def main() -> int:
    import argparse
    
    ap = argparse.ArgumentParser(description="Parse vmstat/pidstat logs and convert to JSON/HTML")
    ap.add_argument("--vmstat", type=Path, help="vmstat log file path")
    ap.add_argument("--pidstat", type=Path, help="pidstat log file path")
    ap.add_argument("--output", type=Path, help="Output JSON file path")
    ap.add_argument("--html", type=Path, help="Output HTML report file path")
    ap.add_argument("--process-name", default="ServerLoadTest", help="Process name to filter in pidstat")
    
    args = ap.parse_args()
    
    result: Dict[str, Any] = {
        "vmstat": [],
        "pidstat": [],
    }
    
    if args.vmstat:
        result["vmstat"] = parse_vmstat_log(args.vmstat)
    
    if args.pidstat:
        result["pidstat"] = parse_pidstat_log(args.pidstat, args.process_name)
    
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
        generate_html_report(result, args.html)
        print(f"HTML report saved to: {args.html}")
    
    if not args.output and not args.html:
        print(output_json)
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
