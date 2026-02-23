#!/usr/bin/env python3
"""Provider Router — real-time quota awareness for all 7 providers.

Commands:
    status          Show all providers with health, latency, models, quota hints
    select MODEL    Pick best healthy provider for a model
    check-health    Run live health checks and update provider-health.json

Reads:
    provider-config.json   — provider definitions (urls, keys, models, priority)
    provider-health.json   — cached health state (written by check-health)
    ~/.openclaw/.env       — env vars for API keys (fallback)

Output: human-readable tables by default, --json for machine consumption.
"""
import json
import os
import sys
import time
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import requests
except ImportError:
    print("ERROR: requests not installed. Run: pip3 install requests", file=sys.stderr)
    sys.exit(1)

TOOLS_DIR = Path(__file__).resolve().parent
CONFIG_FILE = TOOLS_DIR / "provider-config.json"
HEALTH_FILE = TOOLS_DIR / "provider-health.json"
ENV_FILE = Path.home() / ".openclaw" / ".env"

# Quota hints per provider (daily request estimates from AGENTS.md + provider_registry.py)
QUOTA_HINTS: Dict[str, Dict[str, Any]] = {
    "anthropic": {
        "daily_limit": None,
        "note": "Local proxy (kiro :4040), no hard daily cap",
    },
    "app.claude.gg": {
        "daily_limit": None,
        "note": "OAuth subscription, soft rate limits apply",
    },
    "claude.gg": {
        "daily_limit": None,
        "note": "GateAI relay, shared quota with GATE_API_KEY",
    },
    "beta.claude.gg": {
        "daily_limit": None,
        "note": "GateAI relay (beta), shared quota with GATE_API_KEY",
    },
    "codex.claude.gg": {
        "daily_limit": 2500,
        "note": "Codex GPT-5.x, ~2500 req/day via GateAI relay",
    },
    "cliproxyapi": {
        "daily_limit": None,
        "note": "Local CLIProxyAPI (:8317), round-robin multi-account, quota per upstream",
    },
    "beta.vertexapis.com": {
        "daily_limit": 3500,
        "note": "Vertex Gemini native, ~3500 req/day free tier",
    },
}


def load_config() -> Dict[str, Any]:
    with open(CONFIG_FILE) as f:
        return json.load(f)


def load_env() -> Dict[str, str]:
    """Load env vars from os.environ + ~/.openclaw/.env fallback."""
    env = dict(os.environ)
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def resolve_key(cfg: Dict[str, Any], env: Dict[str, str]) -> Optional[str]:
    """Resolve API key from config entry."""
    if "key_literal" in cfg:
        return cfg["key_literal"]
    key_env = cfg.get("key_env")
    if key_env:
        return env.get(key_env) or None
    return None


def build_headers(cfg: Dict[str, Any], env: Dict[str, str]) -> Dict[str, str]:
    """Build request headers with proper auth for a provider."""
    headers: Dict[str, str] = {}
    key = resolve_key(cfg, env)
    if not key:
        return headers
    header_name = cfg.get("key_header", "Authorization")
    if header_name == "Authorization":
        headers["Authorization"] = f"Bearer {key}"
    else:
        headers[header_name] = key
    return headers


