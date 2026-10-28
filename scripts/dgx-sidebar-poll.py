#!/usr/bin/env python3
"""
SparkDash fleet poller for the Aiden DGX sidebar artifact.

Fetches GET /api/sparks from a sparkDash server, reduces each Spark /
GPU-host snapshot to a compact fleet record, and prints JSON the artifact
binds as $fleet. Designed for a shell source: fast, read-only, one
argument (the base URL).

Exit codes:
  0  success (even if the server is unreachable — the JSON says so)
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

DEFAULT_URL = os.environ.get("SPARKDASH_URL", "http://localhost:5555")
POLL_TIMEOUT = 8  # seconds; the artifact shell source has a 30s cap


def http_get_json(base, path):
    url = base.rstrip("/") + path
    req = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "aiden-dgx-sidebar/1.0"}
    )
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def num(value):
    """Coerce to float, or None if missing/non-numeric."""
    if isinstance(value, bool) or value is None:
        return None
    try:
        f = float(value)
        return f if f == f and f not in (float("inf"), float("-inf")) else None
    except (TypeError, ValueError):
        return None


def first_num(*values):
    for v in values:
        n = num(v)
        if n is not None:
            return n
    return None


def fmt_rate(bytes_per_second):
    """Bytes/sec → (value, unit) for compact display."""
    n = num(bytes_per_second)
    if n is None:
        return None
    if abs(n) >= 1_000_000_000:
        return round(n / 1_000_000_000, 2), "GB/s"
    if abs(n) >= 1_000_000:
        return round(n / 1_000_000, 1), "MB/s"
    if abs(n) >= 1_000:
        return round(n / 1_000, 1), "KB/s"
    return round(n, 2), "B/s"


def reduce_spark(s):
    """One sparkDash SparkSnapshot → compact sidebar record."""
    m = s.get("metrics") or {}
    kind = (s.get("kind") or "spark").lower()
    is_host = kind == "host"

    gpu = m.get("gpu") or {}
    vram = gpu.get("vram") or {}
    cpu = m.get("cpu") or {}
    ram = m.get("ram") or {}
    um = m.get("unifiedMemory") or {}
    net = m.get("network") or {}

    # memory: GPU hosts prefer VRAM, Sparks prefer unified memory
    if is_host:
        mem_used = first_num(vram.get("used"), ram.get("used"), um.get("used"))
        mem_total = first_num(vram.get("total"), ram.get("total"), um.get("total"))
        mem_pct = first_num(vram.get("percentage"), ram.get("percentage"), um.get("percentage"))
        mem_noun = "VRAM"
    else:
        mem_used = first_num(um.get("used"), ram.get("used"), vram.get("used"))
        mem_total = first_num(um.get("total"), ram.get("total"), vram.get("total"))
        mem_pct = first_num(um.get("percentage"), ram.get("percentage"), vram.get("percentage"))
        mem_noun = "unified"

    if mem_used is not None and mem_total:
        mem_used_gb = round(mem_used / 1024, 1)
        mem_total_gb = round(mem_total / 1024, 1)
    else:
        mem_used_gb = mem_total_gb = None

    if mem_pct is None and mem_used is not None and mem_total:
        mem_pct = round(100.0 * mem_used / mem_total, 1)
    if mem_pct is not None:
        mem_pct = round(mem_pct, 1)

    # LLM instances
    llms = []
    for l in m.get("llm") or []:
        if not isinstance(l, dict):
            continue
        if l.get("available") is False:
            continue
        gen = first_num(l.get("generationTps"), l.get("generationTokensPerSecond"))
        pre = first_num(l.get("prefillTps"), l.get("prefillTokensPerSecond"))
        llms.append(
            {
                "backend": str(l.get("backend") or "llm"),
                "model": str(l.get("modelId") or l.get("model") or l.get("modelName") or "?"),
                "gen_tps": gen,
                "prefill_tps": pre,
                "running": num(l.get("requestsRunning")),
                "waiting": num(l.get("requestsWaiting")),
                "kv_pct": round(first_num(l.get("kvCacheUsage"), l.get("kvCacheUtilization")) or 0, 1),
                "ttft_p95": first_num(l.get("ttftP95Seconds"), l.get("ttftP95")),
                "port": l.get("port"),
            }
        )
    llm_active = [
        l for l in llms if (l["gen_tps"] or 0) + (l["prefill_tps"] or 0) > 0
    ]
    llm_busy = any(
        (l["running"] or 0) > 0 or (l["waiting"] or 0) > 0 for l in llms
    )

    # ComfyUI
    comfy = m.get("comfy") or {}
    comfy_ok = comfy.get("available") is True
    comfy_active = bool(comfy_ok and ((comfy.get("queueRunning") or 0) > 0 or comfy.get("activeJob")))
    comfy_rec = None
    if comfy_ok:
        prog = comfy.get("progress") or {}
        comfy_rec = {
            "active": comfy_active,
            "queue_pending": comfy.get("queuePending") or 0,
            "job": str((comfy.get("activeJob") or {}).get("title") or "ComfyUI job"),
            "pct": round(first_num(prog.get("percent")) or 0, 0),
            "eta_min": round((num(comfy.get("queueEtaMs")) or 0) / 60000, 1) or None,
        }

    # throttle / alerts
    thr = gpu.get("throttle") or {}
    alerts = []
    if thr.get("thermal"):
        alerts.append("thermal throttling")
    if thr.get("hwSlowdown"):
        alerts.append("HW slowdown")
    if thr.get("powerCap"):
        alerts.append("power cap")
    if um.get("oomRisk") and str(um.get("oomRisk")).lower() not in ("none", "ok", "healthy"):
        alerts.append("OOM risk: " + str(um.get("oomRisk")))
    if (gpu.get("temperature") or 0) >= 90:
        alerts.append(f"hot GPU {int(gpu['temperature'])}°C")
    if ram.get("percentage") is not None and (ram.get("percentage") or 0) >= 90:
        alerts.append("RAM pressure")

    status = "offline" if s.get("online") is False else "online"
    if alerts:
        status = "warning"

    rx = net.get("rxSpeed") or 0
    tx = net.get("txSpeed") or 0

    def speed(v):
        r = fmt_rate(v)
        return {"val": r[0], "unit": r[1]} if r else {"val": 0.0, "unit": "B/s"}

    return {
        "id": str(s.get("id") or s.get("name") or "?"),
        "name": str(s.get("name") or "unnamed"),
        "kind": "GPU host" if is_host else "DGX Spark",
        "ip": str(s.get("lanIp") or "—"),
        "status": status,
        "online": s.get("online") is not False,
        "uptime_h": round((num(s.get("uptime")) or 0) / 3600, 1) or None,
        "gpu_pct": round(first_num(gpu.get("usage")) or 0, 0),
        "gpu_temp": round(first_num(gpu.get("temperature")) or 0, 0) or None,
        "gpu_power_w": round(first_num((gpu.get("power") or {}).get("draw")) or 0, 0) or None,
        "gpu_power_cap": round(first_num((gpu.get("power") or {}).get("limit")) or 0, 0) or None,
        "cpu_pct": round(first_num(cpu.get("usage")) or 0, 0),
        "mem_pct": mem_pct or 0,
        "mem_used_gb": mem_used_gb,
        "mem_total_gb": mem_total_gb,
        "mem_noun": mem_noun,
        "rx": speed(rx),
        "tx": speed(tx),
        "llm": llms,
        "llm_busy": llm_busy or bool(llm_active),
        "comfy": comfy_rec,
        "alerts": alerts,
    }


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_URL
    now = int(time.time())
    try:
        payload = http_get_json(base, "/api/sparks")
        sparks = payload.get("sparks") if isinstance(payload, dict) else payload
        if not isinstance(sparks, list):
            sparks = []
        # GET /api/sparks is configuration-only (no `metrics` block), so each
        # Spark is enriched from its GET /api/sparks/:id/metrics snapshot —
        # the same fallback path SparkBar uses when the WS stream is blocked.
        fleet = []
        for s in sparks:
            if not isinstance(s, dict):
                continue
            sid = s.get("id")
            if sid:
                try:
                    snap = http_get_json(base, "/api/sparks/" + urllib.parse.quote(str(sid), safe="") + "/metrics")
                    if isinstance(snap, dict) and "metrics" in snap:
                        s = {**snap, **{k: v for k, v in s.items() if k not in snap}}
                except Exception:
                    pass  # keep configuration data; metrics stay absent
            fleet.append(reduce_spark(s))
        out = {
            "ok": True,
            "endpoint": base,
            "fetched_at": now,
            "error": None,
            "sparks": fleet,
            "summary": {
                "total": len(fleet),
                "online": sum(1 for s in fleet if s["online"]),
                "busy": sum(1 for s in fleet if s["gpu_pct"] > 5 or s["llm_busy"] or s["comfy"]),
                "alerts": sum(1 for s in fleet if s["alerts"]),
            },
        }
    except Exception as exc:  # connection refused, timeout, bad JSON…
        out = {
            "ok": False,
            "endpoint": base,
            "fetched_at": now,
            "error": f"{type(exc).__name__}: {exc}"[:200],
            "sparks": [],
            "summary": {"total": 0, "online": 0, "busy": 0, "alerts": 0},
        }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
