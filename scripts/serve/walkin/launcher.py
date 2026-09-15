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
from dataclasses import dataclass, field
from pathlib import Path

_ASSIGN = re.compile(r"^\s*(?P<export>export\s+)?(?P<name>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>.*?)\s*(?:#.*)?$")
_HAS_SUBST = re.compile(r"\$\(|`")
_COMMAND_WORD = re.compile(r'^\s*(?:nohup\s+)?(?P<word>"[^"]+"|[^\s|;&]+)')
_TAPNET = re.compile(r"(?:bash|sh)\s+(?P<path>\"?[^\"'\s]*tapnet[\w.-]*\.sh\"?)\s+(?P<verb>up|down)\b")
_UNRESOLVED = re.compile(r"\$\{?[A-Za-z_0-9@*#?]")
# The whole reference at an _UNRESOLVED match, for naming it in the error.
_TOKEN = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_]\w*|\$.")
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
    # Variables the launcher `export`s, i.e. the ones it means the EMULATOR to
    # read from its environment rather than from its argv. A derivation that
    # takes the argv and drops these runs a materially different emulator —
    # see `_collect_variables`.
    exports: dict = field(default_factory=dict)


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


def _collect_variables(lines: list, presets: dict, where: str) -> tuple:
    """Plain assignments, in file order, with presets layered on top.

    Conditional and command-substituted assignments are deliberately skipped:
    we cannot evaluate `LOADVM="-loadvm golden -S"` guarded by a `grep`, and we
    must not pretend to. The broker supplies those as presets instead — which is
    also how it guarantees a pool member comes up on the golden, paused.

    Returns `(variables, exports)`. The second is the half this module used to
    throw away, and throwing it away is not cosmetic: a launcher `export`s the
    settings it means the EMULATOR to read out of its environment, and the
    broker READS a launcher rather than running it (see the module docstring),
    so nothing else can carry them. rhapsody exports
    `KH_I8259_LENIENT_CASCADE=1` — the opt-in for the i8259 patch WITHOUT WHICH
    that guest's Mach kernel loses every slave-PIC interrupt the first time the
    timer and a device completion coincide. A clone built from the argv alone
    ran the right binary with the fix switched OFF, wedged the master PIC with
    ISR2 permanently in service, and lost IRQ12 — the PS/2 mouse — for the rest
    of the visitor's session. Measured 2026-09-15: `info pic` on a walk-in clone
    read `pic0 irr=04 isr=04 / pic1 irr=90 isr=00`, the exact end state
    docs/guests/rhapsody.md records, while the live station (which DOES get the
    variable) has never once failed the same way.
    """
    seen: dict = {}
    exported: set = set()
    for raw in lines:
        match = _ASSIGN.match(raw)
        if not match:
            continue
        name, value = match.group("name"), match.group("value")
        if _HAS_SUBST.search(value):
            continue
        try:
            words = shlex.split(_expand(value, {**seen, **presets}, where))
        except (ValueError, LauncherError):
            continue
        seen[name] = words[0] if len(words) == 1 else " ".join(words)
        if match.group("export"):
            exported.add(name)
    seen.update(presets)
    # Presets WIN over the file for expansion, so an exported name the caller
    # also preset carries the caller's value here too — same rule, one place.
    return seen, {name: seen[name] for name in sorted(exported) if name in seen}


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
    variables, exports = _collect_variables(lines, dict(presets or {}), where)

    binary, command = _qemu_block(lines, variables, where)
    command = re.sub(r"^\s*nohup\s+", "", command)
    expanded = _expand(command, variables, where)
    unresolved = _UNRESOLVED.search(expanded)
    if unresolved:
        # Name the offending token and show it in context, rather than a blind
        # prefix of the command line — on a long invocation the culprit is
        # routinely well past character 200, so a truncated-from-the-start
        # message shows everything EXCEPT the thing that needs fixing (measured
        # on rhapsody's `trace=${PTR_TRACE:-off}`, which sits near the end).
        token_match = _TOKEN.match(expanded, unresolved.start())
        token = token_match.group(0) if token_match else expanded[unresolved.start() : unresolved.start() + 20]
        ctx_start = max(0, unresolved.start() - 30)
        context = expanded[ctx_start : unresolved.start() + len(token) + 30]
        raise LauncherError(f"{where}: unresolved shell expansion {token!r} in the qemu command line, near {context!r}")
    argv = [tok for tok in shlex.split(expanded) if not _REDIRECT.match(tok)]
    if not argv or "qemu-system" not in Path(argv[0]).name:
        raise LauncherError(f"{where}: could not tokenize the qemu command line")

    tapnet = ""
    for raw in lines:
        found = _TAPNET.search(raw)
        if found and found.group("verb") == "up":
            tapnet = _expand(found.group("path").strip('"'), variables, where)
            break

    return Launcher(
        path=where,
        binary=_expand(binary, variables, where),
        argv=argv,
        variables=variables,
        tapnet=tapnet,
        exports=exports,
    )
