#!/usr/bin/env python3
"""qwen-watch — irssi-style live view of qwenit (qwen-task.sh) sessions.

Each task is a channel and channel 0 is the aggregate feed.  Keys:
←/→ switch channel; 0..9 jump to one; PgUp/PgDn scroll; End follows; q quits.

Plain mode prints one human line per event, channel-prefixed and colored:

    22:41:03 #ql-demo          $ ssh lab 'labctl reset sinclairql'
    22:41:19 #ql-demo          ✓ 0.4s
    22:41:25 #docs-audit       📖 AGENTS.md
    22:42:01 #ql-demo          💬 Added the demoProgram block; regenerating now.

The title bar carries what Codex never reported: LIVE SPEND against the cap.
`qwen-task.sh` writes max-wall/max-tokens/max-cost at launch and OpenCode reports
per-step cost, so a watched task shows $0.58/$5.00 rather than a token guess.

Tasks are aggregated from the main checkout AND every Claude worktree (labeled
<task>@<worktree>); QWEN_TASKS_DIR overrides with one explicit directory.
Only active tasks join: RUNNING, or event log moved in the last 30 min.

Usage:  qwen-watch.py [--plain] [--replay N] [--tasks name1,name2]
        --plain      use line-streaming output instead of curses
        --replay N   show the last N events per task on startup (default 3)
        --tasks      filter; bare task names or <task>@<worktree> both match
                     (explicitly named tasks join regardless of age)
"""

from __future__ import annotations

import argparse
import contextlib
import curses
import json
import locale
import os
import sys
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from itertools import islice

from qwen_task_dirs import (
    TaskStream,
    discover_tasks,
    is_active,
    read_caps,
    spend_from,
    task_roots,
    task_state,
)
from qwen_term import clip_display, display_width, wrap_display

COLORS = [36, 33, 32, 35, 34, 91, 92, 93, 94, 95, 96]
RESET, DIM = "\033[0m", "\033[2m"
SCROLLBACK = 4000
POLL_SECONDS = 1.0
FINISHED_CHANNEL_TTL = 5 * 60


def wanted(want, name):
    """--tasks filter: match the display name or its bare task part."""
    return not want or name in want or name.rsplit("@", 1)[0] in want


def _short(path):
    """Paths in the stream are absolute inside the task's worktree, which makes
    every line start with the same 60 useless characters. Show the repo-relative
    tail — the part that differs."""
    text = str(path or "")
    marker = "/tree/"
    return text.rsplit(marker, 1)[-1] if marker in text else text


def _seconds(state):
    t = state.get("time") or {}
    start, end = t.get("start"), t.get("end")
    if not (isinstance(start, (int, float)) and isinstance(end, (int, float))):
        return ""
    return f" {DIM}{(end - start) / 1000:.1f}s{RESET}"


def _fmt_tool(part):
    """One line for a completed tool call. `state.title` is populated for every
    tool, so it is the fallback rather than a guess."""
    tool = part.get("tool") or "?"
    state = part.get("state") or {}
    status = state.get("status")
    inp = state.get("input") or {}
    meta = state.get("metadata") or {}
    title = state.get("title") or ""

    if status not in (None, "completed"):
        return f"!! {tool} {status}: " + str(state.get("error") or title)[:200]

    if tool == "bash":
        rc = meta.get("exit")
        mark = "✓" if rc in (0, None) else f"✗ rc={rc}"
        return f"$ {inp.get('command') or title}\n  {DIM}{mark}{RESET}{_seconds(state)}"
    if tool == "read":
        return f"📖 {_short(inp.get('filePath') or title)}{_seconds(state)}"
    if tool in ("write", "edit", "patch", "multiedit"):
        return f"✎ {_short(inp.get('filePath') or title)}{_seconds(state)}"
    if tool in ("grep", "glob"):
        found = meta.get("matches")
        tail = f" {DIM}({found} matches){RESET}" if found is not None else ""
        return f"🔎 {inp.get('pattern') or inp.get('glob') or title}{tail}"
    if tool in ("list", "ls"):
        return f"{DIM}▸ ls {_short(inp.get('path') or title)}{RESET}"
    if tool == "todowrite":
        todos = meta.get("todos") or inp.get("todos") or []
        done = sum(1 for t in todos if isinstance(t, dict) and t.get("status") == "completed")
        return f"{DIM}☰ plan: {done}/{len(todos)} done{RESET}"
    if tool in ("webfetch", "websearch"):
        return f"🌐 {inp.get('url') or inp.get('query') or title}"
    if tool == "task":
        return f"⚙ subagent: {title}"
    return f"⚙ {tool} {title}"[:400]


