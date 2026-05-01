#!/usr/bin/env python3
# thermal-heartbeat.py - read every available temperature sensor on the host,
# write a Prometheus textfile for node-exporter to scrape, and ping a Sentry
# cron monitor.
#
# Runs on kai-server every 30s via thermal-heartbeat.timer.
#
# Sources, in order of preference:
#   1. lm-sensors `sensors -j`   (CPU package, per-core, motherboard, ambient)
#   2. nvme-cli   `nvme smart-log -o json` for each /dev/nvme*n*
#   3. kernel    /sys/class/thermal/thermal_zone*/temp  (always-on backstop)
#
# Outputs:
#   /var/lib/node-exporter/textfile/thermal.prom
#       node_thermal_celsius{source,chip,sensor} <C>
#       node_thermal_heartbeat_seconds <unix-ts>
#       node_thermal_breach <0|1>
#
# Sentry side, when SENTRY_CRON_URL is set:
#   - Always POSTs a check-in with status=ok|error and duration.
#   - On threshold breach, additionally sends an envelope to SENTRY_DSN with
#     the thermal payload as tags so alert rules can fire on level=warning.
#
# Stdlib only on purpose - this runs on a stock Debian box without any
# Python venv.

import argparse
import dataclasses
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Iterable

TEXTFILE_DEFAULT = "/var/lib/node-exporter/textfile/thermal.prom"
DEFAULT_THRESHOLDS = {
    # source -> celsius. Anything not listed never breaches.
    "lm_sensors_cpu": 85.0,
    "nvme": 70.0,
    "thermal_zone": 95.0,
}
HOSTNAME = socket.gethostname()


@dataclasses.dataclass
class Reading:
    source: str
    chip: str
    sensor: str
    celsius: float

    def label_str(self) -> str:
        return ",".join(
            f'{k}="{_escape(v)}"'
            for k, v in (("source", self.source), ("chip", self.chip), ("sensor", self.sensor))
        )

    def threshold_key(self) -> str:
        if self.source == "lm_sensors" and ("Package" in self.sensor or "Tctl" in self.sensor or "Tdie" in self.sensor):
            return "lm_sensors_cpu"
        return self.source


def _escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def _run(cmd: list[str], timeout: float = 5.0) -> str | None:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout


def read_lm_sensors() -> Iterable[Reading]:
    raw = _run(["sensors", "-j"])
    if not raw:
        return
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return
    for chip, chip_body in data.items():
        if not isinstance(chip_body, dict):
            continue
        for sensor_name, sensor_body in chip_body.items():
            if not isinstance(sensor_body, dict):
                continue
            # lm-sensors keys look like "temp1_input" (Celsius) or
            # "fan1_input" (RPM). Both have the same `_input` suffix, so
            # narrow on the `temp` prefix to avoid reporting fan speeds as
            # temperatures.
            for key, value in sensor_body.items():
                if isinstance(value, (int, float)) and key.startswith("temp") and key.endswith("_input"):
                    yield Reading("lm_sensors", chip, sensor_name, float(value))


def read_thermal_zones() -> Iterable[Reading]:
    base = pathlib.Path("/sys/class/thermal")
    if not base.exists():
        return
    for zone in sorted(base.glob("thermal_zone*")):
        try:
            temp_milli = int((zone / "temp").read_text().strip())
            zone_type = (zone / "type").read_text().strip()
        except (OSError, ValueError):
            continue
        yield Reading("thermal_zone", zone.name, zone_type, temp_milli / 1000.0)


def read_nvme() -> Iterable[Reading]:
    devices = sorted(pathlib.Path("/dev").glob("nvme*n*"))
    for dev in devices:
        # /dev/nvme0n1, /dev/nvme0n1p1 -> only the namespace, not partitions.
        if re.fullmatch(r"nvme\d+n\d+", dev.name) is None:
            continue
        raw = _run(["nvme", "smart-log", "-o", "json", str(dev)])
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            continue
        # `temperature` is in Kelvin x 100 on some kernels, Celsius on others.
        # nvme-cli normalizes to Celsius for the json output.
        temp = data.get("temperature")
        if isinstance(temp, (int, float)):
            yield Reading("nvme", dev.name, "composite", float(temp))
        for k, v in data.items():
            m = re.fullmatch(r"temperature_sensor_(\d+)", k)
            if m and isinstance(v, (int, float)) and v > 0:
                yield Reading("nvme", dev.name, f"sensor_{m.group(1)}", float(v))


