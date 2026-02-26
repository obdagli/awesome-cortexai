#!/usr/bin/env python3
"""Zombie Worker Reaper — finds active workers past their timeout ceiling and marks them failed."""

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

LOG_FILE = Path(__file__).parent / "worker-log.jsonl"

# Timeout ceilings per task-type keyword (seconds)
TIMEOUT_CEILINGS = {
    "coding": 900,
    "code": 900,
    "impl": 900,
    "search": 300,
    "brave": 300,
    "general": 600,
}
DEFAULT_CEILING = 600  # fallback


def infer_ceiling(label: str, explicit_timeout: int | None) -> int:
    """Use explicit timeout from spawn entry if available, else infer from label."""
    if explicit_timeout and explicit_timeout > 0:
        return explicit_timeout
    label_lower = label.lower()
    for keyword, ceiling in TIMEOUT_CEILINGS.items():
        if keyword in label_lower:
            return ceiling
    return DEFAULT_CEILING


def read_log() -> list[dict]:
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


def find_active_workers(entries: list[dict]) -> dict:
    """Return dict of label -> spawn_entry for workers that are still active (spawned but not completed/failed)."""
    spawned = {}
    resolved = set()

    for e in entries:
        event = e.get("event")
        label = e.get("label", "")
        if event == "spawn":
            spawned[label] = e
        elif event in ("complete", "fail"):
            resolved.add(label)

    return {label: entry for label, entry in spawned.items() if label not in resolved}


def reap_zombie(label: str, duration: int):
    """Mark a zombie worker as failed via worker-log.py."""
    cmd = [
        sys.executable, str(Path(__file__).parent / "worker-log.py"),
        "log-fail",
        "--label", label,
        "--error", "reaped_zombie",
        "--duration", str(duration),
    ]
    subprocess.run(cmd, check=True)


def main():
    entries = read_log()
    active = find_active_workers(entries)
    now = datetime.now(timezone.utc)

    reaped = []

    for label, entry in active.items():
        spawn_time = datetime.fromisoformat(entry["timestamp"])
        elapsed = int((now - spawn_time).total_seconds())
        ceiling = infer_ceiling(label, entry.get("timeout"))

        if elapsed > ceiling:
            print(f"Reaping zombie: {label} (active {elapsed}s, ceiling {ceiling}s)")
            reap_zombie(label, elapsed)
            reaped.append({"label": label, "elapsed": elapsed, "ceiling": ceiling})

    if reaped:
        print(f"\n✂️  Reaped {len(reaped)} zombie worker(s):")
        for r in reaped:
            print(f"  - {r['label']}: {r['elapsed']}s (limit {r['ceiling']}s)")
    else:
        print("No zombie workers found. All clear.")


if __name__ == "__main__":
    main()
