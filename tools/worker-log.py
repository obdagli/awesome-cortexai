#!/usr/bin/env python3
"""Worker activity tracking system. JSONL-based logging + status board."""

import json
import os
import re
import sys
import argparse
from datetime import datetime, timezone, timedelta
from pathlib import Path

LOG_FILE = Path(__file__).parent / "worker-log.jsonl"
CB_FILE = Path(__file__).parent / "circuit_breaker.json"


def _now():
    return datetime.now(timezone.utc).isoformat()


def _append(entry: dict):
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")


def _read_all() -> list[dict]:
    if not LOG_FILE.exists():
        return []
    entries = []
    with open(LOG_FILE) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return entries


# ── Logging ──────────────────────────────────────────────────────────

def _sanitize_label(label: str) -> str:
    """Truncate to 64 chars, strip newlines and special chars."""
    label = re.sub(r'[\n\r\t]+', '-', label)
    label = re.sub(r'[^a-zA-Z0-9._-]', '-', label)
    label = re.sub(r'-{2,}', '-', label)
    label = label.strip('-')
    return label[:64]


def log_spawn(label: str, task_summary: str, model: str, profile: str, role: str, timeout: int) -> dict:
    label = _sanitize_label(label)
    entry = {
        "event": "spawn",
        "timestamp": _now(),
        "label": label,
        "task_summary": task_summary,
        "model": model,
        "profile": profile,
        "role": role,
        "timeout": timeout,
    }
    _append(entry)
    return entry


def log_complete(label: str, status: str, duration: float, tokens_in: int, tokens_out: int, outcome_summary: str) -> dict:
    label = _sanitize_label(label)
    entry = {
        "event": "complete",
        "timestamp": _now(),
        "label": label,
        "status": status,
        "duration": duration,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "outcome_summary": outcome_summary,
    }
    _append(entry)
    return entry


def log_fail(label: str, error: str, duration: float) -> dict:
    label = _sanitize_label(label)
    entry = {
        "event": "fail",
        "timestamp": _now(),
        "label": label,
        "error": error,
        "duration": duration,
    }
    _append(entry)
    return entry


# ── Status Board ─────────────────────────────────────────────────────

def get_active() -> list[dict]:
    entries = _read_all()
    spawned = {}
    finished = set()

    for e in entries:
        if e["event"] == "spawn":
            spawned[e["label"]] = e
        elif e["event"] in ("complete", "fail"):
            finished.add(e["label"])

    return [v for k, v in spawned.items() if k not in finished]


def get_recent(hours: int = 4) -> list[dict]:
    entries = _read_all()
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    results = []
    for e in entries:
        if e["event"] in ("complete", "fail"):
            ts = datetime.fromisoformat(e["timestamp"])
            if ts >= cutoff:
                results.append(e)
    return results


def get_today_stats() -> dict:
    entries = _read_all()
    today = datetime.now(timezone.utc).date()

    spawns = 0
    successes = 0
    fails = 0
    timeouts = 0
    durations = []
    total_tokens = 0

    for e in entries:
        ts = datetime.fromisoformat(e["timestamp"]).date()
        if ts != today:
            continue

        if e["event"] == "spawn":
            spawns += 1
        elif e["event"] == "complete":
            successes += 1
            durations.append(e.get("duration", 0))
            total_tokens += e.get("tokens_in", 0) + e.get("tokens_out", 0)
        elif e["event"] == "fail":
            if "timeout" in e.get("error", "").lower():
                timeouts += 1
            else:
                fails += 1
            durations.append(e.get("duration", 0))

    completed = successes + fails + timeouts
    compliance_rate = round(successes / completed * 100, 1) if completed > 0 else 100.0
    avg_duration = round(sum(durations) / len(durations), 1) if durations else 0.0

    return {
        "total_spawns": spawns,
        "success_count": successes,
        "fail_count": fails,
        "timeout_count": timeouts,
        "avg_duration": avg_duration,
        "total_tokens": total_tokens,
        "compliance_rate": compliance_rate,
    }


