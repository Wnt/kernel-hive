#!/usr/bin/env python3
"""qwen_term — terminal text primitives for qwen-watch.

Event text is arbitrary: a model writes CJK, emoji, combining accents and raw
control bytes into a `bash` command or an assistant message, and curses will
happily corrupt a window if asked to draw a two-column glyph in one column.
Everything here measures and cuts text in DISPLAY columns rather than characters.
"""

from __future__ import annotations

import re
import unicodedata

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def _char_width(char):
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


def display_width(text):
    """Columns `text` occupies, not len()."""
    return sum(_char_width(char) for char in text)


def wrap_display(text, width):
    """Sanitize and wrap into rows of at most `width` columns, never splitting a
    wide character across rows."""
    if width <= 0:
        return []
    wrapped = []
    text = ANSI_RE.sub("", str(text)).replace("\t", "    ")
    for logical_line in text.split("\n"):
        out = []
        used = 0
        for char in logical_line:
            if unicodedata.category(char).startswith("C"):
                char = "?"
            char_width = _char_width(char)
            if used + char_width > width and out:
                wrapped.append("".join(out))
                out = []
                used = 0
            if char_width > width:
                # A two-column glyph cannot be drawn in a one-column window.
                char = "?"
                char_width = 1
            out.append(char)
            used += char_width
        wrapped.append("".join(out))
    return wrapped


def clip_display(text, width):
    """Sanitize a single display row, which callers have already wrapped."""
    wrapped = wrap_display(text, width)
    return wrapped[0] if wrapped else ""
