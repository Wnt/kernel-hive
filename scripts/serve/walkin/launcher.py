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
_COMMAND_WORD = re.compile(r'^\s*(?:nohup\s+)?(?P<word>"[^"]+"|[^\s|;&]+)')
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


_VAR = re.compile(r"\$(?:\{(?P<braced>[A-Za-z_]\w*)(?:(?P<op>:?-)(?P<default>[^}]*))?\}|(?P<name>[A-Za-z_]\w*))")


def _expand(text: str, variables: dict, where: str) -> str:
    def sub(match: re.Match) -> str:
        name = match.group("name") or match.group("braced")
        op = match.group("op")
        if op is not None:
            # `${NAME:-default}` / `${NAME-default}` — a bash default-value
            # expansion, not an unresolved reference. `:-` also falls back on an
            # EMPTY value, not just an unset one; `-` falls back only when unset.
            # None of the launchers this reads use the default for anything the
            # derivation cares about (debug trace toggles), so the default is
            # taken as a literal — it is never itself expanded.
            value = variables.get(name)
            if value is None or (op == ":-" and value == ""):
                return match.group("default")
            return str(value)
        if name not in variables:
            raise LauncherError(f"{where}: launcher uses ${name}, which nothing defines and no preset supplies")
        return str(variables[name])

    return _VAR.sub(sub, text)


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


def _command_binary(line: str, variables: dict) -> str:
    """The emulator this line invokes, or "" if it does not invoke one.

    Two shapes have to be told apart, and getting it wrong is quiet rather than
    loud. rhapsody's launcher both ASSIGNS its fork —

        QEMU=/opt/qemu-rhapsody/bin/qemu-system-i386

    — and INVOKES it a line later as a nohup on "$QEMU". Matching on "the line
    mentions qemu-system" picks the assignment, whose continuation is nothing at
    all, and hands back a one-token command line that looks like a parse rather
    than a failure. So: assignments are excluded by the caller, and the command
    WORD is what is expanded and tested — a `$QEMU` that resolves to an emulator
    counts, and `qemu-img snapshot -l` does not.
    """
    match = _COMMAND_WORD.match(line)
    if not match:
        return ""
    word = match.group("word").strip("\"'")
    try:
        expanded = _expand(word, variables, "<probe>")
    except LauncherError:
        return ""
    return expanded if "qemu-system" in Path(expanded).name else ""


def _qemu_block(lines: list, variables: dict, where: str) -> tuple:
    starts = [
        (i, found)
        for i, line in enumerate(lines)
        if not _ASSIGN.match(line) and (found := _command_binary(line, variables))
    ]
    if not starts:
        raise LauncherError(f"{where}: no qemu-system-* invocation found — this launcher is not QEMU-shaped")
    if len(starts) > 1:
        raise LauncherError(f"{where}: {len(starts)} qemu-system-* invocations; the derivation needs exactly one")
    idx, binary = starts[0]
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

    binary, command = _qemu_block(lines, variables, where)
    command = re.sub(r"^\s*nohup\s+", "", command)
    expanded = _expand(command, variables, where)
    if _UNRESOLVED.search(expanded):
        raise LauncherError(f"{where}: unresolved shell expansion in the qemu command line: {expanded[:200]!r}")
    argv = [tok for tok in shlex.split(expanded) if not _REDIRECT.match(tok)]
    if not argv or "qemu-system" not in Path(argv[0]).name:
        raise LauncherError(f"{where}: could not tokenize the qemu command line")

    tapnet = ""
    for raw in lines:
        found = _TAPNET.search(raw)
        if found and found.group("verb") == "up":
            tapnet = _expand(found.group("path").strip('"'), variables, where)
            break

    return Launcher(path=where, binary=_expand(binary, variables, where), argv=argv, variables=variables, tapnet=tapnet)