def _read_circuit_breaker() -> dict:
    if not CB_FILE.exists():
        return {}
    try:
        with open(CB_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def format_status_board() -> str:
    lines = []
    lines.append("📊 Worker Status Board")
    lines.append("")

    active = get_active()
    if active:
        lines.append(f"🔴 Active Workers ({len(active)})")
        for w in active:
            elapsed = datetime.now(timezone.utc) - datetime.fromisoformat(w["timestamp"])
            mins = int(elapsed.total_seconds() // 60)
            secs = int(elapsed.total_seconds() % 60)
            lines.append(f"  ⚙️ {w['label']} — {w.get('role', '?')} ({w.get('model', '?')}) {mins}m{secs}s")
            lines.append(f"     {w.get('task_summary', '')[:80]}")
    else:
        lines.append("🟢 No active workers")
    lines.append("")

    recent = get_recent(hours=2)
    if recent:
        lines.append(f"✅ Recent ({len(recent)} in last 2h)")
        for r in recent[-5:]:
            icon = "✅" if r.get("status") == "success" else "❌"
            dur = r.get("duration", 0)
            summary = r.get("outcome_summary", r.get("error", ""))[:60]
            lines.append(f"  {icon} {r['label']} — {dur}s — {summary}")
    else:
        lines.append("📭 No recent completions")
    lines.append("")

    stats = get_today_stats()
    lines.append("📈 Today's KPIs")
    lines.append(f"  Spawns: {stats['total_spawns']}  ✅ {stats['success_count']}  ❌ {stats['fail_count']}  ⏰ {stats['timeout_count']}")
    lines.append(f"  Avg duration: {stats['avg_duration']}s")
    lines.append(f"  Tokens: {stats['total_tokens']:,}")
    lines.append(f"  Success rate: {stats['compliance_rate']}%")
    lines.append("")

    cb = _read_circuit_breaker()
    if cb:
        lines.append("🔌 Circuit Breakers")
        for cat, state in cb.items():
            icon = "🟢" if state.get("state") == "closed" else "🔴"
            lines.append(f"  {icon} {cat}: {state.get('state', '?')} (fails: {state.get('failures', 0)})")

    return "\n".join(lines)


# ── CLI ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Worker activity tracker")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status", help="Print status board")
    sub.add_parser("today", help="Print today's stats")

    sp = sub.add_parser("log-spawn", help="Log worker spawn")
    sp.add_argument("--label", required=True)
    sp.add_argument("--task", required=True)
    sp.add_argument("--model", default="unknown")
    sp.add_argument("--profile", default="full")
    sp.add_argument("--role", default="worker")
    sp.add_argument("--timeout", type=int, default=600)

    cp = sub.add_parser("log-complete", help="Log worker completion")
    cp.add_argument("--label", required=True)
    cp.add_argument("--status", required=True)
    cp.add_argument("--duration", type=float, default=0)
    cp.add_argument("--tokens-in", type=int, default=0)
    cp.add_argument("--tokens-out", type=int, default=0)
    cp.add_argument("--outcome", default="")

    fp = sub.add_parser("log-fail", help="Log worker failure")
    fp.add_argument("--label", required=True)
    fp.add_argument("--error", required=True)
    fp.add_argument("--duration", type=float, default=0)

    args = parser.parse_args()

    if args.command == "status":
        print(format_status_board())
    elif args.command == "today":
        stats = get_today_stats()
        for k, v in stats.items():
            print(f"  {k}: {v}")
    elif args.command == "log-spawn":
        log_spawn(args.label, args.task, args.model, args.profile, args.role, args.timeout)
        print(f"Logged spawn: {args.label}")
    elif args.command == "log-complete":
        log_complete(args.label, args.status, args.duration, args.tokens_in, args.tokens_out, args.outcome)
        print(f"Logged complete: {args.label}")
    elif args.command == "log-fail":
        log_fail(args.label, args.error, args.duration)
        print(f"Logged fail: {args.label}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
