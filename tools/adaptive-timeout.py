#!/usr/bin/env python3
"""
Adaptive Timeout System for OpenClaw Sub-Agent Workers.

3-layer timeout policy:
  1. Startup timeout  — kill if no output within startup window
  2. Progress timeout — kill if idle (no output growth) beyond idle window
  3. Absolute ceiling — hard cap, no extensions

Progress-based extensions:
  - If worker is producing output when soft deadline approaches, extend by EXTENSION_STEP
  - Keep extending up to absolute ceiling
  - Log every extension decision

Usage:
  from adaptive_timeout import AdaptiveTimeoutManager
  mgr = AdaptiveTimeoutManager()
  mgr.check_workers()          # poll active subagents, enforce policy
  mgr.get_policy("coding")     # get timeout config for task type
  mgr.status()                 # show tracked workers
"""

import json
import os
import subprocess
import time
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LOG_FILE = Path("/home/brk/tools/adaptive-timeout.log")
STATE_FILE = Path("/home/brk/tools/adaptive_timeout_state.json")

EXTENSION_STEP = 120  # seconds added per extension


class Decision(Enum):
    EXTEND = "extend"
    KILL = "kill"
    OK = "ok"


@dataclass
class TimeoutPolicy:
    """Timeout parameters for a task type."""
    startup: int    # seconds — max silence before first output
    idle: int       # seconds — max silence after first output
    ceiling: int    # seconds — absolute hard cap

    def to_dict(self):
        return {"startup": self.startup, "idle": self.idle, "ceiling": self.ceiling}


# Task-type policies
POLICIES: dict[str, TimeoutPolicy] = {
    "coding":  TimeoutPolicy(startup=60,  idle=120, ceiling=900),
    "search":  TimeoutPolicy(startup=30,  idle=60,  ceiling=300),
    "media":   TimeoutPolicy(startup=60,  idle=120, ceiling=900),
    "general": TimeoutPolicy(startup=30,  idle=60,  ceiling=900),
    "review":  TimeoutPolicy(startup=30,  idle=60,  ceiling=300),
    "playwright": TimeoutPolicy(startup=60, idle=60, ceiling=1800),
}

DEFAULT_POLICY = "general"


@dataclass
class WorkerState:
    """Runtime tracking state for a single worker."""
    session_id: str
    label: str
    task_type: str
    start_ts: float
    last_progress_ts: float
    first_output_ts: Optional[float] = None
    last_token_count: int = 0
    current_deadline: float = 0.0  # soft deadline (extendable)
    extensions: int = 0
    killed: bool = False

    def runtime(self) -> float:
        return time.time() - self.start_ts

    def idle_time(self) -> float:
        return time.time() - self.last_progress_ts

    def to_dict(self):
        return {
            "session_id": self.session_id,
            "label": self.label,
            "task_type": self.task_type,
            "start_ts": self.start_ts,
            "last_progress_ts": self.last_progress_ts,
            "first_output_ts": self.first_output_ts,
            "last_token_count": self.last_token_count,
            "current_deadline": self.current_deadline,
            "extensions": self.extensions,
            "killed": self.killed,
        }


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime())
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except OSError:
        pass  # best-effort logging


# ---------------------------------------------------------------------------
# OpenClaw integration helpers
# ---------------------------------------------------------------------------

