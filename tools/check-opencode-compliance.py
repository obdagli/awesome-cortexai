#!/usr/bin/env python3
"""Scan worker task logs for inline code violations (heredocs, cat >, echo >>)."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

VIOLATIONS = [
    ("heredoc", re.compile(r'<<[\s]*[\'"]?EOF', re.IGNORECASE)),
    ("heredoc", re.compile(r'<<[\s]*[\'"]?END', re.IGNORECASE)),
    ("cat_write", re.compile(r'cat\s+>+\s+\S+\.(ts|js|py|tsx|jsx|json|yaml|yml|sh|css|html)')),
    ("echo_append", re.compile(r'echo\s+[\'"].*[\'"]\s*>>?\s+\S+\.(ts|js|py|tsx|jsx|json|yaml|yml|sh|css|html)')),
    ("tee_write", re.compile(r'tee\s+(-a\s+)?\S+\.(ts|js|py|tsx|jsx|json|yaml|yml|sh|css|html)')),
    ("sed_inline", re.compile(r'sed\s+-i')),
    ("printf_redirect", re.compile(r'printf\s+.*>\s+\S+\.(ts|js|py|tsx|jsx|json|yaml|yml|sh|css|html)')),
]

OPENCODE_DISPATCH = re.compile(r'opencode-dispatch\.sh|opencode\s+run')

# Lines matching any allowlist pattern are not violations (e.g. dispatch wrapper context)
ALLOWLIST = [
    re.compile(r'opencode-dispatch\.sh'),
    re.compile(r'opencode\s+run'),
    re.compile(r'^\s*#'),  # shell comments
]

LOG_DIRS = [
    Path.home() / ".local" / "share" / "opencode" / "sessions",
    Path.home() / ".opencode" / "sessions",
    Path("/tmp") / "openclaw-logs",
]

MEMORY_DIR = Path.home() / "memory"


def _is_allowlisted(line: str) -> bool:
    return any(p.search(line) for p in ALLOWLIST)


def scan_text(text: str) -> tuple[list[dict], bool]:
    hits = []
    dispatch_found = False
    for line_num, line in enumerate(text.splitlines(), 1):
        if OPENCODE_DISPATCH.search(line):
            dispatch_found = True
        if _is_allowlisted(line):
            continue
        for vtype, pattern in VIOLATIONS:
            if pattern.search(line):
                hits.append({
                    "type": vtype,
                    "line": line_num,
                    "content": line.strip()[:120],
                })
    return hits, dispatch_found


def scan_file(path: Path) -> tuple[list[dict], bool]:
    try:
        text = path.read_text(errors="replace")
        hits, dispatch_found = scan_text(text)
        for h in hits:
            h["file"] = str(path)
        return hits, dispatch_found
    except OSError:
        return [], False


def find_log_files(max_age_hours: int = 24) -> list[Path]:
    import time
    cutoff = time.time() - (max_age_hours * 3600)
    files = []
    for d in LOG_DIRS:
        if not d.exists():
            continue
        for f in d.rglob("*"):
            if f.is_file() and f.stat().st_mtime > cutoff:
                files.append(f)
    for f in MEMORY_DIR.rglob("*.md"):
        if f.is_file() and f.stat().st_mtime > cutoff:
            files.append(f)
    return files


def scan_opencode_sessions(max_age_hours: int = 24) -> tuple[list[dict], int, int]:
    """Returns (hits, sessions_scanned, dispatch_count)."""
    import time
    cutoff = time.time() - (max_age_hours * 3600)

    try:
        result = subprocess.run(
            ["opencode", "session", "list", "--json"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            return [], 0, 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return [], 0, 0

    hits = []
    sessions_scanned = 0
    dispatch_count = 0

    lines = result.stdout.splitlines()
    for line in lines:
        parts = line.strip().split()
        if not parts:
            continue
        session_id = parts[0]

        # Try to extract timestamp from session listing to filter by age
        session_ts = None
        for part in parts[1:]:
            try:
                session_ts = float(part)
                break
            except ValueError:
                continue

        if session_ts is not None and session_ts < cutoff:
            continue

        try:
            export = subprocess.run(
                ["opencode", "export", session_id],
                capture_output=True, text=True, timeout=15,
            )
            if export.returncode == 0:
                sessions_scanned += 1
                session_hits, dispatch_found = scan_text(export.stdout)
                if dispatch_found:
                    dispatch_count += 1
                for h in session_hits:
                    h["file"] = f"session:{session_id}"
                hits.extend(session_hits)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue
    return hits, sessions_scanned, dispatch_count


def generate_report(all_hits: list[dict], total_scanned: int,
                    dispatch_count: int, total_sessions: int) -> dict:
    total = len(all_hits)
    by_type: dict[str, int] = {}
    for h in all_hits:
        by_type[h["type"]] = by_type.get(h["type"], 0) + 1

    top_patterns = sorted(by_type.items(), key=lambda x: -x[1])[:5]
    samples = all_hits[:10]

    compliance_rate = round(100.0 * max(0, 1 - total / max(total_scanned, 1)), 1)

    report: dict = {
        "total_scanned": total_scanned,
        "compliance_rate": compliance_rate,
        "violation_count": total,
        "top_patterns": [{"type": t, "count": c} for t, c in top_patterns],
        "sample_incidents": [
            {"type": h["type"], "file": h.get("file", "?"), "line": h["line"], "snippet": h["content"]}
            for h in samples
        ],
    }

    if total_sessions > 0:
        report["dispatch_usage"] = {
            "sessions_checked": total_sessions,
            "sessions_using_dispatch": dispatch_count,
            "dispatch_rate": round(100.0 * dispatch_count / total_sessions, 1),
        }

    return report


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Scan worker task logs for inline code violations.")
    parser.add_argument("--hours", type=int, default=24, help="Max age in hours (default: 24)")
    parser.add_argument("--gate", action="store_true",
                        help="Gate mode: exit 1 if violations found, exit 0 with COMPLIANCE_OK if clean")
    args = parser.parse_args()
    hours = args.hours

    all_hits = []
    total_scanned = 0
    file_dispatch_count = 0

    log_files = find_log_files(max_age_hours=hours)
    total_scanned += len(log_files)
    for f in log_files:
        file_hits, dispatch_found = scan_file(f)
        all_hits.extend(file_hits)
        if dispatch_found:
            file_dispatch_count += 1

    session_hits, sessions_scanned, session_dispatch_count = scan_opencode_sessions(max_age_hours=hours)
    all_hits.extend(session_hits)
    total_scanned += sessions_scanned

    report = generate_report(
        all_hits,
        total_scanned=total_scanned,
        dispatch_count=file_dispatch_count + session_dispatch_count,
        total_sessions=sessions_scanned,
    )

    if args.gate:
        if report["violation_count"] > 0:
            for h in all_hits:
                print(f"VIOLATION [{h['type']}] {h.get('file', '?')}:{h['line']}: {h['content']}", file=sys.stderr)
            sys.exit(1)
        else:
            print("COMPLIANCE_OK")
            sys.exit(0)

    print(json.dumps(report, indent=2))

    if report["violation_count"] > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
