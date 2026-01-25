#!/usr/bin/env python3
"""
Generate EMSE-ready tables (Markdown/CSV) and a simple SVG figure from:
1) EncodingBenchmark JSON envelopes (metadata + results)
2) ReevaluationRunner console output (captured manually), OR record JSON files if available.

This script avoids third-party dependencies (no matplotlib).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_csv(path: Path, rows: List[Dict[str, Any]], fieldnames: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})


def md_table(rows: List[List[str]]) -> str:
    if not rows:
        return ""
    widths = [max(len(str(cell)) for cell in col) for col in zip(*rows)]
    def fmt_row(r: List[str]) -> str:
        return "| " + " | ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(r)) + " |"
    header = rows[0]
    sep = ["-" * w for w in widths]
    out = [fmt_row(header), fmt_row(sep)]
    for r in rows[1:]:
        out.append(fmt_row(r))
    return "\n".join(out) + "\n"


def svg_bar_chart(
    title: str,
    labels: List[str],
    values: List[float],
    value_label: str,
    width: int = 800,
    height: int = 494,  # Golden ratio: 800 / 1.618 ≈ 494
    padding: int = 40,
    unit: str = "",
    improvement_pct: float | None = None,
) -> str:
    assert len(labels) == len(values)
    max_v = max(values) if values else 1.0
    max_v = max(max_v, 1e-9)
    # Increase header area to avoid overlap with bar values
    header_height = 70  # Increased from implicit 30+22=52 to 70
    bar_area_w = width - padding * 2
    bar_area_h = height - padding * 2 - header_height
    bar_w = bar_area_w / max(len(values), 1)
    gap = bar_w * 0.2
    inner_w = bar_w - gap

    def y_of(v: float) -> float:
        return padding + header_height + (bar_area_h * (1.0 - v / max_v))

    def h_of(v: float) -> float:
        return bar_area_h * (v / max_v)

    # Format value with unit
    def format_value(v: float) -> str:
        if unit:
            return f"{v:.0f} {unit}"
        return f"{v:.1f}"

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        f'<rect x="0" y="0" width="{width}" height="{height}" fill="white"/>',
        f'<text x="{padding}" y="{padding}" font-family="Arial" font-size="18">{escape_xml(title)}</text>',
        f'<text x="{padding}" y="{padding+22}" font-family="Arial" font-size="12" fill="#444">{escape_xml(value_label)}</text>',
    ]
    # Axis line
    axis_y = padding + header_height + bar_area_h
    parts.append(f'<line x1="{padding}" y1="{axis_y}" x2="{width-padding}" y2="{axis_y}" stroke="#333" stroke-width="1"/>')

    for i, (lab, v) in enumerate(zip(labels, values)):
        x = padding + i * bar_w + gap / 2
        y = y_of(v)
        h = h_of(v)
        parts.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{inner_w:.2f}" height="{h:.2f}" fill="#4C78A8"/>')
        # Value above bar with unit
        parts.append(f'<text x="{x + inner_w/2:.2f}" y="{y - 10:.2f}" text-anchor="middle" font-family="Arial" font-size="12">{escape_xml(format_value(v))}</text>')
        # Improvement percentage for second bar (if provided)
        if i == 1 and improvement_pct is not None:
            improvement_y = y - 30
            parts.append(f'<text x="{x + inner_w/2:.2f}" y="{improvement_y:.2f}" text-anchor="middle" font-family="Arial" font-size="11" fill="#2E7D32" font-weight="bold">{improvement_pct:.1f}% reduction</text>')
        parts.append(f'<text x="{x + inner_w/2:.2f}" y="{axis_y + 16:.2f}" text-anchor="middle" font-family="Arial" font-size="11" fill="#333">{escape_xml(lab)}</text>')

    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def escape_xml(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


@dataclass(frozen=True)
class ScalabilityRow:
    format: str
    display: str
    rooms: int
    players_per_room: int
    ticks_per_sync: int
    iterations: int
    serial_time_ms: float
    parallel_time_ms: float
    serial_avg_cost_ms: float
    parallel_avg_cost_ms: float
    serial_bytes_per_sync: int
    parallel_bytes_per_sync: int
    speedup: float
    efficiency_pct: float
    cpu_logical: int


def parse_scalability_matrix(envelope: Dict[str, Any]) -> List[ScalabilityRow]:
    meta = envelope.get("metadata", {})
    env = meta.get("environment", {})
    cpu_logical = int(env.get("cpuLogicalCores") or 0)
    bench = meta.get("benchmarkConfig", {})
    ticks_per_sync = int(bench.get("ticksPerSync") or 0)
    iterations = int(bench.get("iterations") or 0)

    rows: List[ScalabilityRow] = []
    for r in envelope.get("results", []):
        rooms = int(r.get("rooms") or r.get("roomCount") or 0)
        ppr = int(r.get("playersPerRoom") or 0)
        fmt = str(r.get("format") or "")
        display = str(r.get("displayName") or fmt)
        serial = r.get("serial") or {}
        parallel = r.get("parallel") or {}
        serial_time = float(serial.get("timeMs") or 0.0)
        parallel_time = float(parallel.get("timeMs") or 0.0)
        serial_avg = float(serial.get("avgCostPerSyncMs") or 0.0)
        parallel_avg = float(parallel.get("avgCostPerSyncMs") or 0.0)
        serial_bps = int(serial.get("bytesPerSync") or 0)
        parallel_bps = int(parallel.get("bytesPerSync") or 0)
        speedup = float(r.get("speedup") or (serial_time / parallel_time if parallel_time > 0 else 0.0))
        eff = float(r.get("efficiency") or 0.0)
        rows.append(
            ScalabilityRow(
                format=fmt,
                display=display,
                rooms=rooms,
                players_per_room=ppr,
                ticks_per_sync=ticks_per_sync,
                iterations=iterations,
                serial_time_ms=serial_time,
                parallel_time_ms=parallel_time,
                serial_avg_cost_ms=serial_avg,
                parallel_avg_cost_ms=parallel_avg,
                serial_bytes_per_sync=serial_bps,
                parallel_bytes_per_sync=parallel_bps,
                speedup=speedup,
                efficiency_pct=eff,
                cpu_logical=cpu_logical,
            )
        )
    return rows


def compute_capacity(
    avg_cost_per_sync_ms: float,
    cpu_logical: int,
    sync_hz: float,
    cpu_usage_limit: float,
    players_per_room: int,
) -> Tuple[float, float]:
    # costRoomMsPerSecond = avgCostPerSyncMs * syncHz
    cost_room_ms_per_sec = avg_cost_per_sync_ms * sync_hz
    cpu_budget_ms_per_sec = cpu_logical * 1000.0 * cpu_usage_limit
    if cost_room_ms_per_sec <= 0:
        return 0.0, 0.0
    max_rooms = cpu_budget_ms_per_sec / cost_room_ms_per_sec
    max_players = max_rooms * players_per_room
    return max_rooms, max_players


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default="artifacts", help="Output directory (default: artifacts)")
    ap.add_argument("--json-object", required=True, help="scalability-matrix json-object envelope path")
    ap.add_argument("--messagepack", required=True, help="scalability-matrix messagepack-pathhash envelope path")
    ap.add_argument("--sync-hz", type=float, default=10.0)
    ap.add_argument("--cpu-usage-limit", type=float, default=0.7)
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    rows += parse_scalability_matrix(load_json(Path(args.json_object)))
    rows += parse_scalability_matrix(load_json(Path(args.messagepack)))

    # Filter to ppr=5 and rooms 10/30/50 if present
    wanted_rooms = {10, 30, 50}
    rows = [r for r in rows if r.players_per_room == 5 and r.rooms in wanted_rooms]

    # RQ1 table (bytesPerSync)
    rq1_rows_csv: List[Dict[str, Any]] = []
    for r in sorted(rows, key=lambda x: (x.display, x.rooms)):
        rq1_rows_csv.append(
            dict(
                format=r.display,
                rooms=r.rooms,
                playersPerRoom=r.players_per_room,
                ticksPerSync=r.ticks_per_sync,
                iterations=r.iterations,
                serial_bytesPerSync=r.serial_bytes_per_sync,
                parallel_bytesPerSync=r.parallel_bytes_per_sync,
            )
        )
    write_csv(
        out_dir / "rq1_network_efficiency.csv",
        rq1_rows_csv,
        ["format", "rooms", "playersPerRoom", "ticksPerSync", "iterations", "serial_bytesPerSync", "parallel_bytesPerSync"],
    )

    # RQ2 capacity table
    rq2_rows: List[List[str]] = [[
        "format",
        "rooms",
        "avgCostPerSyncMs(serial)",
        "avgCostPerSyncMs(parallel)",
        "MaxRooms(serial)",
        "MaxRooms(parallel)",
        "MaxPlayers(serial)",
        "MaxPlayers(parallel)",
    ]]
    rq2_csv: List[Dict[str, Any]] = []
    for r in sorted(rows, key=lambda x: (x.display, x.rooms)):
        max_rooms_s, max_players_s = compute_capacity(
            r.serial_avg_cost_ms, r.cpu_logical, args.sync_hz, args.cpu_usage_limit, r.players_per_room
        )
        max_rooms_p, max_players_p = compute_capacity(
            r.parallel_avg_cost_ms, r.cpu_logical, args.sync_hz, args.cpu_usage_limit, r.players_per_room
        )
        rq2_rows.append([
            r.display,
            str(r.rooms),
            f"{r.serial_avg_cost_ms:.4f}",
            f"{r.parallel_avg_cost_ms:.4f}",
            f"{max_rooms_s:.1f}",
            f"{max_rooms_p:.1f}",
            f"{max_players_s:.0f}",
            f"{max_players_p:.0f}",
        ])
        rq2_csv.append(
            dict(
                format=r.display,
                rooms=r.rooms,
                cpuLogicalCores=r.cpu_logical,
                syncHz=args.sync_hz,
                cpuUsageLimit=args.cpu_usage_limit,
                playersPerRoom=r.players_per_room,
                serial_avgCostPerSyncMs=r.serial_avg_cost_ms,
                parallel_avgCostPerSyncMs=r.parallel_avg_cost_ms,
                maxRoomsSerial=max_rooms_s,
                maxRoomsParallel=max_rooms_p,
                maxPlayersSerial=max_players_s,
                maxPlayersParallel=max_players_p,
            )
        )
    write_text(out_dir / "rq2_capacity_model.md", md_table(rq2_rows))
    write_csv(
        out_dir / "rq2_capacity_model.csv",
        rq2_csv,
        [
            "format",
            "rooms",
            "cpuLogicalCores",
            "syncHz",
            "cpuUsageLimit",
            "playersPerRoom",
            "serial_avgCostPerSyncMs",
            "parallel_avgCostPerSyncMs",
            "maxRoomsSerial",
            "maxRoomsParallel",
            "maxPlayersSerial",
            "maxPlayersParallel",
        ],
    )

    # Simple SVG figure for RQ1: parallel bytes per sync at rooms=50
    rows_50 = [r for r in rows if r.rooms == 50]
    labels = [r.display for r in rows_50]
    values_bytes = [float(r.parallel_bytes_per_sync) for r in rows_50]
    values_time = [float(r.parallel_avg_cost_ms) for r in rows_50]
    
    # Calculate improvement percentages (baseline is first, optimized is second)
    improvement_pct_bytes = None
    improvement_pct_time = None
    if len(values_bytes) == 2 and values_bytes[0] > 0:
        improvement_pct_bytes = ((values_bytes[1] - values_bytes[0]) / values_bytes[0]) * 100.0
    if len(values_time) == 2 and values_time[0] > 0:
        improvement_pct_time = ((values_time[1] - values_time[0]) / values_time[0]) * 100.0
    
    # Single metric chart (bytes only) - RQ1 focuses on network efficiency
    svg_bytes = svg_bar_chart(
        title="RQ1: Bytes per sync at 50 rooms (parallel)",
        labels=labels,
        values=values_bytes,
        value_label="bytesPerSync (application payload)",
        unit="bytes",
        improvement_pct=improvement_pct_bytes,
    )
    write_text(out_dir / "rq1_bytes_per_sync_rooms50_parallel.svg", svg_bytes)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