def collect() -> list[Reading]:
    readings: list[Reading] = []
    readings.extend(read_lm_sensors())
    readings.extend(read_nvme())
    readings.extend(read_thermal_zones())
    return readings


def read_cpu_usage_pct(delay_s: float = 0.25) -> float | None:
    # Sample /proc/stat's `cpu` aggregate row twice and diff. Fields:
    # user nice system idle iowait irq softirq steal guest guest_nice.
    proc_stat = pathlib.Path("/proc/stat")
    try:
        a = [int(x) for x in proc_stat.read_text().splitlines()[0].split()[1:]]
        time.sleep(delay_s)
        b = [int(x) for x in proc_stat.read_text().splitlines()[0].split()[1:]]
    except (OSError, ValueError, IndexError):
        return None
    total = sum(b) - sum(a)
    idle = (b[3] + b[4]) - (a[3] + a[4])
    if total <= 0:
        return None
    return 100.0 * (total - idle) / total


def read_loadavg() -> tuple[float, float, float] | None:
    try:
        parts = pathlib.Path("/proc/loadavg").read_text().split()
        return float(parts[0]), float(parts[1]), float(parts[2])
    except (OSError, ValueError, IndexError):
        return None


def render_textfile(
    readings: list[Reading],
    breach: bool,
    ts: int,
    cpu_usage_pct: float | None,
    loadavg: tuple[float, float, float] | None,
) -> str:
    lines = [
        "# HELP node_thermal_celsius Temperature in degrees Celsius from lm-sensors, nvme, and kernel thermal zones.",
        "# TYPE node_thermal_celsius gauge",
    ]
    for r in readings:
        lines.append(f"node_thermal_celsius{{{r.label_str()}}} {r.celsius:.2f}")
    lines.extend(
        [
            "# HELP node_thermal_heartbeat_seconds Unix timestamp of the last successful thermal collection.",
            "# TYPE node_thermal_heartbeat_seconds gauge",
            f"node_thermal_heartbeat_seconds {ts}",
            "# HELP node_thermal_breach 1 if any reading exceeded its configured threshold on the last collection.",
            "# TYPE node_thermal_breach gauge",
            f"node_thermal_breach {1 if breach else 0}",
        ]
    )
    if cpu_usage_pct is not None:
        # Pair-with-thermal CPU util: node-exporter exposes the raw counters
        # too, but emitting the gauge alongside the temps keeps the breach
        # narrative ("hot AND loaded" vs "hot AND idle") in one panel.
        lines.extend(
            [
                "# HELP node_thermal_cpu_usage_pct Instantaneous system-wide CPU usage % over a 250ms sample.",
                "# TYPE node_thermal_cpu_usage_pct gauge",
                f"node_thermal_cpu_usage_pct {cpu_usage_pct:.2f}",
            ]
        )
    if loadavg is not None:
        lines.extend(
            [
                "# HELP node_thermal_loadavg System load average paired with the thermal sample.",
                "# TYPE node_thermal_loadavg gauge",
                f'node_thermal_loadavg{{window="1m"}} {loadavg[0]:.2f}',
                f'node_thermal_loadavg{{window="5m"}} {loadavg[1]:.2f}',
                f'node_thermal_loadavg{{window="15m"}} {loadavg[2]:.2f}',
            ]
        )
    return "\n".join(lines) + "\n"