def fmt(ev):
    """Return a short human line for one OpenCode event, or None to skip.

    The schema is nothing like Codex's: events are {type, sessionID, timestamp,
    part}, and the interesting ones are tool_use / text / step_finish. step_start
    is dropped — it carries no payload and there is one per tool call.
    """
    kind = ev.get("type", "")
    part = ev.get("part") or {}

    if kind == "tool_use":
        return _fmt_tool(part)
    if kind == "text":
        text = (part.get("text") or "").strip()
        # Intermediate steps emit whitespace-only text parts between tool calls.
        return f"💬 {text}" if text else None
    if kind == "step_finish":
        tok = part.get("tokens") or {}
        cost = part.get("cost")
        spend = f" / ${cost:.4f}" if isinstance(cost, (int, float)) else ""
        reason = part.get("reason") or ""
        note = "" if reason == "tool-calls" else f" [{reason}]"
        return f"{DIM}— step (in {tok.get('input', '?')} / out {tok.get('output', '?')}{spend}){note}{RESET}"
    if kind in ("error", "session_error"):
        return "!! " + str(ev.get("error") or ev.get("message") or json.dumps(ev))[:400]
    return None


@dataclass
class ScreenLine:
    text: str
    source: str = ""
    notice: bool = False


@dataclass
class Channel:
    name: str
    task_dir: str | None = None
    events_path: str | None = None
    lines: deque = field(default_factory=lambda: deque(maxlen=SCROLLBACK))
    unseen: bool = False
    scroll: int = 0
    state: str = "RUNNING"
    finished_at: float | None = None
    wrap_width: int | None = None
    wrapped_lines: deque = field(default_factory=deque)
    wrapped_counts: deque = field(default_factory=deque)


def spend_label(task_dir, events_path):
    """`$0.58/$5.00  9.9k/300k tok` — the cap line, or '' when unreadable."""
    if not (task_dir and events_path):
        return ""
    tokens, cost = spend_from(events_path)
    _, max_tokens, max_cost = read_caps(task_dir)
    cost_part = f"${cost:.2f}" + (f"/${max_cost:.2f}" if max_cost else "")
    tok_part = f"{tokens / 1000:.1f}k" + (f"/{max_tokens / 1000:.0f}k" if max_tokens else "")
    return f"{cost_part}  {tok_part} tok"


