#!/usr/bin/env python3
"""
Parse Android logcat and extract mobile profile bind/import timeout timeline.

Input: plain `adb logcat -v time` output file.
Output: JSON + Markdown summary in target directory.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


TIMESTAMP_RE = re.compile(r"^(?P<md>\d{2}-\d{2})\s+(?P<hms>\d{2}:\d{2}:\d{2}\.\d{3})")

EVENT_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("bootstrap_start", re.compile(r"mobile auto import", re.IGNORECASE)),
    ("conn_attempt", re.compile(r"mobile conn_link import attempt", re.IGNORECASE)),
    ("conn_success", re.compile(r"mobile conn_link import success", re.IGNORECASE)),
    ("conn_fail", re.compile(r"mobile conn_link import fail", re.IGNORECASE)),
    ("conn_throw", re.compile(r"mobile conn_link import threw", re.IGNORECASE)),
    ("rebind", re.compile(r"manual rebind", re.IGNORECASE)),
    ("lookup", re.compile(r"/api/v1/subscriptions/lookup", re.IGNORECASE)),
    ("users_create", re.compile(r"/api/v1/users/create", re.IGNORECASE)),
    ("devices_rebind", re.compile(r"/api/v1/devices/rebind", re.IGNORECASE)),
    (
        "ui_timeout",
        re.compile(
            r"(сервер долго отвечает|server .*respond)|(I/flutter.*timeoutexception)",
            re.IGNORECASE,
        ),
    ),
]

NETWORK_TIMEOUT_RE = re.compile(
    r"NetworkMonitor.*SocketTimeoutException|Read timed out|failed to connect",
    re.IGNORECASE,
)


@dataclass
class TimelineEvent:
    ts: str
    delta_s: float
    kind: str
    line: str


def parse_ts(line: str, year: int) -> datetime | None:
    match = TIMESTAMP_RE.search(line)
    if not match:
        return None
    raw = f"{year}-{match.group('md')} {match.group('hms')}"
    try:
        return datetime.strptime(raw, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=UTC)
    except ValueError:
        return None


def render_markdown(summary: dict[str, Any], events: list[TimelineEvent]) -> str:
    lines: list[str] = []
    lines.append("# Mobile Flow Timeline Summary")
    lines.append("")
    lines.append(f"- log file: `{summary['input_file']}`")
    lines.append(f"- total lines: `{summary['total_lines']}`")
    lines.append(f"- matched events: `{summary['event_count']}`")
    lines.append(f"- network timeout lines: `{summary['network_timeout_lines']}`")
    lines.append(f"- ui timeout detected: `{summary['ui_timeout_detected']}`")
    lines.append("")
    lines.append("## Event Counts")
    for key, value in sorted(summary["event_kinds"].items()):
        lines.append(f"- {key}: `{value}`")
    lines.append("")
    lines.append("## Timeline (first 100 events)")
    lines.append("")
    lines.append("| t+ (s) | kind | log |")
    lines.append("|---:|---|---|")
    for event in events[:100]:
        safe_line = event.line.replace("|", "\\|")
        lines.append(f"| {event.delta_s:.3f} | {event.kind} | `{safe_line}` |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse mobile bind/import flow from logcat")
    parser.add_argument("--input", required=True, help="Path to logcat text file")
    parser.add_argument("--output-dir", default="out/diagnostics", help="Directory for parsed output")
    parser.add_argument("--year", type=int, default=datetime.now(UTC).year)
    args = parser.parse_args()

    src = Path(args.input).resolve()
    out_dir = Path(args.output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    if not src.exists():
        raise FileNotFoundError(f"Input file does not exist: {src}")

    raw_lines = src.read_text(encoding="utf-8", errors="replace").splitlines()
    events: list[TimelineEvent] = []
    network_timeout_lines = 0
    first_ts: datetime | None = None
    counts: dict[str, int] = {}

    for raw in raw_lines:
        if NETWORK_TIMEOUT_RE.search(raw):
            network_timeout_lines += 1

        matched_kind: str | None = None
        for kind, pattern in EVENT_PATTERNS:
            if pattern.search(raw):
                matched_kind = kind
                break
        if matched_kind is None:
            continue

        ts = parse_ts(raw, args.year)
        if ts is None:
            continue
        if first_ts is None:
            first_ts = ts
        delta = (ts - first_ts).total_seconds() if first_ts else 0.0
        counts[matched_kind] = counts.get(matched_kind, 0) + 1
        events.append(TimelineEvent(ts=ts.isoformat(), delta_s=delta, kind=matched_kind, line=raw.strip()))

    summary = {
        "input_file": str(src),
        "total_lines": len(raw_lines),
        "event_count": len(events),
        "event_kinds": counts,
        "network_timeout_lines": network_timeout_lines,
        "ui_timeout_detected": counts.get("ui_timeout", 0) > 0,
        "started_at_utc": events[0].ts if events else None,
        "ended_at_utc": events[-1].ts if events else None,
        "duration_s": (events[-1].delta_s if events else 0.0),
    }

    stem = src.stem
    json_path = out_dir / f"{stem}_flow_summary.json"
    md_path = out_dir / f"{stem}_flow_summary.md"
    events_path = out_dir / f"{stem}_flow_events.json"

    json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    events_path.write_text(
        json.dumps([asdict(event) for event in events], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    md_path.write_text(render_markdown(summary, events), encoding="utf-8")

    print(f"[ok] summary: {json_path}")
    print(f"[ok] events : {events_path}")
    print(f"[ok] report : {md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
