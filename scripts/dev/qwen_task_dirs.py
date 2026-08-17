#!/usr/bin/env python3
"""qwen_task_dirs — discover qwen-task dirs across the main checkout and worktrees.

A task launched from a Claude worktree (`.claude/worktrees/<name>/`) registers
under that worktree's own `.claude/qwen-tasks/`, so a watcher started in the main
checkout must aggregate every root, not just its own. `QWEN_TASKS_DIR` forces
explicit single-dir mode (no worktree scan, no labels) and matches the same
override in `qwen-task.sh`.
"""

from __future__ import annotations

import functools
import glob
import json
import os
import subprocess
import time

ACTIVE_WINDOW_SECONDS = 30 * 60


@functools.lru_cache(maxsize=1)
def _main_repo_root():
    """Main-checkout root, even when invoked from inside a linked worktree."""
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
        ).stdout.strip()
    except OSError:
        common = ""
    if common:
        return os.path.dirname(os.path.abspath(common))
    return os.getcwd()


def task_roots():
    """Return [(label, tasks_dir)]; label '' = main root (or the QWEN_TASKS_DIR
    override), otherwise the origin worktree's name. The main root resolves once
    per process; the worktree list is re-scanned on every call so a long-running
    watcher picks up worktrees created mid-session."""
    override = os.environ.get("QWEN_TASKS_DIR")
    if override:
        return [("", override)]
    main = _main_repo_root()
    roots = [("", os.path.join(main, ".claude", "qwen-tasks"))]
    pattern = os.path.join(main, ".claude", "worktrees", "*", ".claude", "qwen-tasks")
    for tasks_dir in sorted(glob.glob(pattern)):
        worktree = os.path.basename(os.path.dirname(os.path.dirname(tasks_dir)))
        roots.append((worktree, tasks_dir))
    return roots


def _task_key(name, task_dir):
    """Dedup key: creating a worktree snapshots main's qwen-tasks wholesale, so the
    same task appears under several roots, and the copies share the original's
    OpenCode session id (and pid file) verbatim. Prefer the globally-unique session
    id; fall back to name+pid (pids recycle, so scope them by task name), then to
    the bare name — a dir with neither file was never launched, so collapsing it
    cannot hide anything live."""
    for fname, scoped in (("session.txt", False), ("pid", True)):
        try:
            with open(os.path.join(task_dir, fname)) as f:
                content = f.read().strip()
        except OSError:
            continue
        if content:
            return (fname, name, content) if scoped else (fname, content)
    return ("name", name)


def discover_tasks():
    """Yield (display_name, events_path) for every task under every root;
    worktree-origin tasks display as <task>@<worktree>. Snapshot duplicates
    collapse into their first occurrence (main root wins)."""
    seen = set()
    for label, root in task_roots():
        for path in sorted(glob.glob(os.path.join(root, "*", "events.jsonl"))):
            task_dir = os.path.dirname(path)
            name = os.path.basename(task_dir)
            key = _task_key(name, task_dir)
            if key in seen:
                continue
            seen.add(key)
            yield (f"{name}@{label}" if label else name, path)


def task_state(task_dir):
    """RUNNING | KILLED | DONE | DIED — the same ladder `qwen-task.sh state_in`
    walks, in the same order. `killed` outranks a live pid because the watchdog
    writes the marker before it starts the TERM/KILL grace period."""
    if not task_dir:
        return "DONE"
    killed = os.path.join(task_dir, "killed")
    if os.path.exists(killed) and os.path.getsize(killed):
        return "KILLED"
    try:
        with open(os.path.join(task_dir, "pid")) as f:
            os.kill(int(f.read().strip()), 0)
    except (OSError, ValueError):
        last = os.path.join(task_dir, "last.md")
        return "DONE" if os.path.exists(last) and os.path.getsize(last) else "DIED"
    return "RUNNING"


def read_caps(task_dir):
    """(max_wall, max_tokens, max_cost) as floats; None for any the task never
    wrote. qwen-task.sh writes all three at launch, so a missing file means an
    older task dir, not a task without caps."""
    out = []
    for fname in ("max-wall", "max-tokens", "max-cost"):
        try:
            with open(os.path.join(task_dir, fname)) as f:
                out.append(float(f.read().strip()))
        except (OSError, ValueError):
            out.append(None)
    return tuple(out)


def spend_from(events_path):
    """(output_tokens, cost) summed over the event log.

    Usage is reported PER STEP in step_finish.part.tokens — it is NOT cumulative,
    so a reader that takes the last event's value under-reports by the number of
    steps. This is the same summation `qwen-task.sh` does in jq.
    """
    tokens = 0
    cost = 0.0
    try:
        with open(events_path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or '"step_finish"' not in line:
                    continue
                try:
                    part = json.loads(line).get("part") or {}
                except ValueError:
                    continue
                tokens += (part.get("tokens") or {}).get("output") or 0
                cost += part.get("cost") or 0.0
    except OSError:
        pass
    return tokens, cost


class TaskStream:
    """Follow one events.jsonl and tolerate replacement or in-place rewrites.

    `qwen-task.sh resume` appends to the same file, but `clean` + a relaunch under
    the same name replaces it, and a task dir copied into a new worktree has a
    different inode with identical early bytes. Watching by offset alone would
    replay a stale tail or silently stop; the inode, the size going backwards and
    a 256-byte prefix check together catch all three.
    """

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.identity = None
        self.prefix = b""
        self.started = False

    def read(self, replay):
        try:
            with open(self.path, "rb") as f:
                st = os.fstat(f.fileno())
                identity = (st.st_dev, st.st_ino)
                reset = self.started and (identity != self.identity or st.st_size < self.offset)
                if self.started and not reset and self.prefix:
                    reset = f.read(len(self.prefix)) != self.prefix

                if not self.started:
                    raw_lines = f.read().splitlines()
                    raw_lines = raw_lines[-replay:] if replay else []
                else:
                    if reset:
                        self.offset = 0
                    f.seek(self.offset)
                    raw_lines = f.read().splitlines()

                self.offset = f.tell()
                f.seek(0)
                self.prefix = f.read(256)
                self.identity = identity
                self.started = True
        except OSError:
            return []
        return [line.decode("utf-8", "replace") for line in raw_lines]


def is_active(events_path):
    """Worth a watcher's attention: the event log moved within
    ACTIVE_WINDOW_SECONDS (a task that just finished is still interesting), or the
    task is RUNNING (a long task can go quiet between steps — a single `bash` call
    doing a golden bake emits nothing for minutes)."""
    try:
        if time.time() - os.path.getmtime(events_path) < ACTIVE_WINDOW_SECONDS:
            return True
    except OSError:
        return False
    return task_state(os.path.dirname(events_path)) == "RUNNING"