class WatchTUI:
    def __init__(self, stdscr, replay, tasks):
        self.stdscr = stdscr
        self.replay = replay
        self.want = set(filter(None, tasks.split(",")))
        self.channels = [Channel("all")]
        self.by_name = {}
        self.streams = {}
        self.active = 0
        self.running = True
        self.next_poll = 0.0
        self.task_pairs = {}
        self.retired = {}
        self._init_screen()

    def _init_screen(self):
        # keypad(True) emits smkx, which puts the terminal into APPLICATION cursor
        # mode: arrows then arrive as ESC O C / ESC O D, terminfo decodes them, and
        # get_wch() hands us KEY_RIGHT / KEY_LEFT. That is the whole arrow story —
        # no escape parsing. (Normal-mode ESC [ C is not in xterm's keymap and
        # cannot be registered here: this Python's curses has no define_key.)
        self.stdscr.keypad(True)
        self.stdscr.timeout(100)
        with contextlib.suppress(curses.error):
            curses.curs_set(0)
        self.has_colors = curses.has_colors()
        if not self.has_colors:
            return
        try:
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLUE)
            palette = (
                curses.COLOR_CYAN,
                curses.COLOR_YELLOW,
                curses.COLOR_GREEN,
                curses.COLOR_MAGENTA,
                curses.COLOR_BLUE,
                curses.COLOR_RED,
            )
            for number, color in enumerate(palette, 4):
                curses.init_pair(number, color, -1)
        except curses.error:
            self.has_colors = False

    def _task_pair(self, name):
        if not self.has_colors or not name:
            return 0
        if name not in self.task_pairs:
            self.task_pairs[name] = 4 + (len(self.task_pairs) % 6)
        return curses.color_pair(self.task_pairs[name])

    def _append(self, index, line):
        channel = self.channels[index]
        if index == self.active:
            if channel.scroll:
                _, width = self.stdscr.getmaxyx()
                channel.scroll += len(wrap_display(line.text, width))
        else:
            channel.unseen = True

        if channel.wrap_width is not None:
            if len(channel.lines) == channel.lines.maxlen:
                old_count = channel.wrapped_counts.popleft()
                for _ in range(old_count):
                    channel.wrapped_lines.popleft()
            pieces = self._wrap_line(line, channel.wrap_width)
            channel.wrapped_lines.extend(pieces)
            channel.wrapped_counts.append(len(pieces))
        channel.lines.append(line)

    def _add_channel(self, name, path):
        task_dir = os.path.dirname(path)
        self.channels.append(Channel(name, task_dir, path, state=task_state(task_dir)))
        self.by_name[name] = len(self.channels) - 1
        self.streams[name] = TaskStream(path)
        self.retired.pop(name, None)
        ts = datetime.now().strftime("%H:%M:%S")
        self._append(0, ScreenLine(f"{ts} *** joined #{name} as channel {self.by_name[name]}", name, True))

    @staticmethod
    def _wrap_line(line, width):
        return [ScreenLine(text, line.source, line.notice) for text in wrap_display(line.text, width)]

    def _wrapped(self, channel, width):
        if channel.wrap_width != width:
            channel.wrap_width = width
            channel.wrapped_lines.clear()
            channel.wrapped_counts.clear()
            for line in channel.lines:
                pieces = self._wrap_line(line, width)
                channel.wrapped_lines.extend(pieces)
                channel.wrapped_counts.append(len(pieces))
        return channel.wrapped_lines

    def _expire_finished_channels(self, now):
        remove = []
        for index, channel in enumerate(self.channels[1:], 1):
            channel.state = task_state(channel.task_dir)
            if channel.state == "RUNNING":
                channel.finished_at = None
                continue
            if channel.finished_at is None:
                channel.finished_at = now
                ts = datetime.now().strftime("%H:%M:%S")
                spend = spend_label(channel.task_dir, channel.events_path)
                self._append(0, ScreenLine(f"{ts} *** #{channel.name} {channel.state} — {spend}", channel.name, True))
            if index != self.active and now - channel.finished_at >= FINISHED_CHANNEL_TTL:
                remove.append(index)

        for index in reversed(remove):
            channel = self.channels[index]
            self.retired[channel.name] = channel.task_dir
            self.streams.pop(channel.name, None)
            del self.channels[index]
            if index < self.active:
                self.active -= 1

        if remove:
            self.by_name = {channel.name: index for index, channel in enumerate(self.channels) if index}

    def poll(self):
        for name, path in discover_tasks():
            if not wanted(self.want, name):
                continue
            if name in self.retired:
                if task_state(os.path.dirname(path)) != "RUNNING":
                    continue
                self.retired.pop(name, None)
            if name not in self.by_name and (self.want or is_active(path)):
                self._add_channel(name, path)

        for name, stream in list(self.streams.items()):
            for raw in stream.read(self.replay):
                if not raw.strip():
                    continue
                try:
                    out = fmt(json.loads(raw))
                except (AttributeError, TypeError, ValueError):
                    out = None
                if not out:
                    continue
                ts = datetime.now().strftime("%H:%M:%S")
                self._append(self.by_name[name], ScreenLine(f"{ts} {out}", name))
                chan = f"#{name[:26]:<26}"
                self._append(0, ScreenLine(f"{ts} {chan} {out}", name))
        self._expire_finished_channels(time.monotonic())

    def switch(self, index):
        if 0 <= index < len(self.channels):
            self.active = index
            self.channels[index].unseen = False

    def move(self, amount):
        self.switch((self.active + amount) % len(self.channels))

    def handle_key(self, key):
        """Bare keys only. The predecessor read Alt+Left/Right and Alt+0..9, which
        meant hand-parsing escape sequences across terminals that disagree about
        them; plain arrows are unambiguous and curses decodes them for us."""
        channel = self.channels[self.active]
        height, _ = self.stdscr.getmaxyx()
        page = max(1, height - 3)
        max_scroll = max(0, len(channel.lines) - max(1, height - 2))
        if key == "q":
            self.running = False
        elif key == curses.KEY_LEFT:
            self.move(-1)
        elif key == curses.KEY_RIGHT:
            self.move(1)
        elif isinstance(key, str) and key.isdigit():
            self.switch(int(key))
        elif key == curses.KEY_PPAGE:
            channel.scroll = min(max_scroll, channel.scroll + page)
        elif key == curses.KEY_NPAGE:
            channel.scroll = max(0, channel.scroll - page)
        elif key == curses.KEY_END:
            channel.scroll = 0
        elif key == curses.KEY_RESIZE:
            with contextlib.suppress(curses.error):
                curses.update_lines_cols()

    def _addstr(self, row, col, text, attr=0):
        height, width = self.stdscr.getmaxyx()
        if not (0 <= row < height and 0 <= col < width):
            return 0
        clipped = clip_display(text, width - col)
        with contextlib.suppress(curses.error):
            self.stdscr.addstr(row, col, clipped, attr)
        return display_width(clipped)

    def _render_status(self, row, width):
        base = curses.color_pair(1) if self.has_colors else curses.A_REVERSE
        unseen = (curses.color_pair(3) if self.has_colors else base) | curses.A_BOLD
        with contextlib.suppress(curses.error):
            self.stdscr.addstr(row, 0, " " * max(0, width - 1), base)
        tokens = [f"[{i}:{channel.name}] " for i, channel in enumerate(self.channels)]
        start = self.active
        used = display_width(tokens[start])
        while start > 0 and used + display_width(tokens[start - 1]) <= width:
            start -= 1
            used += display_width(tokens[start])
        col = 0
        for index in range(start, len(tokens)):
            if col >= width:
                break
            attr = base
            if index == self.active:
                attr |= curses.A_REVERSE | curses.A_BOLD
            elif self.channels[index].unseen:
                attr = unseen
            col += self._addstr(row, col, tokens[index], attr)

    def _title(self):
        channel = self.channels[self.active]
        if self.active == 0:
            live = sum(1 for c in self.channels[1:] if c.state == "RUNNING")
            total = sum(spend_from(c.events_path)[1] for c in self.channels[1:] if c.events_path)
            return f"[all] AGGREGATE | {len(self.channels) - 1} tasks, {live} running | ${total:.2f} | ←/→ q"
        spend = spend_label(channel.task_dir, channel.events_path)
        return f"#{channel.name} {channel.state} | {spend} | channel {self.active} | ←/→ PgUp/PgDn q"

    def render(self):
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        if height <= 0 or width <= 0:
            return
        channel = self.channels[self.active]
        content_height = max(0, height - 2)
        lines = self._wrapped(channel, width)
        max_scroll = max(0, len(lines) - content_height)
        channel.scroll = min(channel.scroll, max_scroll)
        visible = list(islice(reversed(lines), channel.scroll, channel.scroll + content_height))
        visible.reverse()
        for row, line in enumerate(visible):
            attr = self._task_pair(line.source)
            if line.notice:
                attr |= curses.A_BOLD
            self._addstr(row, 0, line.text, attr)

        if height >= 2:
            title_attr = curses.color_pair(2) if self.has_colors else curses.A_REVERSE
            with contextlib.suppress(curses.error):
                self.stdscr.addstr(height - 2, 0, " " * max(0, width - 1), title_attr)
            self._addstr(height - 2, 0, self._title(), title_attr | curses.A_BOLD)
        self._render_status(height - 1, width)
        with contextlib.suppress(curses.error):
            self.stdscr.refresh()

    def run(self):
        while self.running:
            now = time.monotonic()
            if now >= self.next_poll:
                self.poll()
                self.next_poll = now + POLL_SECONDS
            self.render()
            try:
                key = self.stdscr.get_wch()
            except curses.error:
                continue
            self.handle_key(key)