def load_health(max_age: int) -> Optional[Dict[str, Any]]:
    """Load cached health data, return None if stale or missing."""
    if not HEALTH_FILE.exists():
        return None
    try:
        data = json.loads(HEALTH_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return None
    updated = data.get("updated_at", "")
    if updated:
        try:
            ts = datetime.fromisoformat(updated)
            age = (datetime.now(timezone.utc) - ts).total_seconds()
            if age > max_age:
                return None
        except (ValueError, TypeError):
            pass
    return data


def check_one_provider(
    name: str, cfg: Dict[str, Any], env: Dict[str, str]
) -> Dict[str, Any]:
    """Run a live health check against one provider. Returns result dict."""
    url = cfg["url"]
    key = resolve_key(cfg, env)
    if not key and cfg.get("key_env"):
        return {
            "healthy": False,
            "latency_ms": 0,
            "status_code": 0,
            "error": f"missing env var {cfg['key_env']}",
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }

    headers = build_headers(cfg, env)
    try:
        start = time.monotonic()
        resp = requests.get(url, headers=headers, timeout=5)
        latency = int((time.monotonic() - start) * 1000)
        code = resp.status_code
        error = None
        if code in (401, 403):
            error = "auth_failed"
        elif code >= 500:
            error = f"server_error_{code}"
        elif code != 200:
            error = f"http_{code}"
        return {
            "healthy": code == 200,
            "latency_ms": latency,
            "status_code": code,
            "error": error,
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }
    except requests.Timeout:
        return {
            "healthy": False,
            "latency_ms": 5000,
            "status_code": 0,
            "error": "timeout",
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }
    except requests.ConnectionError:
        return {
            "healthy": False,
            "latency_ms": 0,
            "status_code": 0,
            "error": "connection_refused",
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }
    except Exception as e:
        return {
            "healthy": False,
            "latency_ms": 0,
            "status_code": 0,
            "error": str(e)[:120],
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }


# ── Commands ──────────────────────────────────────────────────────────


def cmd_status(config: Dict[str, Any], env: Dict[str, str], as_json: bool) -> int:
    """Show all providers with health, latency, models, and quota hints."""
    max_age = config.get("staleness_max_seconds", 600)
    health = load_health(max_age)
    providers = config.get("providers", {})

    rows: List[Dict[str, Any]] = []
    for name, cfg in providers.items():
        has_key = bool(resolve_key(cfg, env))
        h = (health or {}).get("providers", {}).get(name, {})
        quota = QUOTA_HINTS.get(name, {})
        row = {
            "provider": name,
            "healthy": h.get("healthy", "?"),
            "latency_ms": h.get("latency_ms", "?"),
            "status_code": h.get("status_code", "?"),
            "error": h.get("error"),
            "models": cfg.get("models", []),
            "priority": cfg.get("priority", 99),
            "key_present": has_key,
            "daily_limit": quota.get("daily_limit"),
            "quota_note": quota.get("note", ""),
        }
        rows.append(row)

    if as_json:
        stale = health is None
        updated = (health or {}).get("updated_at")
        print(json.dumps({"stale": stale, "updated_at": updated, "providers": rows}, indent=2, default=str))
        return 0


    health_age = ""
    if health and health.get("updated_at"):
        try:
            ts = datetime.fromisoformat(health["updated_at"])
            age_s = int((datetime.now(timezone.utc) - ts).total_seconds())
            health_age = f" (age: {age_s}s)"
        except (ValueError, TypeError):
            pass
    stale_tag = " [STALE]" if health is None else ""
    print(f"Provider Status{stale_tag}{health_age}")
    print("=" * 100)
    fmt = "{:<22} {:>5} {:>6} {:>4} {:>3} {:>7}  {}"
    print(fmt.format("PROVIDER", "HLTHY", "LAT ms", "HTTP", "PRI", "KEY", "MODELS"))
    print("-" * 100)
    for r in rows:
        healthy_str = "✅" if r["healthy"] is True else ("❌" if r["healthy"] is False else "?")
        key_str = "✓" if r["key_present"] else "✗"
        lat = str(r["latency_ms"]) if r["latency_ms"] != "?" else "?"
        code = str(r["status_code"]) if r["status_code"] != "?" else "?"
        models = ", ".join(r["models"][:3])
        if len(r["models"]) > 3:
            models += f" (+{len(r['models']) - 3})"
        err = f"  ⚠ {r['error']}" if r["error"] else ""
        print(fmt.format(r["provider"], healthy_str, lat, code, str(r["priority"]), key_str, models + err))


    print()
    print("Quota Hints:")
    for r in rows:
        limit = r["daily_limit"]
        note = r["quota_note"]
        if limit:
            print(f"  {r['provider']}: ~{limit}/day — {note}")
        elif note:
            print(f"  {r['provider']}: {note}")

    return 0


def cmd_select(
    config: Dict[str, Any], env: Dict[str, str], model_id: str, as_json: bool
) -> int:
    """Pick best healthy provider for a model, output provider/model."""
    model_providers = config.get("model_providers", {})
    max_age = config.get("staleness_max_seconds", 600)

    candidates = model_providers.get(model_id, [])
    if not candidates:
        if as_json:
            print(json.dumps({"error": f"unknown model: {model_id}", "model": model_id}))
        else:
            print(f"ERROR: Unknown model '{model_id}'", file=sys.stderr)
        return 1

    health = load_health(max_age)
    providers_cfg = config.get("providers", {})

    def score(pname: str) -> Tuple[int, int, int]:
        if health:
            d = health.get("providers", {}).get(pname, {})
            return (0 if d.get("healthy") else 1, d.get("priority", 99), d.get("latency_ms", 9999))
        # No health data — use config priority only
        p = providers_cfg.get(pname, {})
        return (0, p.get("priority", 99), 9999)

    ranked = sorted(candidates, key=score)
    best = ranked[0]


    best_cfg = providers_cfg.get(best, {})
    has_key = bool(resolve_key(best_cfg, env))

    if as_json:
        result = {
            "model": model_id,
            "provider": best,
            "route": f"{best}/{model_id}",
            "healthy": True,
            "key_present": has_key,
            "all_candidates": ranked,
        }
        if health:
            h = health.get("providers", {}).get(best, {})
            result["healthy"] = h.get("healthy", True)
            result["latency_ms"] = h.get("latency_ms")
        quota = QUOTA_HINTS.get(best, {})
        if quota.get("daily_limit"):
            result["daily_limit"] = quota["daily_limit"]
        print(json.dumps(result, indent=2, default=str))
    else:
        warning = ""
        if health:
            h = health.get("providers", {}).get(best, {})
            if not h.get("healthy", True):
                warning = " ⚠ UNHEALTHY"
        if not has_key:
            warning += " ⚠ KEY MISSING"
        quota = QUOTA_HINTS.get(best, {})
        quota_str = f" (~{quota['daily_limit']}/day)" if quota.get("daily_limit") else ""
        print(f"{best}/{model_id}{warning}{quota_str}")

    return 0


def cmd_check_health(
    config: Dict[str, Any], env: Dict[str, str], as_json: bool
) -> int:
    """Run live health checks on all providers, write provider-health.json."""
    providers = config.get("providers", {})
    results: Dict[str, Dict[str, Any]] = {}

    for name, cfg in providers.items():
        results[name] = check_one_provider(name, cfg, env)

    output = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "providers": results,
    }

    # Atomic write
    fd, tmp = tempfile.mkstemp(dir=TOOLS_DIR, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(output, f, indent=2)
        os.replace(tmp, HEALTH_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    if as_json:
        print(json.dumps(output, indent=2, default=str))
    else:
        print(f"Health check completed — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
        print()
        for name, r in results.items():
            icon = "✅" if r["healthy"] else "❌"
            err = f" ({r['error']})" if r.get("error") else ""
            print(f"  {icon} {name}: HTTP {r['status_code']} ({r['latency_ms']}ms){err}")

    healthy_count = sum(1 for r in results.values() if r["healthy"])
    total = len(results)
    if not as_json:
        print(f"\n{healthy_count}/{total} providers healthy")

    return 0 if healthy_count > 0 else 1


# ── Main ──────────────────────────────────────────────────────────────


def usage():
    print(
        """provider-router.py — real-time quota awareness for all 7 providers

Usage:
    provider-router.py status [--json]          Show all providers + health + quota
    provider-router.py select MODEL [--json]    Pick best provider for MODEL
    provider-router.py check-health [--json]    Run live health checks

Options:
    --json    Machine-readable JSON output

Examples:
    provider-router.py status
    provider-router.py select claude-opus-4-6
    provider-router.py select gpt-5.3-codex --json
    provider-router.py check-health"""
    )


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        usage()
        return 0

    cmd = sys.argv[1]
    as_json = "--json" in sys.argv

    try:
        config = load_config()
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"ERROR: Could not load {CONFIG_FILE}: {e}", file=sys.stderr)
        return 1

    env = load_env()

    if cmd == "status":
        return cmd_status(config, env, as_json)
    elif cmd == "select":
        args = [a for a in sys.argv[2:] if a != "--json"]
        if not args:
            print("ERROR: select requires a MODEL argument", file=sys.stderr)
            return 1
        return cmd_select(config, env, args[0], as_json)
    elif cmd == "check-health":
        return cmd_check_health(config, env, as_json)
    else:
        print(f"ERROR: Unknown command '{cmd}'", file=sys.stderr)
        usage()
        return 1


if __name__ == "__main__":
    sys.exit(main())
