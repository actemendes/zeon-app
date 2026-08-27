#!/usr/bin/env python3
"""
End-to-end diagnostics for profile rebind/create timeout investigation.

What this script does:
1. Benchmarks key endpoints from the current machine ("external").
2. Benchmarks key endpoints from zeon-server via SSH ("server-local").
3. Parses zeon-server journal response-time logs for route-level stats.
4. Produces machine-readable JSON + human-readable Markdown report.

The script is non-mutating by default (GET-only checks).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

try:
    import paramiko  # type: ignore
except Exception:  # pragma: no cover - optional dependency in runtime
    paramiko = None


DEFAULT_API_KEY = "mob_a7f3c9e1b2d4f6a8e0c5b7d9f1a3e5c7"
PRIMARY_BASE = "https://api.zeon-vps.online"
FALLBACK_BASE = "https://zeon-vps.link"
WRITE_FMT = (
    "%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t"
    "%{time_starttransfer}\t%{time_total}\t%{num_redirects}\t%{size_download}\t"
    "%{remote_ip}\t%{url_effective}"
)


@dataclass
class Target:
    name: str
    url: str
    headers: list[str]
    iterations: int
    max_time: int
    connect_timeout: int
    follow_redirects: bool
    vantage: str


@dataclass
class Sample:
    target: str
    vantage: str
    attempt: int
    ts_utc: str
    exit_code: int
    http_code: int | None
    time_namelookup: float | None
    time_connect: float | None
    time_appconnect: float | None
    time_starttransfer: float | None
    time_total: float | None
    num_redirects: int | None
    size_download: int | None
    remote_ip: str | None
    url_effective: str | None
    error: str | None


def utc_now_iso() -> str:
    return datetime.now(UTC).isoformat()


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    values_sorted = sorted(values)
    k = (len(values_sorted) - 1) * p
    low = math.floor(k)
    high = math.ceil(k)
    if low == high:
        return values_sorted[low]
    fraction = k - low
    return values_sorted[low] * (1.0 - fraction) + values_sorted[high] * fraction


def find_curl_binary() -> str:
    if platform.system().lower().startswith("win"):
        return "curl.exe"
    return "curl"


def find_adb_binary() -> str:
    path = shutil.which("adb") or shutil.which("adb.exe")
    return path or "adb"


def parse_metrics_line(line: str) -> dict[str, Any]:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 10:
        raise ValueError(f"Unexpected curl metrics format: {line!r}")
    return {
        "http_code": int(parts[0]) if parts[0].isdigit() else 0,
        "time_namelookup": float(parts[1]),
        "time_connect": float(parts[2]),
        "time_appconnect": float(parts[3]),
        "time_starttransfer": float(parts[4]),
        "time_total": float(parts[5]),
        "num_redirects": int(float(parts[6])),
        "size_download": int(float(parts[7])),
        "remote_ip": parts[8] or None,
        "url_effective": parts[9] or None,
    }


def build_curl_cmd(
    curl_bin: str,
    url: str,
    headers: list[str],
    follow_redirects: bool,
    max_time: int,
    connect_timeout: int,
    sink: str,
) -> list[str]:
    cmd = [
        curl_bin,
        "-sS",
        "--max-time",
        str(max_time),
        "--connect-timeout",
        str(connect_timeout),
        "-o",
        sink,
        "-w",
        WRITE_FMT,
    ]
    if follow_redirects:
        cmd.append("-L")
    for header in headers:
        cmd.extend(["-H", header])
    cmd.append(url)
    return cmd


def run_local_target(target: Target, curl_bin: str) -> list[Sample]:
    sink = "NUL" if platform.system().lower().startswith("win") else "/dev/null"
    samples: list[Sample] = []
    for idx in range(1, target.iterations + 1):
        cmd = build_curl_cmd(
            curl_bin=curl_bin,
            url=target.url,
            headers=target.headers,
            follow_redirects=target.follow_redirects,
            max_time=target.max_time,
            connect_timeout=target.connect_timeout,
            sink=sink,
        )
        started = utc_now_iso()
        proc = subprocess.run(cmd, capture_output=True, text=True)
        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()
        parsed: dict[str, Any] | None = None
        parse_error: str | None = None
        if stdout:
            try:
                parsed = parse_metrics_line(stdout.splitlines()[-1])
            except Exception as exc:
                parse_error = f"metrics_parse_error: {exc}"
        err = None
        if proc.returncode != 0:
            err = stderr or parse_error or "curl_failed"
        elif parse_error:
            err = parse_error
        samples.append(
            Sample(
                target=target.name,
                vantage=target.vantage,
                attempt=idx,
                ts_utc=started,
                exit_code=proc.returncode,
                http_code=(parsed or {}).get("http_code"),
                time_namelookup=(parsed or {}).get("time_namelookup"),
                time_connect=(parsed or {}).get("time_connect"),
                time_appconnect=(parsed or {}).get("time_appconnect"),
                time_starttransfer=(parsed or {}).get("time_starttransfer"),
                time_total=(parsed or {}).get("time_total"),
                num_redirects=(parsed or {}).get("num_redirects"),
                size_download=(parsed or {}).get("size_download"),
                remote_ip=(parsed or {}).get("remote_ip"),
                url_effective=(parsed or {}).get("url_effective"),
                error=err,
            )
        )
    return samples


def run_remote_target(ssh: Any, target: Target) -> list[Sample]:
    samples: list[Sample] = []
    for idx in range(1, target.iterations + 1):
        cmd_parts = build_curl_cmd(
            curl_bin="curl",
            url=target.url,
            headers=target.headers,
            follow_redirects=target.follow_redirects,
            max_time=target.max_time,
            connect_timeout=target.connect_timeout,
            sink="/dev/null",
        )
        remote_cmd = " ".join(shlex.quote(part) for part in cmd_parts)
        started = utc_now_iso()
        stdin, stdout, stderr = ssh.exec_command(
            remote_cmd, timeout=target.max_time + target.connect_timeout + 10
        )
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err_text = stderr.read().decode("utf-8", errors="replace").strip()
        rc = stdout.channel.recv_exit_status()
        parsed: dict[str, Any] | None = None
        parse_error: str | None = None
        if out:
            try:
                parsed = parse_metrics_line(out.splitlines()[-1])
            except Exception as exc:
                parse_error = f"metrics_parse_error: {exc}"
        err = None
        if rc != 0:
            err = err_text or parse_error or "remote_curl_failed"
        elif parse_error:
            err = parse_error
        samples.append(
            Sample(
                target=target.name,
                vantage=target.vantage,
                attempt=idx,
                ts_utc=started,
                exit_code=rc,
                http_code=(parsed or {}).get("http_code"),
                time_namelookup=(parsed or {}).get("time_namelookup"),
                time_connect=(parsed or {}).get("time_connect"),
                time_appconnect=(parsed or {}).get("time_appconnect"),
                time_starttransfer=(parsed or {}).get("time_starttransfer"),
                time_total=(parsed or {}).get("time_total"),
                num_redirects=(parsed or {}).get("num_redirects"),
                size_download=(parsed or {}).get("size_download"),
                remote_ip=(parsed or {}).get("remote_ip"),
                url_effective=(parsed or {}).get("url_effective"),
                error=err,
            )
        )
    return samples


def run_adb_target(adb_bin: str, serial: str, target: Target) -> list[Sample]:
    samples: list[Sample] = []
    adb_prefix = [adb_bin]
    if serial:
        adb_prefix.extend(["-s", serial])
    for idx in range(1, target.iterations + 1):
        curl_parts = build_curl_cmd(
            curl_bin="curl",
            url=target.url,
            headers=target.headers,
            follow_redirects=target.follow_redirects,
            max_time=target.max_time,
            connect_timeout=target.connect_timeout,
            sink="/dev/null",
        )
        remote_cmd = " ".join(shlex.quote(part) for part in curl_parts)
        cmd = adb_prefix + ["shell", remote_cmd]
        started = utc_now_iso()
        proc = subprocess.run(cmd, capture_output=True, text=True)
        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()
        parsed: dict[str, Any] | None = None
        parse_error: str | None = None
        if stdout:
            try:
                parsed = parse_metrics_line(stdout.splitlines()[-1])
            except Exception as exc:
                parse_error = f"metrics_parse_error: {exc}"
        err = None
        if proc.returncode != 0:
            err = stderr or parse_error or "adb_shell_curl_failed"
        elif parse_error:
            err = parse_error
        samples.append(
            Sample(
                target=target.name,
                vantage=target.vantage,
                attempt=idx,
                ts_utc=started,
                exit_code=proc.returncode,
                http_code=(parsed or {}).get("http_code"),
                time_namelookup=(parsed or {}).get("time_namelookup"),
                time_connect=(parsed or {}).get("time_connect"),
                time_appconnect=(parsed or {}).get("time_appconnect"),
                time_starttransfer=(parsed or {}).get("time_starttransfer"),
                time_total=(parsed or {}).get("time_total"),
                num_redirects=(parsed or {}).get("num_redirects"),
                size_download=(parsed or {}).get("size_download"),
                remote_ip=(parsed or {}).get("remote_ip"),
                url_effective=(parsed or {}).get("url_effective"),
                error=err,
            )
        )
    return samples


def summarize_samples(samples: list[Sample]) -> dict[str, Any]:
    by_target: dict[tuple[str, str], list[Sample]] = {}
    for sample in samples:
        key = (sample.target, sample.vantage)
        by_target.setdefault(key, []).append(sample)

    summary: dict[str, Any] = {}
    for (target_name, vantage), group in by_target.items():
        totals = [s.time_total for s in group if s.time_total is not None and s.exit_code == 0]
        http_2xx = sum(1 for s in group if s.http_code and 200 <= s.http_code < 300)
        http_3xx = sum(1 for s in group if s.http_code and 300 <= s.http_code < 400)
        http_4xx = sum(1 for s in group if s.http_code and 400 <= s.http_code < 500)
        http_5xx = sum(1 for s in group if s.http_code and 500 <= s.http_code < 600)
        failures = sum(1 for s in group if s.exit_code != 0 or s.error)
        summary[f"{target_name}@{vantage}"] = {
            "count_total": len(group),
            "count_success": len(totals),
            "count_failures": failures,
            "http_2xx": http_2xx,
            "http_3xx": http_3xx,
            "http_4xx": http_4xx,
            "http_5xx": http_5xx,
            "p50_total_s": percentile(totals, 0.50),
            "p95_total_s": percentile(totals, 0.95),
            "p99_total_s": percentile(totals, 0.99),
            "max_total_s": max(totals) if totals else None,
            "slow_ge_5s": sum(1 for t in totals if t >= 5.0),
            "slow_ge_15s": sum(1 for t in totals if t >= 15.0),
            "slow_ge_90s": sum(1 for t in totals if t >= 90.0),
            "share_ge_5s": (sum(1 for t in totals if t >= 5.0) / len(totals)) if totals else None,
            "share_ge_15s": (sum(1 for t in totals if t >= 15.0) / len(totals)) if totals else None,
            "share_ge_90s": (sum(1 for t in totals if t >= 90.0) / len(totals)) if totals else None,
        }
    return summary


def fetch_json(url: str, headers: dict[str, str], timeout: int = 15) -> dict[str, Any] | None:
    req = Request(url=url, method="GET")
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return json.loads(body)
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
        return None


def resolve_context(base_url: str, user_id: str, api_key: str) -> dict[str, Any]:
    lookup_url = f"{base_url}/api/v1/subscriptions/lookup?user_id={user_id}"
    lookup = fetch_json(lookup_url, {"x-api-key": api_key, "Content-Type": "application/json"})
    data = (lookup or {}).get("data", {})
    vpn_uuid = data.get("vpn_uuid")
    subscription_id = data.get("subscription_id")
    connection_link = data.get("connection_link")
    resolved = {
        "lookup_ok": bool((lookup or {}).get("ok")),
        "vpn_uuid": vpn_uuid,
        "subscription_id": subscription_id,
        "connection_link": connection_link,
    }
    return resolved


def parse_journal_response_times(log_text: str) -> dict[str, Any]:
    route_entries: dict[str, list[float]] = {}
    req_route_by_id: dict[str, str] = {}
    for line in log_text.splitlines():
        try:
            json_start = line.find("{")
            if json_start < 0:
                continue
            obj = json.loads(line[json_start:])

            req_id = obj.get("reqId")
            req_obj = obj.get("req")
            if req_id and isinstance(req_obj, dict):
                method = req_obj.get("method") or "?"
                url = req_obj.get("url") or "unknown"
                req_route_by_id[str(req_id)] = f"{method} {url}"

            response_time = obj.get("responseTime")
            if response_time is not None:
                route = None
                if req_id:
                    route = req_route_by_id.get(str(req_id))
                if not route and isinstance(req_obj, dict):
                    method = req_obj.get("method") or "?"
                    url = req_obj.get("url") or "unknown"
                    route = f"{method} {url}"
                if not route:
                    route = obj.get("url") or obj.get("path") or "unknown"
                route_entries.setdefault(str(route), []).append(float(response_time) / 1000.0)
        except Exception:
            continue

    result: dict[str, Any] = {}
    for route, times in route_entries.items():
        result[route] = {
            "count": len(times),
            "p50_s": percentile(times, 0.50),
            "p95_s": percentile(times, 0.95),
            "p99_s": percentile(times, 0.99),
            "max_s": max(times),
            "ge_5s": sum(1 for t in times if t >= 5.0),
            "ge_15s": sum(1 for t in times if t >= 15.0),
        }
    return result


def render_markdown_report(
    started_utc: str,
    finished_utc: str,
    config: dict[str, Any],
    context: dict[str, Any],
    summary: dict[str, Any],
    journal_summary: dict[str, Any] | None,
) -> str:
    lines: list[str] = []
    lines.append("# Profile Timeout Diagnostics Report")
    lines.append("")
    lines.append(f"- Started (UTC): `{started_utc}`")
    lines.append(f"- Finished (UTC): `{finished_utc}`")
    lines.append(f"- User ID: `{config['user_id']}`")
    lines.append(f"- Primary: `{config['primary_base']}`")
    lines.append(f"- Fallback: `{config['fallback_base']}`")
    lines.append(f"- Iterations (default/fallback): `{config['iterations_default']}/{config['iterations_fallback']}`")
    lines.append("")
    lines.append("## Resolved Context")
    lines.append(f"- lookup ok: `{context.get('lookup_ok')}`")
    lines.append(f"- vpn_uuid: `{context.get('vpn_uuid')}`")
    lines.append(f"- subscription_id: `{context.get('subscription_id')}`")
    lines.append("")
    lines.append("## Endpoint Latency Summary")
    lines.append("")
    lines.append("| target@vantage | count | p50(s) | p95(s) | p99(s) | max(s) | >=5s | >=15s | fail |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for key in sorted(summary.keys()):
        item = summary[key]
        lines.append(
            "| {key} | {count} | {p50:.3f} | {p95:.3f} | {p99:.3f} | {mx:.3f} | {ge5} | {ge15} | {fail} |".format(
                key=key,
                count=item.get("count_success", 0),
                p50=item.get("p50_total_s") or 0.0,
                p95=item.get("p95_total_s") or 0.0,
                p99=item.get("p99_total_s") or 0.0,
                mx=item.get("max_total_s") or 0.0,
                ge5=item.get("slow_ge_5s", 0),
                ge15=item.get("slow_ge_15s", 0),
                fail=item.get("count_failures", 0),
            )
        )
    lines.append("")
    if journal_summary is not None:
        relevant_markers = (
            "/open/",
            "/subscription/",
            "/api/v1/subscriptions/lookup",
            "/api/v1/connections",
            "/api/v1/users/create",
            "/api/v1/devices/rebind",
        )
        journal_items = list(journal_summary.items())
        relevant = [(route, stats) for route, stats in journal_items if any(m in route for m in relevant_markers)]
        if relevant:
            rows = sorted(relevant, key=lambda item: item[0])
        else:
            rows = sorted(journal_items, key=lambda item: item[1].get("count", 0), reverse=True)[:40]
        lines.append("## Server Journal Route Stats (last window)")
        lines.append("")
        lines.append("| route | count | p95(s) | max(s) | >=5s | >=15s |")
        lines.append("|---|---:|---:|---:|---:|---:|")
        for route, stats in rows:
            lines.append(
                "| {route} | {count} | {p95:.3f} | {mx:.3f} | {ge5} | {ge15} |".format(
                    route=route,
                    count=stats.get("count", 0),
                    p95=stats.get("p95_s") or 0.0,
                    mx=stats.get("max_s") or 0.0,
                    ge5=stats.get("ge_5s", 0),
                    ge15=stats.get("ge_15s", 0),
                )
            )
        lines.append("")
    lines.append("## Notes")
    lines.append("- This run uses GET-only probes to avoid mutating production data.")
    lines.append("- Client-flow timing from real device still requires adb capture while reproducing timeout.")
    lines.append("")
    return "\n".join(lines)


def run_journal_fetch(ssh: Any, unit: str, since: str) -> str:
    cmd = f"journalctl -u {shlex.quote(unit)} --since {shlex.quote(since)} --no-pager"
    stdin, stdout, stderr = ssh.exec_command(cmd, timeout=120)
    out = stdout.read().decode("utf-8", errors="replace")
    _ = stderr.read().decode("utf-8", errors="replace")
    return out


def open_ssh(host: str, user: str, password: str, port: int = 22) -> Any:
    if paramiko is None:
        raise RuntimeError("paramiko is not installed. Install it with: pip install paramiko")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(hostname=host, port=port, username=user, password=password, timeout=20)
    return client


def main() -> int:
    parser = argparse.ArgumentParser(description="Run profile timeout diagnostics")
    parser.add_argument("--output-dir", default="out/diagnostics")
    parser.add_argument("--user-id", default="649669380")
    parser.add_argument("--primary-base", default=PRIMARY_BASE)
    parser.add_argument("--fallback-base", default=FALLBACK_BASE)
    parser.add_argument("--api-key", default=DEFAULT_API_KEY)
    parser.add_argument("--iterations-default", type=int, default=100)
    parser.add_argument("--iterations-fallback", type=int, default=40)
    parser.add_argument("--max-time", type=int, default=20)
    parser.add_argument("--connect-timeout", type=int, default=5)
    parser.add_argument("--ssh-host", default="130.49.151.173")
    parser.add_argument("--ssh-user", default="root")
    parser.add_argument("--ssh-port", type=int, default=22)
    parser.add_argument("--ssh-pass-env", default="ZEON_SSH_PASSWORD")
    parser.add_argument("--skip-remote", action="store_true")
    parser.add_argument("--skip-local", action="store_true")
    parser.add_argument("--adb-serial", default="")
    parser.add_argument("--skip-device", action="store_true")
    parser.add_argument("--journal-unit", default="zeon-server")
    parser.add_argument("--journal-since", default="24 hours ago")
    args = parser.parse_args()

    started_utc = utc_now_iso()
    out_root = Path(args.output_dir).resolve()
    run_dir = out_root / datetime.now(UTC).strftime("profile_timeout_diag_%Y%m%d_%H%M%S")
    run_dir.mkdir(parents=True, exist_ok=True)

    context = resolve_context(args.primary_base, args.user_id, args.api_key)
    vpn_uuid = context.get("vpn_uuid")
    subscription_id = context.get("subscription_id")

    targets_local: list[Target] = [
        Target(
            name="open_primary_follow",
            url=f"{args.primary_base}/open/{args.user_id}",
            headers=[],
            iterations=args.iterations_default,
            max_time=args.max_time,
            connect_timeout=args.connect_timeout,
            follow_redirects=True,
            vantage="external",
        ),
        Target(
            name="open_fallback_follow",
            url=f"{args.fallback_base}/open/{args.user_id}",
            headers=[],
            iterations=args.iterations_fallback,
            max_time=args.max_time,
            connect_timeout=args.connect_timeout,
            follow_redirects=True,
            vantage="external",
        ),
        Target(
            name="lookup_primary",
            url=f"{args.primary_base}/api/v1/subscriptions/lookup?user_id={args.user_id}",
            headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
            iterations=args.iterations_default,
            max_time=args.max_time,
            connect_timeout=args.connect_timeout,
            follow_redirects=False,
            vantage="external",
        ),
    ]
    if vpn_uuid:
        targets_local.append(
            Target(
                name="subscription_primary",
                url=f"{args.primary_base}/subscription/{vpn_uuid}",
                headers=[],
                iterations=args.iterations_default,
                max_time=args.max_time,
                connect_timeout=args.connect_timeout,
                follow_redirects=False,
                vantage="external",
            )
        )
        targets_local.append(
            Target(
                name="connections_primary",
                url=f"{args.primary_base}/api/v1/connections?vpn_uuid={vpn_uuid}&format=v2ray",
                headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                iterations=args.iterations_default,
                max_time=args.max_time,
                connect_timeout=args.connect_timeout,
                follow_redirects=False,
                vantage="external",
            )
        )
    elif subscription_id:
        targets_local.append(
            Target(
                name="connections_primary",
                url=f"{args.primary_base}/api/v1/connections?subscription_id={subscription_id}&format=v2ray",
                headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                iterations=args.iterations_default,
                max_time=args.max_time,
                connect_timeout=args.connect_timeout,
                follow_redirects=False,
                vantage="external",
            )
        )

    curl_bin = find_curl_binary()
    all_samples: list[Sample] = []

    if not args.skip_local:
        for target in targets_local:
            print(f"[local] running {target.name} x{target.iterations}", flush=True)
            all_samples.extend(run_local_target(target, curl_bin=curl_bin))

    if not args.skip_device:
        adb_bin = find_adb_binary()
        adb_check_cmd = [adb_bin]
        if args.adb_serial:
            adb_check_cmd.extend(["-s", args.adb_serial])
        adb_check_cmd.extend(["get-state"])
        adb_ready = subprocess.run(adb_check_cmd, capture_output=True, text=True)
        if adb_ready.returncode == 0 and adb_ready.stdout.strip() == "device":
            targets_device: list[Target] = [
                Target(
                    name="open_primary_follow",
                    url=f"{args.primary_base}/open/{args.user_id}",
                    headers=[],
                    iterations=args.iterations_default,
                    max_time=args.max_time,
                    connect_timeout=args.connect_timeout,
                    follow_redirects=True,
                    vantage="device",
                ),
                Target(
                    name="open_fallback_follow",
                    url=f"{args.fallback_base}/open/{args.user_id}",
                    headers=[],
                    iterations=args.iterations_fallback,
                    max_time=args.max_time,
                    connect_timeout=args.connect_timeout,
                    follow_redirects=True,
                    vantage="device",
                ),
                Target(
                    name="lookup_primary",
                    url=f"{args.primary_base}/api/v1/subscriptions/lookup?user_id={args.user_id}",
                    headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                    iterations=args.iterations_default,
                    max_time=args.max_time,
                    connect_timeout=args.connect_timeout,
                    follow_redirects=False,
                    vantage="device",
                ),
            ]
            if vpn_uuid:
                targets_device.append(
                    Target(
                        name="subscription_primary",
                        url=f"{args.primary_base}/subscription/{vpn_uuid}",
                        headers=[],
                        iterations=args.iterations_default,
                        max_time=args.max_time,
                        connect_timeout=args.connect_timeout,
                        follow_redirects=False,
                        vantage="device",
                    )
                )
                targets_device.append(
                    Target(
                        name="connections_primary",
                        url=f"{args.primary_base}/api/v1/connections?vpn_uuid={vpn_uuid}&format=v2ray",
                        headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                        iterations=args.iterations_default,
                        max_time=args.max_time,
                        connect_timeout=args.connect_timeout,
                        follow_redirects=False,
                        vantage="device",
                    )
                )
            for target in targets_device:
                print(f"[device] running {target.name} x{target.iterations}", flush=True)
                all_samples.extend(run_adb_target(adb_bin=adb_bin, serial=args.adb_serial, target=target))
        else:
            print("[warn] device probes skipped. adb device is not ready.", flush=True)

    journal_summary: dict[str, Any] | None = None
    remote_available = (not args.skip_remote) and bool(os.getenv(args.ssh_pass_env))
    if remote_available:
        ssh_password = os.environ[args.ssh_pass_env]
        ssh = None
        try:
            ssh = open_ssh(
                host=args.ssh_host,
                user=args.ssh_user,
                password=ssh_password,
                port=args.ssh_port,
            )
            targets_remote: list[Target] = [
                Target(
                    name="open_primary_follow",
                    url=f"{args.primary_base}/open/{args.user_id}",
                    headers=[],
                    iterations=args.iterations_default,
                    max_time=args.max_time,
                    connect_timeout=args.connect_timeout,
                    follow_redirects=True,
                    vantage="server-local",
                ),
                Target(
                    name="lookup_primary",
                    url=f"{args.primary_base}/api/v1/subscriptions/lookup?user_id={args.user_id}",
                    headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                    iterations=args.iterations_default,
                    max_time=args.max_time,
                    connect_timeout=args.connect_timeout,
                    follow_redirects=False,
                    vantage="server-local",
                ),
            ]
            if vpn_uuid:
                targets_remote.append(
                    Target(
                        name="subscription_primary",
                        url=f"{args.primary_base}/subscription/{vpn_uuid}",
                        headers=[],
                        iterations=args.iterations_default,
                        max_time=args.max_time,
                        connect_timeout=args.connect_timeout,
                        follow_redirects=False,
                        vantage="server-local",
                    )
                )
                targets_remote.append(
                    Target(
                        name="connections_primary",
                        url=f"{args.primary_base}/api/v1/connections?vpn_uuid={vpn_uuid}&format=v2ray",
                        headers=[f"x-api-key: {args.api_key}", "Content-Type: application/json"],
                        iterations=args.iterations_default,
                        max_time=args.max_time,
                        connect_timeout=args.connect_timeout,
                        follow_redirects=False,
                        vantage="server-local",
                    )
                )
            for target in targets_remote:
                print(f"[remote] running {target.name} x{target.iterations}", flush=True)
                all_samples.extend(run_remote_target(ssh, target))
            journal_text = run_journal_fetch(ssh, args.journal_unit, args.journal_since)
            journal_summary = parse_journal_response_times(journal_text)
            (run_dir / "journal_raw.log").write_text(journal_text, encoding="utf-8")
        finally:
            if ssh is not None:
                ssh.close()
    else:
        print(
            f"[warn] remote probes skipped. Set env {args.ssh_pass_env} or use --skip-remote explicitly.",
            flush=True,
        )

    summary = summarize_samples(all_samples)
    finished_utc = utc_now_iso()

    samples_json_path = run_dir / "samples.json"
    summary_json_path = run_dir / "summary.json"
    report_md_path = run_dir / "report.md"

    samples_json_path.write_text(
        json.dumps([asdict(sample) for sample in all_samples], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    summary_payload = {
        "started_utc": started_utc,
        "finished_utc": finished_utc,
        "config": {
            "user_id": args.user_id,
            "primary_base": args.primary_base,
            "fallback_base": args.fallback_base,
            "iterations_default": args.iterations_default,
            "iterations_fallback": args.iterations_fallback,
            "journal_since": args.journal_since,
            "remote_enabled": remote_available,
        },
        "context": context,
        "summary": summary,
        "journal_summary": journal_summary,
    }
    summary_json_path.write_text(
        json.dumps(summary_payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    report_md_path.write_text(
        render_markdown_report(
            started_utc=started_utc,
            finished_utc=finished_utc,
            config=summary_payload["config"],
            context=context,
            summary=summary,
            journal_summary=journal_summary,
        ),
        encoding="utf-8",
    )

    print(f"[ok] samples: {samples_json_path}")
    print(f"[ok] summary: {summary_json_path}")
    print(f"[ok] report : {report_md_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