def _openclaw_list_subagents() -> list[dict]:
    """Call openclaw CLI to list active subagents. Returns parsed JSON list."""
    try:
        result = subprocess.run(
            ["openclaw", "sessions", "list", "--json"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            if isinstance(data, list):
                return data
            # Some versions wrap in {"sessions": [...]}
            if isinstance(data, dict) and "sessions" in data:
                return data["sessions"]
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        pass
    return []


def _openclaw_kill_session(session_id: str) -> bool:
    """Kill a subagent session via openclaw CLI."""
    try:
        result = subprocess.run(
            ["openclaw", "sessions", "kill", session_id],
            capture_output=True, text=True, timeout=10,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def _estimate_progress(session: dict) -> int:
    """
    Estimate progress from session metadata.
    Uses token count, message count, or output length as proxy.
    """
    # Try various fields that OpenClaw might expose
    for key in ("tokens", "token_count", "outputTokens", "output_tokens"):
        if key in session and isinstance(session[key], (int, float)):
            return int(session[key])
    # Fallback: message count as rough proxy
    for key in ("messages", "message_count"):
        if key in session and isinstance(session[key], (int, float)):
            return int(session[key]) * 100  # rough token estimate
    # Fallback: output length
    if "output" in session and isinstance(session["output"], str):
        return len(session["output"])
    return 0


# ---------------------------------------------------------------------------
# Core Manager
# ---------------------------------------------------------------------------

class AdaptiveTimeoutManager:
    """Manages adaptive timeouts for OpenClaw sub-agent workers."""

    def __init__(self, policies: Optional[dict[str, TimeoutPolicy]] = None):
        self.policies = policies or POLICIES
        self.workers: dict[str, WorkerState] = {}
        self._load_state()

    # -- Policy access --

    def get_policy(self, task_type: str) -> TimeoutPolicy:
        """Return timeout policy for a task type. Falls back to general."""
        return self.policies.get(task_type, self.policies[DEFAULT_POLICY])

    # -- Worker registration --

    def register(self, session_id: str, label: str, task_type: str = "general") -> WorkerState:
        """Register a new worker for monitoring."""
        now = time.time()
        policy = self.get_policy(task_type)
        # Initial soft deadline = startup timeout (first output must arrive by then)
        deadline = now + policy.startup
        ws = WorkerState(
            session_id=session_id,
            label=label,
            task_type=task_type,
            start_ts=now,
            last_progress_ts=now,
            current_deadline=deadline,
        )
        self.workers[session_id] = ws
        _log(f"REGISTER worker={label} sid={session_id} type={task_type} "
             f"startup={policy.startup}s idle={policy.idle}s ceiling={policy.ceiling}s")
        self._save_state()
        return ws

    def unregister(self, session_id: str):
        """Remove a worker from tracking."""
        ws = self.workers.pop(session_id, None)
        if ws:
            _log(f"UNREGISTER worker={ws.label} sid={session_id} "
                 f"runtime={ws.runtime():.1f}s extensions={ws.extensions}")
            self._save_state()

    # -- Core decision logic --

    def should_kill(self, ws: WorkerState, token_count: int = 0) -> bool:
        """
        Returns True if any timeout layer says kill.
        Layer 1: Startup — no first output within startup window.
        Layer 2: Progress — idle too long after first output.
        Layer 3: Ceiling — absolute hard cap exceeded.
        """
        now = time.time()
        policy = self.get_policy(ws.task_type)

        # Layer 3: Absolute ceiling (non-negotiable)
        if ws.runtime() >= policy.ceiling:
            _log(f"KILL(ceiling) worker={ws.label} runtime={ws.runtime():.1f}s "
                 f"ceiling={policy.ceiling}s")
            return True

        # Layer 1: Startup timeout — no output yet
        if ws.first_output_ts is None:
            if now > ws.start_ts + policy.startup:
                _log(f"KILL(startup) worker={ws.label} no output after "
                     f"{ws.runtime():.1f}s startup={policy.startup}s")
                return True
            return False

        # Layer 2: Progress timeout — idle too long
        if ws.idle_time() >= policy.idle:
            _log(f"KILL(idle) worker={ws.label} idle={ws.idle_time():.1f}s "
                 f"threshold={policy.idle}s")
            return True

        # Layer 2b: Soft deadline exceeded (extensions gate lifecycle)
        if now > ws.current_deadline:
            _log(f"KILL(deadline) worker={ws.label} deadline exceeded by "
                 f"{now - ws.current_deadline:.1f}s")
            return True

        return False

    def should_extend(self, ws: WorkerState, token_count: int = 0) -> bool:
        """
        Returns True if worker is making progress and deadline is approaching,
        and we haven't hit the ceiling yet.
        Only applies after first output (startup phase uses startup timeout, not extensions).
        """
        now = time.time()
        policy = self.get_policy(ws.task_type)

        # No extensions during startup phase (before first output)
        if ws.first_output_ts is None:
            return False

        # Can't extend past ceiling
        max_deadline = ws.start_ts + policy.ceiling
        if ws.current_deadline >= max_deadline:
            return False

        # Is deadline approaching? (within 30s)
        time_to_deadline = ws.current_deadline - now
        if time_to_deadline > 30:
            return False  # plenty of time left

        # Is there progress? (token count increased)
        if token_count > ws.last_token_count:
            return True

        return False

    def evaluate(self, ws: WorkerState, token_count: int = 0) -> Decision:
        """
        Evaluate a worker and return a decision: KILL, EXTEND, or OK.
        Also updates worker state with new token count / progress timestamps.
        """
        now = time.time()
        policy = self.get_policy(ws.task_type)
        has_new_progress = token_count > ws.last_token_count

        # Check kill conditions first (before updating state)
        if self.should_kill(ws, token_count):
            return Decision.KILL

        # Check extension (before updating last_token_count so comparison works)
        if self.should_extend(ws, token_count):
            max_deadline = ws.start_ts + policy.ceiling
            new_deadline = min(ws.current_deadline + EXTENSION_STEP, max_deadline)
            actual_ext = new_deadline - ws.current_deadline
            ws.current_deadline = new_deadline
            ws.extensions += 1
            _log(f"EXTEND worker={ws.label} by {actual_ext:.0f}s "
                 f"(tokens: {token_count}, runtime: {ws.runtime():.1f}s) "
                 f"extensions={ws.extensions}")
            # Still update progress state after extension decision
            if has_new_progress:
                if ws.first_output_ts is None:
                    ws.first_output_ts = now
                ws.last_progress_ts = now
                ws.last_token_count = token_count
            return Decision.EXTEND

        # Update progress tracking after all checks
        if has_new_progress:
            if ws.first_output_ts is None:
                ws.first_output_ts = now
                # Now that we have first output, set soft deadline to initial timeout
                ws.current_deadline = now + policy.idle
                _log(f"FIRST_OUTPUT worker={ws.label} at {ws.runtime():.1f}s "
                     f"tokens={token_count}")
            ws.last_progress_ts = now
            ws.last_token_count = token_count

        return Decision.OK

    # -- High-level operations --

    def check_workers(self) -> dict[str, Decision]:
        """
        Poll all active subagents, evaluate each tracked worker.
        Returns dict of session_id -> Decision.
        Auto-registers unknown active sessions as 'general'.
        """
        sessions = _openclaw_list_subagents()
        active_ids = set()
        decisions: dict[str, Decision] = {}

        for session in sessions:
            sid = session.get("id") or session.get("session_id") or session.get("sessionId", "")
            if not sid:
                continue
            active_ids.add(sid)
            token_count = _estimate_progress(session)

            # Auto-register if unknown
            if sid not in self.workers:
                label = session.get("label", session.get("name", "unknown"))
                task_type = self._infer_task_type(label, session)
                self.register(sid, label, task_type)

            ws = self.workers[sid]
            decision = self.evaluate(ws, token_count)
            decisions[sid] = decision

            if decision == Decision.KILL and not ws.killed:
                ws.killed = True
                success = _openclaw_kill_session(sid)
                _log(f"KILL_EXEC worker={ws.label} sid={sid} success={success}")

        # Clean up workers that are no longer active
        stale = [sid for sid in self.workers if sid not in active_ids]
        for sid in stale:
            self.unregister(sid)

        self._save_state()
        return decisions

    def status(self) -> list[dict]:
        """Return status of all tracked workers."""
        result = []
        for ws in self.workers.values():
            policy = self.get_policy(ws.task_type)
            result.append({
                "session_id": ws.session_id,
                "label": ws.label,
                "task_type": ws.task_type,
                "runtime": round(ws.runtime(), 1),
                "idle": round(ws.idle_time(), 1),
                "tokens": ws.last_token_count,
                "extensions": ws.extensions,
                "ceiling": policy.ceiling,
                "time_to_ceiling": round(max(0, policy.ceiling - ws.runtime()), 1),
                "killed": ws.killed,
                "has_output": ws.first_output_ts is not None,
            })
        return result

    def config(self) -> dict[str, dict]:
        """Return all timeout policies as dict."""
        return {name: p.to_dict() for name, p in self.policies.items()}

    # -- Internals --

    def _infer_task_type(self, label: str, session: dict) -> str:
        """Guess task type from label/metadata. Order matters — more specific first."""
        label_lower = label.lower()
        # Review before coding (e.g. "review-code" should be review, not coding)
        if any(kw in label_lower for kw in ("review", "grapple", "audit")):
            return "review"
        if any(kw in label_lower for kw in ("search", "brave", "research", "lookup")):
            return "search"
        if any(kw in label_lower for kw in ("media", "video", "image", "generate", "veo", "kling")):
            return "media"
        if any(kw in label_lower for kw in ("playwright", "browser", "chromium", "firefox", "webkit")):
            return "playwright"
        if any(kw in label_lower for kw in ("code", "write", "implement", "fix", "refactor", "opencode")):
            return "coding"
        return "general"

    def _save_state(self):
        """Persist worker state to disk."""
        try:
            data = {sid: ws.to_dict() for sid, ws in self.workers.items()}
            tmp = str(STATE_FILE) + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f, indent=2)
            os.replace(tmp, STATE_FILE)
        except OSError:
            pass

    def _load_state(self):
        """Load persisted worker state (best-effort)."""
        try:
            if STATE_FILE.exists():
                with open(STATE_FILE) as f:
                    data = json.load(f)
                for sid, d in data.items():
                    self.workers[sid] = WorkerState(**d)
        except (OSError, json.JSONDecodeError, TypeError):
            self.workers = {}


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------

def main():
    import sys
    mgr = AdaptiveTimeoutManager()

    if len(sys.argv) < 2:
        print("Usage: adaptive-timeout.py <check|status|config>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "check":
        decisions = mgr.check_workers()
        for sid, dec in decisions.items():
            ws = mgr.workers.get(sid)
            label = ws.label if ws else "?"
            print(f"  {label} ({sid[:12]}...): {dec.value}")
        if not decisions:
            print("  No active workers found.")

    elif cmd == "status":
        statuses = mgr.status()
        if not statuses:
            print("  No tracked workers.")
        for s in statuses:
            print(f"  {s['label']} | runtime={s['runtime']}s idle={s['idle']}s "
                  f"tokens={s['tokens']} ext={s['extensions']} "
                  f"ceiling_left={s['time_to_ceiling']}s "
                  f"{'KILLED' if s['killed'] else 'ALIVE'}")

    elif cmd == "config":
        for name, p in mgr.config().items():
            print(f"  {name}: startup={p['startup']}s idle={p['idle']}s ceiling={p['ceiling']}s")

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