def atomic_write(path: pathlib.Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(body)
    tmp.replace(path)


def find_breaches(readings: list[Reading], thresholds: dict[str, float]) -> list[tuple[Reading, float]]:
    out: list[tuple[Reading, float]] = []
    for r in readings:
        limit = thresholds.get(r.threshold_key())
        if limit is not None and r.celsius >= limit:
            out.append((r, limit))
    return out


def post(url: str, body: bytes | None, headers: dict[str, str], timeout: float = 5.0) -> int | None:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except (urllib.error.URLError, TimeoutError, socket.timeout):
        return None


def sentry_check_in(cron_url: str, status: str, duration_ms: int) -> int | None:
    qs = urllib.parse.urlencode({"status": status, "duration": duration_ms})
    sep = "&" if "?" in cron_url else "?"
    return post(f"{cron_url}{sep}{qs}", body=b"", headers={"Content-Length": "0"})


def sentry_event(
    dsn: str,
    breaches: list[tuple[Reading, float]],
    cpu_usage_pct: float | None,
    loadavg: tuple[float, float, float] | None,
) -> int | None:
    # Parse a DSN of the form https://<key>@<host>/<project>.
    parsed = urllib.parse.urlparse(dsn)
    if not parsed.username or not parsed.path.lstrip("/"):
        return None
    project_id = parsed.path.lstrip("/")
    public_key = parsed.username
    envelope_url = f"{parsed.scheme}://{parsed.hostname}/api/{project_id}/envelope/"
    event_id = uuid.uuid4().hex
    ts = time.time()
    tags = {"host": HOSTNAME, "breach_count": str(len(breaches))}
    if cpu_usage_pct is not None:
        tags["cpu_usage_pct"] = f"{cpu_usage_pct:.1f}"
    if loadavg is not None:
        tags["loadavg_1m"] = f"{loadavg[0]:.2f}"
        tags["loadavg_5m"] = f"{loadavg[1]:.2f}"
    for i, (r, limit) in enumerate(breaches[:10]):
        tags[f"breach_{i}_source"] = r.source
        tags[f"breach_{i}_sensor"] = f"{r.chip}/{r.sensor}"
        tags[f"breach_{i}_celsius"] = f"{r.celsius:.1f}"
        tags[f"breach_{i}_limit"] = f"{limit:.1f}"
    event = {
        "event_id": event_id,
        "timestamp": ts,
        "platform": "other",
        "level": "warning",
        "logger": "thermal-heartbeat",
        "server_name": HOSTNAME,
        "message": f"thermal threshold breach: {len(breaches)} sensor(s) over limit on {HOSTNAME}",
        "tags": tags,
        "extra": {
            "breaches": [
                {
                    "source": r.source,
                    "chip": r.chip,
                    "sensor": r.sensor,
                    "celsius": r.celsius,
                    "limit": limit,
                }
                for r, limit in breaches
            ]
        },
    }
    envelope_header = json.dumps({"event_id": event_id, "dsn": dsn})
    item_header = json.dumps({"type": "event", "content_type": "application/json"})
    item_payload = json.dumps(event)
    body = f"{envelope_header}\n{item_header}\n{item_payload}\n".encode()
    headers = {
        "Content-Type": "application/x-sentry-envelope",
        "X-Sentry-Auth": (
            f"Sentry sentry_version=7,sentry_client=thermal-heartbeat/1.0,sentry_key={public_key}"
        ),
    }
    return post(envelope_url, body, headers)


def main() -> int:
    parser = argparse.ArgumentParser(description="thermal heartbeat for kai-server")
    parser.add_argument("--textfile", default=os.environ.get("THERMAL_TEXTFILE", TEXTFILE_DEFAULT))
    parser.add_argument("--dry-run", action="store_true", help="print textfile to stdout, skip writes and Sentry calls")
    args = parser.parse_args()

    started = time.monotonic()
    readings = collect()
    cpu_usage_pct = read_cpu_usage_pct()
    loadavg = read_loadavg()
    breaches = find_breaches(readings, DEFAULT_THRESHOLDS)
    breach = bool(breaches)
    ts = int(time.time())
    body = render_textfile(readings, breach, ts, cpu_usage_pct, loadavg)

    if args.dry_run:
        sys.stdout.write(body)
        if breaches:
            sys.stderr.write(f"breaches: {len(breaches)}\n")
        return 0

    atomic_write(pathlib.Path(args.textfile), body)

    duration_ms = int((time.monotonic() - started) * 1000)
    cron_url = os.environ.get("SENTRY_CRON_URL", "").strip()
    dsn = os.environ.get("SENTRY_DSN", "").strip()
    if cron_url:
        sentry_check_in(cron_url, "error" if breach else "ok", duration_ms)
    if dsn and breaches:
        sentry_event(dsn, breaches, cpu_usage_pct, loadavg)

    if not readings:
        # Don't fail the unit; the textfile still has the heartbeat metric and
        # Sentry will see status=error from a follow-up no-readings detection.
        sys.stderr.write("thermal-heartbeat: no sensors produced readings\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