def run_tui(replay, tasks):
    locale.setlocale(locale.LC_ALL, "")
    if hasattr(curses, "set_escdelay"):
        curses.set_escdelay(25)
    curses.wrapper(lambda stdscr: WatchTUI(stdscr, replay, tasks).run())


def run_plain(replay, tasks):
    """Line-oriented watcher; also what runs when stdout is redirected."""
    want = set(filter(None, tasks.split(",")))
    offsets, colors, replayed, states = {}, {}, set(), {}
    roots = task_roots()
    # Every print here flushes: plain mode is what runs when stdout is a pipe or a
    # file, and a watcher whose output appears only at exit is not a watcher.
    print(
        f"{DIM}qwen-watch: following {len(roots)} task root(s) for */events.jsonl (Ctrl-C to quit){RESET}", flush=True
    )
    try:
        while True:
            for name, path in discover_tasks():
                if not wanted(want, name):
                    continue
                if name not in colors:
                    if not (want or is_active(path)):
                        continue
                    colors[name] = COLORS[len(colors) % len(COLORS)]
                    print(f"\033[{colors[name]}m*** watching #{name}{RESET}", flush=True)
                try:
                    size = os.path.getsize(path)
                    if path not in offsets:
                        if replay and path not in replayed:
                            with open(path, errors="replace") as f:
                                lines = f.readlines()
                            offsets[path] = size
                            replayed.add(path)
                            tail = lines[-replay:] if replay else []
                        else:
                            offsets[path], tail = size, []
                    else:
                        if size < offsets[path]:
                            offsets[path] = 0  # truncated (resume) — reread
                        with open(path, errors="replace") as f:
                            f.seek(offsets[path])
                            tail = f.readlines()
                            offsets[path] = f.tell()
                    for line in tail:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            out = fmt(json.loads(line))
                        except (TypeError, ValueError):
                            out = None
                        if out:
                            ts = datetime.now().strftime("%H:%M:%S")
                            chan = f"#{name[:26]:<26}"
                            print(f"{DIM}{ts}{RESET} \033[{colors[name]}m{chan}{RESET} {out}", flush=True)
                    task_dir = os.path.dirname(path)
                    state = task_state(task_dir)
                    if states.get(name) not in (None, state) or (name not in states and state != "RUNNING"):
                        print(
                            f"{DIM}{datetime.now():%H:%M:%S}{RESET} \033[{colors[name]}m{f'#{name[:26]:<26}'}{RESET}"
                            f" *** {state} — {spend_label(task_dir, path)}",
                            flush=True,
                        )
                    states[name] = state
                except OSError:
                    continue
            time.sleep(2)
    except KeyboardInterrupt:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plain", action="store_true")
    ap.add_argument("--replay", type=int, default=3)
    ap.add_argument("--tasks", default="")
    args = ap.parse_args()
    if args.plain or not sys.stdout.isatty():
        run_plain(args.replay, args.tasks)
        return
    run_tui(args.replay, args.tasks)


if __name__ == "__main__":
    main()
