#!/usr/bin/env python3
# process-memory-heartbeat.py - sample per-process RSS on this host, humanize
# generic interpreter names (python, node, etc.) into something readable, and
# push the result to VictoriaMetrics single via OTLP/HTTP protobuf.
#
# Runs on kai-server every 30s via process-memory-heartbeat.timer.
#
# Output:
#   POST <VMSINGLE_OTLP_URL> (Content-Type: application/x-protobuf) with two gauges:
#     process_memory_rss_bytes{process,user,host}      # per-process aggregate
#     system_memory_bytes{state,host}                  # total/available/free/buffers/cached
#
# Defaults to the in-cluster vmsingle NodePort at http://localhost:30428.
# VictoriaMetrics single does NOT accept OTLP/JSON - protobuf only - so this
# script hand-encodes the small subset of OTLP messages it needs (the proto
# wire format is stable and trivial). VM lowercases / underscores the metric
# and attribute names automatically.
#
# Stdlib only - matches thermal-heartbeat's no-venv constraint.

import argparse
import os
import pwd
import re
import socket
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = "http://localhost:30428/opentelemetry/v1/metrics"
DEFAULT_TOP_N = 50
HOSTNAME = socket.gethostname()

# Python entry-points where the interesting name lives in the next argv,
# not in the `-m <runner>` token itself.
PYTHON_RUNNERS = {"uvicorn", "gunicorn", "hypercorn", "daphne", "celery", "flask"}


def read_bytes(path: str) -> bytes:
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def read_cmdline(pid: int) -> list[str]:
    raw = read_bytes(f"/proc/{pid}/cmdline").rstrip(b"\x00")
    if not raw:
        return []
    return [a.decode("utf-8", "replace") for a in raw.split(b"\x00")]


def read_comm(pid: int) -> str:
    return read_bytes(f"/proc/{pid}/comm").decode("utf-8", "replace").strip()


def read_status(pid: int) -> dict[str, str]:
    raw = read_bytes(f"/proc/{pid}/status").decode("utf-8", "replace")
    out: dict[str, str] = {}
    for line in raw.splitlines():
        k, sep, v = line.partition(":")
        if sep:
            out[k.strip()] = v.strip()
    return out


def humanize(comm: str, argv: list[str]) -> str:
    """Map (comm, argv) to a stable, readable process name.

    Generic interpreters (python, node) get rewritten using the script or
    module they're running so 'python' doesn't collapse three uvicorn apps
    into one timeseries.
    """
    if not comm:
        return "?"

    if re.fullmatch(r"python\d*(\.\d+)?", comm):
        # `python -m <runner> <target>` -> "<runner>:<target-first-segment>"
        if "-m" in argv:
            i = argv.index("-m")
            if i + 1 < len(argv):
                module = argv[i + 1]
                if module in PYTHON_RUNNERS:
                    for tail in argv[i + 2 :]:
                        if tail.startswith("-"):
                            continue
                        base = tail.split(":")[0]
                        return f"{module}:{base}" if base else module
                    return module
                return module
        # `python /path/to/script.py ...` -> "script.py"
        for a in argv[1:]:
            if a.startswith("-"):
                continue
            return os.path.basename(a) or comm
        return comm

    if comm in {"node", "nodejs"}:
        for a in argv[1:]:
            if a.startswith("-"):
                continue
            return os.path.basename(a) or comm
        return comm

    return comm


def collect_processes() -> list[dict]:
    procs: list[dict] = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return procs
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        status = read_status(pid)
        rss_field = status.get("VmRSS")
        if not rss_field:
            continue
        try:
            rss_bytes = int(rss_field.split()[0]) * 1024
        except (ValueError, IndexError):
            continue
        uid_field = status.get("Uid", "0").split()[0]
        try:
            user = pwd.getpwuid(int(uid_field)).pw_name
        except (KeyError, ValueError):
            user = uid_field
        comm = read_comm(pid)
        argv = read_cmdline(pid)
        name = humanize(comm, argv)
        procs.append({"pid": pid, "user": user, "rss_bytes": rss_bytes, "name": name})
    return procs


def aggregate(procs: list[dict]) -> dict[tuple[str, str], int]:
    agg: dict[tuple[str, str], int] = {}
    for p in procs:
        key = (p["name"], p["user"])
        agg[key] = agg.get(key, 0) + p["rss_bytes"]
    return agg


def read_meminfo() -> dict[str, int]:
    out: dict[str, int] = {}
    raw = read_bytes("/proc/meminfo").decode("utf-8", "replace")
    for line in raw.splitlines():
        k, _, v = line.partition(":")
        parts = v.strip().split()
        if not parts:
            continue
        try:
            out[k.strip()] = int(parts[0]) * 1024
        except ValueError:
            continue
    return out


# --- minimal OTLP protobuf encoder ---------------------------------------
# Wire format reference: https://protobuf.dev/programming-guides/encoding/
# OTLP metrics schema:
#   https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/metrics/v1/metrics.proto


def _varint(n: int) -> bytes:
    out = bytearray()
    while n > 0x7F:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n & 0x7F)
    return bytes(out)


def _tag(field_number: int, wire_type: int) -> bytes:
    return _varint((field_number << 3) | wire_type)


def _len_delim(field_number: int, body: bytes) -> bytes:
    return _tag(field_number, 2) + _varint(len(body)) + body


def _string(field_number: int, value: str) -> bytes:
    return _len_delim(field_number, value.encode("utf-8"))


