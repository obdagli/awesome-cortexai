#!/usr/bin/env python3
"""Dynamic provider router with real-time quota awareness.

Commands:
  python3 provider-router.py status
  python3 provider-router.py select <tier>
  python3 provider-router.py check-health
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests

PROVIDERS: Dict[str, Dict[str, Any]] = {
    "claude.gg": {
        "usage_url": "https://claude.gg/api/me?key={key}",
        "env_key": "APP_CLAUDE_KEY",
        "daily_limit": 2500,
        "hourly_limit": None,
        "models": ["claude-sonnet-4-5", "claude-opus-4-5"],
        "tier": "claude-standard",
    },
    "app.claude.gg": {
        "usage_url": "https://app.claude.gg/api/me?key={key}",
        "env_key": "APP_CLAUDE_KEY",
        "daily_limit": 1000,
        "hourly_limit": 450,
        "models": [
            "claude-opus-4-6",
            "claude-sonnet-4-6",
            "claude-sonnet-4-5",
            "claude-haiku-4-5",
        ],
        "tier": "claude-premium",
    },
    "beta.vertexapis.com": {
        "usage_url": "https://beta.vertexapis.com/api/me?key={key}",
        "env_key": "VERTEX_API_KEY",
        "daily_limit": 3500,
        "hourly_limit": 450,
        "models": ["gemini-2.5-flash", "gemini-3-pro"],
        "tier": "gemini",
    },
    "img.claude.gg": {
        "usage_url": "https://img.claude.gg/api/me",
        "auth_header": True,
        "env_key": "APP_CLAUDE_KEY",
        "daily_limit": 1000,
        "hourly_limit": 400,
        "models": ["image-generation"],
        "tier": "image",
    },
    "codex.claude.gg": {
        "usage_url": "https://codex.claude.gg/api/me?key={key}",
        "env_key": "APP_CLAUDE_KEY",
        "daily_limit": 5000,
        "hourly_limit": 5000,
        "models": ["gpt-5.2-codex", "gpt-5.3-codex"],
        "tier": "codex",
    },
    "perplexity.claude.gg": {
        "usage_url": "https://perplexity.claude.gg/api/me",
        "auth_header": True,
        "env_key": "APP_CLAUDE_KEY",
        "daily_limit": 3000,
        "hourly_limit": 700,
        "models": ["perplexity-search"],
        "tier": "search",
    },
    "gateai": {
        "usage_url": "https://api.gateai.app/api/me?key={key}",
        "env_key": "GATE_API_KEY",
        "daily_limit": 150,
        "hourly_limit": None,
        "models": ["gpt-5.2-codex", "gpt-5.3-codex"],
        "tier": "codex-fallback",
    },
}

STATUS_STREAM_URL = "https://cortexai.com.tr/api/status/stream"
TIMEOUT_SECONDS = 12

# Fallbacks by tier family. Primary key is requested tier.
TIER_FALLBACKS: Dict[str, List[str]] = {
    "codex": ["codex-fallback"],
    "codex-fallback": ["codex"],
    "claude-premium": ["claude-standard"],
    "claude-standard": ["claude-premium"],
}


@dataclass
class ProviderUsage:
    provider: str
    tier: str
    model: str
    healthy: bool
    used_daily: Optional[int]
    remaining_daily: Optional[int]
    remaining_pct: Optional[int]
    error: Optional[str] = None


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def env_value(name: str) -> Optional[str]:
    v = os.getenv(name)
    if not v:
        return None
    return v.strip()


def _safe_int(v: Any) -> Optional[int]:
    if v is None:
        return None
    try:
        if isinstance(v, bool):
            return None
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _iter_pairs(obj: Any, prefix: str = "") -> Iterable[Tuple[str, Any]]:
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = f"{prefix}.{k}" if prefix else str(k)
            yield p.lower(), v
            yield from _iter_pairs(v, p)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            p = f"{prefix}[{i}]"
            yield from _iter_pairs(v, p)


def extract_daily_used(payload: Any, daily_limit: int) -> Optional[int]:
    """Best-effort parser for daily usage from heterogeneous /api/me payloads."""
    if not isinstance(payload, (dict, list)):
        return None

    exact_used_keys = {
        "daily_used",
        "dailyusage",
        "daily_usage",
        "used_today",
        "requests_today",
        "today_used",
    }
    exact_remaining_keys = {
        "daily_remaining",
        "remaining_today",
        "requests_remaining",
        "today_remaining",
    }

    best_used: Optional[int] = None
    best_remaining: Optional[int] = None

    for key, value in _iter_pairs(payload):
        val = _safe_int(value)
        if val is None:
            continue

        token = re.sub(r"[^a-z0-9_]", "", key)

        if token in exact_used_keys:
            return max(0, val)

        if token in exact_remaining_keys:
            best_remaining = val
            continue

        if "daily" in token and any(w in token for w in ("used", "usage", "count", "request", "spent")):
            best_used = val if best_used is None else max(best_used, val)
            continue

        if "today" in token and any(w in token for w in ("used", "usage", "count", "request", "spent")):
            best_used = val if best_used is None else max(best_used, val)
            continue

        if any(w in token for w in ("remaining", "left")) and any(w in token for w in ("daily", "today", "request")):
            best_remaining = val if best_remaining is None else max(best_remaining, val)

    if best_used is not None:
        return max(0, best_used)

    if best_remaining is not None:
        return max(0, daily_limit - best_remaining)

    return None


def fetch_usage(provider: str, cfg: Dict[str, Any]) -> ProviderUsage:
    env_key = cfg["env_key"]
    key = env_value(env_key)
    model = cfg["models"][0]
    tier = cfg["tier"]
    daily_limit = int(cfg["daily_limit"])

    if not key:
        return ProviderUsage(
            provider=provider,
            tier=tier,
            model=model,
            healthy=False,
            used_daily=None,
            remaining_daily=None,
            remaining_pct=None,
            error=f"missing ${env_key}",
        )

    usage_url = cfg["usage_url"]
    headers: Dict[str, str] = {"Accept": "application/json"}

    if cfg.get("auth_header"):
        url = usage_url
        headers["Authorization"] = f"Bearer {key}"
    else:
        url = usage_url.format(key=key)

    try:
        resp = requests.get(url, headers=headers, timeout=TIMEOUT_SECONDS)
    except requests.RequestException as e:
        return ProviderUsage(
            provider=provider,
            tier=tier,
            model=model,
            healthy=False,
            used_daily=None,
            remaining_daily=None,
            remaining_pct=None,
            error=str(e),
        )

    if resp.status_code != 200:
        return ProviderUsage(
            provider=provider,
            tier=tier,
            model=model,
            healthy=False,
            used_daily=None,
            remaining_daily=None,
            remaining_pct=None,
            error=f"http {resp.status_code}",
        )

    try:
        payload = resp.json()
    except ValueError:
        return ProviderUsage(
            provider=provider,
            tier=tier,
            model=model,
            healthy=False,
            used_daily=None,
            remaining_daily=None,
            remaining_pct=None,
            error="invalid json",
        )

    used_daily = extract_daily_used(payload, daily_limit)
    if used_daily is None:
        # Endpoint is alive; usage shape is unknown.
        return ProviderUsage(
            provider=provider,
            tier=tier,
            model=model,
            healthy=True,
            used_daily=None,
            remaining_daily=None,
            remaining_pct=None,
            error="usage field not found",
        )

    used_daily = max(0, min(daily_limit, used_daily))
    remaining_daily = max(0, daily_limit - used_daily)
    remaining_pct = int(round((remaining_daily / daily_limit) * 100))

    return ProviderUsage(
        provider=provider,
        tier=tier,
        model=model,
        healthy=True,
        used_daily=used_daily,
        remaining_daily=remaining_daily,
        remaining_pct=remaining_pct,
    )


def all_statuses() -> List[ProviderUsage]:
    results = [fetch_usage(name, cfg) for name, cfg in PROVIDERS.items()]
    # Deterministic order close to requested sample
    order = [
        "codex.claude.gg",
        "app.claude.gg",
        "beta.vertexapis.com",
        "img.claude.gg",
        "claude.gg",
        "perplexity.claude.gg",
        "gateai",
    ]
    rank = {name: i for i, name in enumerate(order)}
    results.sort(key=lambda x: rank.get(x.provider, 999))
    return results


def _display_name(provider: str) -> str:
    if provider == "perplexity.claude.gg":
        return "perplexity.gg"
    if provider == "beta.vertexapis.com":
        return "beta.vertexapis"
    return provider


def cmd_status() -> int:
    statuses = all_statuses()

    print(f"Provider Status ({utc_now()})")
    print("━" * 37)

    total_remaining = 0
    underutilized: List[str] = []

    for s in statuses:
        icon = "✅" if s.healthy else "⚠️"
        name = _display_name(s.provider)
        limit = PROVIDERS[s.provider]["daily_limit"]

        if s.used_daily is None or s.remaining_pct is None or s.remaining_daily is None:
            usage_txt = f"?/{limit} daily"
            rem_txt = "unknown remaining"
        else:
            usage_txt = f"{s.used_daily}/{limit} daily"
            rem_txt = f"{s.remaining_pct}% remaining"
            total_remaining += s.remaining_daily
            used_pct = 100 - s.remaining_pct
            if used_pct <= 5:
                underutilized.append(f"{name} ({used_pct}%)")

        line = f"{name:<18} {icon} {usage_txt:>14}  ({rem_txt})"
        if s.error and s.used_daily is None:
            line += f"  [{s.error}]"
        print(line)

    print("━" * 37)
    print(f"Total capacity remaining: ~{total_remaining:,} requests")
    if underutilized:
        print(f"Underutilized: {', '.join(underutilized)}")
    else:
        print("Underutilized: none")

    return 0


def _candidate_providers_for_tier(tier: str) -> List[str]:
    direct = [name for name, cfg in PROVIDERS.items() if cfg["tier"] == tier]
    if direct:
        return direct

    providers: List[str] = []
    seen = set()

    def add_for_t(t: str) -> None:
        for p, cfg in PROVIDERS.items():
            if cfg["tier"] == t and p not in seen:
                seen.add(p)
                providers.append(p)

    add_for_t(tier)
    for fb in TIER_FALLBACKS.get(tier, []):
        add_for_t(fb)

    return providers


def cmd_select(tier: str) -> int:
    candidates = _candidate_providers_for_tier(tier)
    if not candidates:
        print(f"ERROR: Unknown tier '{tier}'", file=sys.stderr)
        return 1

    usages = [fetch_usage(name, PROVIDERS[name]) for name in candidates]

    healthy_with_headroom = [
        u for u in usages if u.healthy and u.remaining_pct is not None and u.remaining_pct > 10
    ]
    if healthy_with_headroom:
        best = max(healthy_with_headroom, key=lambda u: (u.remaining_pct or -1, u.remaining_daily or -1))
        print(best.model)
        return 0

    healthy_any = [u for u in usages if u.healthy and u.remaining_pct is not None]
    if healthy_any:
        best = max(healthy_any, key=lambda u: (u.remaining_pct or -1, u.remaining_daily or -1))
        print(f"{best.model}  # WARNING: all candidates <=10% remaining")
        return 0

    # Last resort: provider reachable but usage unknown
    reachable_unknown = [u for u in usages if u.healthy]
    if reachable_unknown:
        best = reachable_unknown[0]
        print(f"{best.model}  # WARNING: usage unknown, selecting best available")
        return 0

    # Final fallback: return first model anyway as requested
    fallback = usages[0]
    print(f"{fallback.model}  # WARNING: all providers exhausted/unhealthy")
    return 0


def _extract_services_from_payload(payload: Any) -> List[Tuple[str, str]]:
    bad_states = {"degraded", "down", "outage", "major_outage", "partial_outage", "incident"}
    findings: List[Tuple[str, str]] = []

    if isinstance(payload, dict):
        if "services" in payload and isinstance(payload["services"], list):
            for s in payload["services"]:
                if not isinstance(s, dict):
                    continue
                name = str(s.get("name") or s.get("service") or "unknown")
                status = str(s.get("status") or s.get("state") or "unknown").lower()
                if status in bad_states:
                    findings.append((name, status))

        for k, v in payload.items():
            if isinstance(v, dict):
                status = str(v.get("status") or v.get("state") or "").lower()
                if status in bad_states:
                    findings.append((str(v.get("name") or k), status))

    return findings


def cmd_check_health() -> int:
    token = env_value("APP_CLAUDE_KEY")
    if not token:
        print("ERROR: missing $APP_CLAUDE_KEY", file=sys.stderr)
        return 1

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "text/event-stream, application/json, text/plain",
    }

    try:
        resp = requests.get(STATUS_STREAM_URL, headers=headers, timeout=TIMEOUT_SECONDS)
    except requests.RequestException as e:
        print(f"ERROR: health stream request failed: {e}", file=sys.stderr)
        return 1

    if resp.status_code != 200:
        print(f"ERROR: health stream http {resp.status_code}", file=sys.stderr)
        return 1

    text = resp.text.strip()
    findings: List[Tuple[str, str]] = []

    # Try JSON body first
    try:
        payload = resp.json()
        findings = _extract_services_from_payload(payload)
    except ValueError:
        # Parse SSE/plain lines
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            if line.startswith("data:"):
                line = line[5:].strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
                findings.extend(_extract_services_from_payload(payload))
                continue
            except ValueError:
                pass

            low = line.lower()
            if any(flag in low for flag in ("degraded", "down", "outage", "incident")):
                findings.append(("status-stream", line))

    # Deduplicate while preserving order
    seen = set()
    unique: List[Tuple[str, str]] = []
    for item in findings:
        if item in seen:
            continue
        seen.add(item)
        unique.append(item)

    if not unique:
        print("All services healthy ✅")
        return 0

    print("Degraded services detected:")
    for name, status in unique:
        print(f"- {name}: {status}")
    return 1


def usage() -> None:
    print(
        "Usage:\n"
        "  python3 provider-router.py status\n"
        "  python3 provider-router.py select <tier>\n"
        "  python3 provider-router.py check-health"
    )


def main() -> int:
    if len(sys.argv) < 2:
        usage()
        return 1

    cmd = sys.argv[1].strip().lower()

    if cmd == "status":
        return cmd_status()
    if cmd == "select":
        if len(sys.argv) < 3:
            print("ERROR: missing tier", file=sys.stderr)
            return 1
        return cmd_select(sys.argv[2].strip())
    if cmd == "check-health":
        return cmd_check_health()

    usage()
    return 1


if __name__ == "__main__":
    sys.exit(main())
