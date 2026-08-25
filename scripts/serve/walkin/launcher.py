"""Read a station's OWN launcher and hand back its QEMU command line.

The brief is explicit: **reuse the station launcher verbatim, parameterized —
never fork it** (`docs/lab/WALKIN-BRIEF.md` §2). A forked launcher drifts, and a
drifted launcher is how `loadvm` starts failing against a golden that was
captured on the original device set.

So the clone command line is *derived* from the live launcher rather than copied
into a sibling script. That derivation is STATIC — this module never executes the
launcher. It cannot: a station launcher opens with

    D=/data/vms/streamhost/stations/os2warp
    [ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")"

and running it with an override that failed to reach the environment is exactly
the incident `clone-guard` exists to prevent (`docs/lab/clone-guard.md`). We read
the text, resolve the variables we were given, and refuse anything we cannot
account for.

What is parsed:
  * plain top-level `VAR=value` assignments (no command substitution, no
    conditionals) — the launcher's own defaults;
  * `presets` supplied by the caller, which WIN over those defaults. This is the
    parameterization: `D`, the disk, and `LOADVM` come from the broker;
  * the single `qemu-system-*` invocation and its backslash continuations;
  * a `*tapnet*.sh up` call, so the clone can be pointed at its own sibling
    script instead of the station's live one.

Anything left holding an unresolved `$` is an error. A launcher with two QEMU
invocations, or none, is an error. Failing loudly beats guessing (rule 7).
"""

from __future__ import annotations

import re
import shlex
from dataclasses import dataclass
from pathlib import Path

_ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*(?:#.*)?$")
_HAS_SUBST = re.compile(r"\$\(|`")
_QEMU_START = re.compile(r"^\s*(?:nohup\s+)?(?P<bin>[^\s|;&]*qemu-system-[\w.-]+)\b")
_TAPNET = re.compile(r"(?:bash|sh)\s+(?P<path>\"?[^\"'\s]*tapnet[\w.-]*\.sh\"?)\s+(?P<verb>up|down)\b")
_UNRESOLVED = re.compile(r"\$\{?[A-Za-z_0-9@*#?]")
_REDIRECT = re.compile(r"^(?:\d?[<>]|&$|\d>&\d)")


class LauncherError(ValueError):
    """A launcher this module will not derive a clone command line from."""


@dataclass(frozen=True)
class Launcher:
    """The static reading of one station launcher."""

    path: str
    binary: str
    argv: list  # full argv, argv[0] == binary
    variables: dict
    tapnet: str = ""  # resolved path of the station's own tap script, if any


def _expand(text: str, variables: dict, where: str) -> str:
    def sub(match: re.Match) -> str:
        name = match.group("name") or match.group("braced")
        if name not in variables:
            raise LauncherError(f"{where}: launcher uses ${name}, which nothing defines and no preset supplies")
        return str(variables[name])

    return re.sub(r"\$(?:\{(?P<braced>[A-Za-z_]\w*)\}|(?P<name>[A-Za-z_]\w*))", sub, text)


def _collect_variables(lines: list, presets: dict, where: str) -> dict:
    """Plain assignments, in file order, with presets layered on top.

    Conditional and command-substituted assignments are deliberately skipped:
    we cannot evaluate `LOADVM="-loadvm golden -S"` guarded by a `grep`, and we
    must not pretend to. The broker supplies those as presets instead — which is
    also how it guarantees a pool member comes up on the golden, paused.
    """
    seen: dict = {}
    for raw in lines:
        match = _ASSIGN.match(raw)
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        if _HAS_SUBST.search(value):
            continue
        try:
            words = shlex.split(_expand(value, {**seen, **presets}, where))
        except (ValueError, LauncherError):
            continue
        seen[name] = words[0] if len(words) == 1 else " ".join(words)
    seen.update(presets)
    return seen


def _qemu_block(lines: list, where: str) -> tuple:
    starts = [i for i, line in enumerate(lines) if _QEMU_START.match(line)]
    if not starts:
        raise LauncherError(f"{where}: no qemu-system-* invocation found — this launcher is not QEMU-shaped")
    if len(starts) > 1:
        raise LauncherError(f"{where}: {len(starts)} qemu-system-* invocations; the derivation needs exactly one")
    idx = starts[0]
    binary = _QEMU_START.match(lines[idx]).group("bin")
    chunk = []
    while idx < len(lines):
        line = lines[idx].rstrip()
        cont = line.endswith("\\")
        chunk.append(line[:-1] if cont else line)
        idx += 1
        if not cont:
            break
    return binary, " ".join(chunk)


def parse(path, presets: dict | None = None, text: str | None = None) -> Launcher:
    where = str(path)
    body = text if text is not None else Path(path).read_text()
    lines = [ln for ln in body.splitlines() if not ln.lstrip().startswith("#")]
    variables = _collect_variables(lines, dict(presets or {}), where)

    binary, command = _qemu_block(lines, where)
    command = re.sub(r"^\s*nohup\s+", "", command)
    expanded = _expand(command, variables, where)
    if _UNRESOLVED.search(expanded):
        raise LauncherError(f"{where}: unresolved shell expansion in the qemu command line: {expanded[:200]!r}")
    argv = [tok for tok in shlex.split(expanded) if not _REDIRECT.match(tok)]
    if not argv or "qemu-system-" not in argv[0]:
        raise LauncherError(f"{where}: could not tokenize the qemu command line")

    tapnet = ""
    for raw in lines:
        found = _TAPNET.search(raw)
        if found and found.group("verb") == "up":
            tapnet = _expand(found.group("path").strip('"'), variables, where)
            break

    return Launcher(path=where, binary=_expand(binary, variables, where), argv=argv, variables=variables, tapnet=tapnet)