def _fixed64(field_number: int, value: int) -> bytes:
    # Used for fixed64 (unsigned) and sfixed64 (signed); both are 8 bytes LE.
    return _tag(field_number, 1) + value.to_bytes(8, "little", signed=value < 0)


def _any_value(s: str) -> bytes:
    # AnyValue { string string_value = 1; }
    return _string(1, s)


def _key_value(key: str, value: str) -> bytes:
    # KeyValue { string key = 1; AnyValue value = 2; }
    return _string(1, key) + _len_delim(2, _any_value(value))


def _number_data_point(attrs: list[tuple[str, str]], ts_ns: int, value: int) -> bytes:
    # NumberDataPoint {
    #   repeated KeyValue attributes = 7;
    #   fixed64 time_unix_nano = 3;
    #   sfixed64 as_int = 6;
    # }
    body = b""
    for k, v in attrs:
        body += _len_delim(7, _key_value(k, v))
    body += _fixed64(3, ts_ns)
    body += _fixed64(6, value)
    return body


def _gauge(points: list[bytes]) -> bytes:
    # Gauge { repeated NumberDataPoint data_points = 1; }
    return b"".join(_len_delim(1, p) for p in points)


def _metric(name: str, unit: str, gauge_body: bytes) -> bytes:
    # Metric { string name = 1; string unit = 3; Gauge gauge = 5; }
    return _string(1, name) + _string(3, unit) + _len_delim(5, gauge_body)


def _scope_metrics(scope_name: str, scope_version: str, metrics: list[bytes]) -> bytes:
    # ScopeMetrics { InstrumentationScope scope = 1; repeated Metric metrics = 2; }
    scope = _string(1, scope_name) + _string(2, scope_version)
    body = _len_delim(1, scope)
    for m in metrics:
        body += _len_delim(2, m)
    return body


def _resource(attrs: list[tuple[str, str]]) -> bytes:
    # Resource { repeated KeyValue attributes = 1; }
    return b"".join(_len_delim(1, _key_value(k, v)) for k, v in attrs)


def _resource_metrics(resource_body: bytes, scope_metrics_body: bytes) -> bytes:
    # ResourceMetrics { Resource resource = 1; repeated ScopeMetrics scope_metrics = 2; }
    return _len_delim(1, resource_body) + _len_delim(2, scope_metrics_body)


def build_protobuf(
    agg: dict[tuple[str, str], int], meminfo: dict[str, int], top_n: int
) -> bytes:
    ts_ns = time.time_ns()
    items = sorted(agg.items(), key=lambda kv: kv[1], reverse=True)[:top_n]

    proc_points = [
        _number_data_point(
            [
                ("process.name", name),
                ("process.user", user),
                ("host.name", HOSTNAME),
            ],
            ts_ns,
            rss,
        )
        for (name, user), rss in items
    ]
    metrics_bodies = [_metric("process.memory.rss_bytes", "By", _gauge(proc_points))]

    state_keys = {
        "total": "MemTotal",
        "available": "MemAvailable",
        "free": "MemFree",
        "buffers": "Buffers",
        "cached": "Cached",
    }
    mem_points = [
        _number_data_point(
            [("state", state), ("host.name", HOSTNAME)], ts_ns, meminfo[k]
        )
        for state, k in state_keys.items()
        if k in meminfo
    ]
    if mem_points:
        metrics_bodies.append(_metric("system.memory.bytes", "By", _gauge(mem_points)))

    scope_body = _scope_metrics("process-memory-heartbeat", "1.0", metrics_bodies)
    resource_body = _resource(
        [
            ("host.name", HOSTNAME),
            ("service.name", "process-memory-heartbeat"),
        ]
    )
    rm_body = _resource_metrics(resource_body, scope_body)
    # ExportMetricsServiceRequest { repeated ResourceMetrics resource_metrics = 1; }
    return _len_delim(1, rm_body)


def post_otlp(url: str, body: bytes, timeout: float = 5.0) -> tuple[int | None, bytes]:
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/x-protobuf"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, TimeoutError, socket.timeout) as e:
        return None, str(e).encode()


def render_table(agg: dict[tuple[str, str], int], top_n: int) -> str:
    items = sorted(agg.items(), key=lambda kv: kv[1], reverse=True)[:top_n]
    lines = [f"{'MiB':>9}  {'user':<10}  process"]
    for (name, user), rss in items:
        lines.append(f"{rss / 1024 / 1024:9.1f}  {user:<10}  {name}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="process memory heartbeat -> vmsingle (OTLP)")
    parser.add_argument("--url", default=os.environ.get("VMSINGLE_OTLP_URL", DEFAULT_URL))
    parser.add_argument(
        "--top", type=int, default=int(os.environ.get("PROCESS_TOP_N", DEFAULT_TOP_N))
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print humanized table + OTLP payload, skip POST",
    )
    args = parser.parse_args()

    procs = collect_processes()
    agg = aggregate(procs)
    meminfo = read_meminfo()
    payload = build_protobuf(agg, meminfo, args.top)

    if args.dry_run:
        sys.stdout.write(render_table(agg, args.top) + "\n\n")
        sys.stdout.write(f"OTLP protobuf payload: {len(payload)} bytes\n")
        return 0

    status, body = post_otlp(args.url, payload)
    if status is None or status >= 400:
        sys.stderr.write(
            f"process-memory-heartbeat: OTLP POST failed status={status} body={body[:200]!r}\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
